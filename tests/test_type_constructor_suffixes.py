"""A suffix (`*`, `[]`, `[K]`) written *inside* a type constructor's parens
(`const(T*)`, `immutable(T[])`) used to be dropped entirely, not just the
qualifier.

`resolveDeclaredType` (`dsymbol/conversion/second.d`) only ever resolves a
*base name*: suffix-wrapping is the caller's job, applied once to the
outermost `Type` node's own `typeSuffixes`. A type constructor's operand
(`t2.type` in `const(X)`) is itself a full `Type` node with its own
`typeSuffixes` list -- and nothing ever read it, so `const(T**)` resolved as
bare `T`, not `T**`: not just missing `const`, but silently downgrading a
double pointer to a plain value. Fixed by applying the operand's own
suffixes where it's resolved, the same way the outer type's are applied.

`const`/`immutable` itself staying invisible in the resolved type graph is a
separate, already-known, deliberately deferred limitation (see
docs/problem-calltips.md and the parameter-storage-class work) -- these
tests pin the suffix shape, not the qualifier keyword.
"""

from harness import DlsTestCase, find_item


PLAIN_VARIABLES = """module app;

void test()
{
    const(int*) ptr;
    immutable(int[]) arr;
    const(int**) doublePtr;

    int useThem = 1;
}
"""

POINTER_EDGE_CASES = """module app;

struct Data
{
    int value;
}

void test()
{
    const(int***) triple;
    const(int*[]) arrOfPtr;
    const(int[3]*) ptrToStaticArr;
    const(int[][]) doubleArr;
    shared(int*) sharedPtr;

    const(Data*) dataPtr;
    dataPtr.va

    int useThem = 1;
}
"""

NON_GENERIC_RETURN_TYPES = """module app;

struct Data
{
    int value;
}

const(Data*) getDataPtr();
Data** getDoubleDataPtr();

void test()
{
    auto p = getDataPtr();
    p.va

    auto pp = getDoubleDataPtr();
}
"""

FIELD_TYPES = """module app;

struct Data
{
    int value;
}

struct Holder
{
    const(Data*) dataPtr;
    const(int**) intDoublePtr;
}

void test()
{
    Holder h;
    h.dataPtr.va
}
"""

GENERIC_RETURN_TYPES = """module app;

struct Data
{
    int value;
}

const(T**) getDoublePtr(T)();
const(T[]) getArray(T)();
immutable(T*) getPtr(T)();

void test()
{
    auto viaDoublePtr = getDoublePtr!(Data);
    auto viaArray = getArray!(Data);
    auto viaPtr = getPtr!(Data);
}
"""


class DeclaredVariableSuffixTests(DlsTestCase):
    """The bug reproduces without templates at all -- a plain local
    variable's declared type already loses inner suffixes.
    """

    PROJECT = {"app.d": PLAIN_VARIABLES}

    def _hover(self, doc, needle):
        result = doc.hover(needle, offset=-1)
        return "\n".join(entry["value"] for entry in result["contents"])

    def test_pointer_inside_const(self):
        doc = self.open_doc("app.d")
        self.assertIn("int* ptr", self._hover(doc, "const(int*) ptr"))

    def test_array_inside_immutable(self):
        doc = self.open_doc("app.d")
        self.assertIn("int[] arr", self._hover(doc, "immutable(int[]) arr"))

    def test_double_pointer_inside_const(self):
        doc = self.open_doc("app.d")
        self.assertIn("int** doublePtr", self._hover(doc, "const(int**) doublePtr"))


class GenericReturnTypeSuffixTests(DlsTestCase):
    """The same gap through a generic function's return type, deduced via
    an explicit `get!(Data)` instantiation -- the shape that surfaced the
    bug originally.
    """

    PROJECT = {"app.d": GENERIC_RETURN_TYPES}

    def _hover(self, doc, needle):
        result = doc.hover(needle, offset=-len(needle) + 5)
        return "\n".join(entry["value"] for entry in result["contents"])

    def test_double_pointer_return_type(self):
        doc = self.open_doc("app.d")
        self.assertIn("Data** viaDoublePtr", self._hover(doc, "auto viaDoublePtr"))

    def test_array_return_type(self):
        doc = self.open_doc("app.d")
        self.assertIn("Data[] viaArray", self._hover(doc, "auto viaArray"))

    def test_pointer_return_type(self):
        doc = self.open_doc("app.d")
        self.assertIn("Data* viaPtr", self._hover(doc, "auto viaPtr"))


class PointerEdgeCaseTests(DlsTestCase):
    """Pointer-specific shapes beyond a bare `T*`/`T**`: more indirection,
    a pointer combined with array suffixes on either side, another
    qualifier keyword (`shared`), and -- the functional check, not just a
    display string -- member completion through a `const(Data*)` local,
    which needs `getParts`/`memberStep` to walk through the
    `POINTER_SYMBOL_NAME` wrapper the fix now actually builds.
    """

    PROJECT = {"app.d": POINTER_EDGE_CASES}

    def _hover(self, doc, needle):
        result = doc.hover(needle, offset=-1)
        return "\n".join(entry["value"] for entry in result["contents"])

    def test_triple_pointer(self):
        doc = self.open_doc("app.d")
        self.assertIn("int*** triple", self._hover(doc, "const(int***) triple"))

    def test_array_of_pointers(self):
        doc = self.open_doc("app.d")
        self.assertIn("int*[] arrOfPtr", self._hover(doc, "const(int*[]) arrOfPtr"))

    def test_pointer_to_static_array(self):
        doc = self.open_doc("app.d")
        self.assertIn("int[3]* ptrToStaticArr",
            self._hover(doc, "const(int[3]*) ptrToStaticArr"))

    def test_array_of_arrays(self):
        doc = self.open_doc("app.d")
        self.assertIn("int[][] doubleArr", self._hover(doc, "const(int[][]) doubleArr"))

    def test_shared_pointer(self):
        doc = self.open_doc("app.d")
        self.assertIn("int* sharedPtr", self._hover(doc, "shared(int*) sharedPtr"))

    def test_member_completion_through_a_const_pointer(self):
        doc = self.open_doc("app.d")
        items = doc.completion("dataPtr.va")["items"]
        self.assertEqual(find_item(items, "value")["labelDetails"]["description"], "int")


class NonGenericFunctionReturnPointerTests(DlsTestCase):
    """The same fix, reached without any template involved at all: a plain
    function's own declared return type goes through the identical
    `resolveDeclaredType` path.
    """

    PROJECT = {"app.d": NON_GENERIC_RETURN_TYPES}

    def test_hover_shows_the_pointer(self):
        doc = self.open_doc("app.d")
        result = doc.hover("auto p", offset=-len("auto p") + 5)
        text = "\n".join(entry["value"] for entry in result["contents"])
        self.assertIn("Data* p", text)

    def test_member_completion_through_the_returned_pointer(self):
        doc = self.open_doc("app.d")
        items = doc.completion("p.va")["items"]
        self.assertEqual(find_item(items, "value")["labelDetails"]["description"], "int")

    def test_double_pointer_return_type_without_a_qualifier(self):
        doc = self.open_doc("app.d")
        result = doc.hover("auto pp", offset=-len("auto pp") + 5)
        text = "\n".join(entry["value"] for entry in result["contents"])
        self.assertIn("Data** pp", text)


class FieldTypeSuffixTests(DlsTestCase):
    """The declared type of a struct *field* goes through the same
    resolution as a local variable's -- pinned separately since fields are
    collected through a different first-pass visitor path
    (`structFieldTypes`) before ending up at the same `resolveDeclaredType`.
    """

    PROJECT = {"app.d": FIELD_TYPES}

    def test_hover_on_a_pointer_field(self):
        doc = self.open_doc("app.d")
        result = doc.hover("const(Data*) dataPtr", offset=-1)
        text = "\n".join(entry["value"] for entry in result["contents"])
        self.assertIn("Data* dataPtr", text)

    def test_hover_on_a_double_pointer_field(self):
        doc = self.open_doc("app.d")
        result = doc.hover("const(int**) intDoublePtr", offset=-1)
        text = "\n".join(entry["value"] for entry in result["contents"])
        self.assertIn("int** intDoublePtr", text)

    def test_member_completion_through_a_field_pointer(self):
        doc = self.open_doc("app.d")
        items = doc.completion("h.dataPtr.va")["items"]
        self.assertEqual(find_item(items, "value")["labelDetails"]["description"], "int")
