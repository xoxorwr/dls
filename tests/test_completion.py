"""Completion behaviour and response shape."""

from harness import KIND_FIELD, KIND_VARIABLE, DlsTestCase, find_item, labels


MEMBERS = """module app;

struct State
{
    int aaa;
    int bbb;
}

void main()
{
    State st;
    st.aa
}
"""

PARTIAL = """module app;

struct State
{
    int aaa;
    int bbb;
}

void main()
{
    State st;
    st.b
}
"""

MODULE_SCOPE = """module app;

struct State
{
    int aaa;
}

int compute(int x) { return x; }

void main()
{
    comp
}
"""


FUNCTION_POINTERS = """module app;

struct State {}

void function(State*) free_fp;

struct Box
{
    void function(State*) fp;
}

void main()
{
    Box b;
    free_fp;
    b.fp;
}
"""


class CompletionTests(DlsTestCase):
    PROJECT = {
        "app.d": MEMBERS,
        "partial.d": PARTIAL,
        "scope.d": MODULE_SCOPE,
    }

    def test_member_completion_after_dot(self):
        doc = self.open_doc("app.d")
        items = doc.completion("st.aa")["items"]

        field = find_item(items, "aaa")
        self.assertEqual(field["kind"], KIND_FIELD)
        self.assertEqual(field["labelDetails"]["description"], "int")
        # Member variables are sorted into the "3_" group.
        self.assertEqual(field["sortText"], "3_")

    def test_member_completion_is_filtered_by_the_typed_prefix(self):
        doc = self.open_doc("partial.d")
        items = doc.completion("st.b")["items"]

        found = labels(items)
        self.assertIn("bbb", found)
        self.assertNotIn("aaa", found)

    def test_completion_response_shape(self):
        doc = self.open_doc("app.d")
        result = doc.completion("st.aa")

        self.assertFalse(result["isIncomplete"])
        self.assertIsInstance(result["items"], list)
        for item in result["items"]:
            self.assertIsInstance(item["label"], str)
            self.assertIsInstance(item["kind"], int)
            self.assertIn("sortText", item)
            self.assertIn("filterText", item)
            self.assertIn("detail", item["labelDetails"])
            self.assertIn("description", item["labelDetails"])

    def test_module_scope_completion_finds_top_level_symbols(self):
        doc = self.open_doc("scope.d")
        # The indentation keeps the needle from matching the "compute"
        # declaration itself; the cursor ends up in "    comp" inside main.
        items = doc.completion("    comp")["items"]

        self.assertIn("compute", labels(items))

    def test_member_completion_only_returns_matching_members(self):
        doc = self.open_doc("app.d")
        # The cursor sits after "st.aa", so the prefix is "a": both "aaa" and
        # "bbb" exist, but only "aaa" matches.
        items = doc.completion("st.", offset=len("aa"))["items"]
        found = labels(items)
        self.assertIn("aaa", found)
        self.assertNotIn("bbb", found)


class FunctionPointerCompletionTests(DlsTestCase):
    """A function pointer keeps its own kind but shows the type it points at.

    ``void function(State*) fn;`` declares a variable, so the label says
    variable (or field for a member) - and the type it is shown with is the
    whole function type, not the bare word "function".
    """

    PROJECT = {"app.d": FUNCTION_POINTERS}

    def test_a_variable_is_a_variable_typed_void_function(self):
        doc = self.open_doc("app.d")
        # The second occurrence: the first is the declaration itself.
        items = doc.completion("free_fp", occurrence=1)["items"]
        item = find_item(items, "free_fp")
        self.assertEqual(item["kind"], KIND_VARIABLE)
        self.assertEqual(item["labelDetails"]["description"], "void function(State*)")

    def test_a_member_is_a_field_typed_void_function(self):
        doc = self.open_doc("app.d")
        item = find_item(doc.completion("b.fp")["items"], "fp")
        self.assertEqual(item["kind"], KIND_FIELD)
        self.assertEqual(item["labelDetails"]["description"], "void function(State*)")


TEMPLATED_STRUCT = """module app;

struct TD(T)
{
    T data;
}

void main()
{
    TD!int x;
}
"""


class TemplatedStructCompletionTests(DlsTestCase):
    """Regression: a templated struct's completion item used to show no
    parameter list at all - "TD" with nothing further, indistinguishable
    from a plain, non-templated struct.
    """

    PROJECT = {"app.d": TEMPLATED_STRUCT}

    def test_completion_detail_keeps_the_template_parameter_list(self):
        doc = self.open_doc("app.d")
        # The second occurrence: the first is the declaration itself.
        items = doc.completion("TD", occurrence=1)["items"]
        item = find_item(items, "TD")
        self.assertEqual(item["labelDetails"]["detail"], "(T)")


TEMPLATE_SHAPES = """module app;

// A template parameter that isn't a plain type - constrained (`T : Base`)
// or a value parameter (`int N`) - has no dedicated typeTmpParam symbol,
// so its completion detail falls back to the struct's full callTip (which
// has a body) rather than the no-body "Name(Params)" a plain type parameter
// gets. The two need the same clipped-at-the-closing-paren detail either
// way.
struct Constrained(T : int)
{
    T data;
}

struct ValueParam(int N)
{
    int[N] data;
}

// Multiple plain type parameters: opSlice() does not hand symbols back in
// declaration order, so the parameter list has to be sorted by source
// position or it comes out scrambled.
struct Triple(A, B, C)
{
    A a;
    B b;
    C c;
}

class ClassPair(K, V)
{
    K key;
    V value;
}

// A non-templated struct whose one field happens to contain a '(' inside
// its own body - must not be mistaken for a template parameter list.
struct WithFunctionPointerField
{
    void function(int) fp;
}

void main()
{
    Constrained!int a;
    ValueParam!4 b;
    Triple!(int, string, bool) c;
    ClassPair!(int, string) d;
    WithFunctionPointerField e;
}
"""


class TemplateShapeCompletionTests(DlsTestCase):
    """Edge cases of the structName/className completion detail: every shape
    that can produce a definition with a '(' in it has to end up with only
    the parameter list in `detail`, correctly ordered, body excluded.
    """

    PROJECT = {"app.d": TEMPLATE_SHAPES}

    def _detail(self, name):
        doc = self.open_doc("app.d")
        items = doc.completion(name, occurrence=1)["items"]
        return find_item(items, name)["labelDetails"]["detail"]

    def test_constrained_template_parameter_stops_at_its_own_paren(self):
        self.assertEqual(self._detail("Constrained"), "(T : int)")

    def test_value_template_parameter_stops_at_its_own_paren(self):
        self.assertEqual(self._detail("ValueParam"), "(int N)")

    def test_multiple_type_parameters_stay_in_declaration_order(self):
        self.assertEqual(self._detail("Triple"), "(A, B, C)")

    def test_a_templated_class_also_gets_an_ordered_parameter_list(self):
        self.assertEqual(self._detail("ClassPair"), "(K, V)")

    def test_a_body_only_paren_is_not_mistaken_for_a_parameter_list(self):
        self.assertEqual(self._detail("WithFunctionPointerField"), "")
