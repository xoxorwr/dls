"""Structured signatures: attributes, template parameter lists, substitution.

`DSymbol.callTip` used to be one joined line that signature help and
completion detail took apart again with bracket-depth bookkeeping.  A callable
now keeps a `Signature` whose parts were read off the AST while it was alive,
so these pin what the parts are - not what can be recovered from the line.
"""

from harness import DlsTestCase, find_item


def param_text(signature, parameter):
    """As in `test_signature_help`: an offset label is sliced out of the
    signature label, the way an LSP client resolves it."""
    label = parameter["label"]
    if isinstance(label, list):
        start, end = label
        return signature["label"][start:end]
    return label


def param_texts(signature):
    return [param_text(signature, p) for p in signature["parameters"]]


ATTRIBUTES_LEADING = """module attrs_leading;

// Written before the return type: libdparse consumes these into the
// enclosing declaration, not the function declaration.
pure nothrow @safe int f(int a) { return a; }

void main()
{
    f(1, 
}
"""

ATTRIBUTES_TRAILING = """module attrs_trailing;

int f(int a) pure nothrow @safe { return a; }

void main()
{
    f(1, 
}
"""

UDA_LEADING = """module uda_leading;

@(1) void g(int a) {}

void main()
{
    g(1, 
}
"""

UDA_TRAILING = """module uda_trailing;

void u(int a) @(42) {}

void main()
{
    u(1, 
}
"""


class FunctionAttributeSignatureTests(DlsTestCase):
    """Function attributes were never in the call tip at all -- it did not
    look at them, so unlike a parameter list they could not even be
    reverse-engineered out of it. They are part of the signature now.
    """

    PROJECT = {
        "attrs_leading.d": ATTRIBUTES_LEADING,
        "attrs_trailing.d": ATTRIBUTES_TRAILING,
        "uda_leading.d": UDA_LEADING,
        "uda_trailing.d": UDA_TRAILING,
    }

    def label_at(self, doc_name, needle):
        doc = self.open_doc(doc_name)
        result = doc.signature_help(needle)
        self.assertEqual(len(result["signatures"]), 1)
        return result["signatures"][0]

    def test_attributes_before_the_return_type(self):
        signature = self.label_at("attrs_leading.d", "f(1, ")
        self.assertEqual(signature["label"], "int f(int a) pure nothrow @safe")
        self.assertEqual(param_texts(signature), ["int a"])

    def test_attributes_after_the_parameter_list(self):
        signature = self.label_at("attrs_trailing.d", "f(1, ")
        self.assertEqual(signature["label"], "int f(int a) pure nothrow @safe")
        self.assertEqual(param_texts(signature), ["int a"])

    def test_a_user_defined_attribute_before_the_return_type(self):
        signature = self.label_at("uda_leading.d", "g(1, ")
        self.assertEqual(signature["label"], "void g(int a) @(1)")

    def test_a_user_defined_attribute_after_the_parameter_list(self):
        signature = self.label_at("uda_trailing.d", "u(1, ")
        self.assertEqual(signature["label"], "void u(int a) @(42)")

    def test_parameter_offsets_are_into_the_attributed_label(self):
        # The offsets have to be computed against the line that was actually
        # assembled, attributes and all - not against a re-found "(...)".
        signature = self.label_at("attrs_leading.d", "f(1, ")
        # "int f(" is six bytes, so the value parameter list starts there.
        self.assertEqual(signature["label"][6:11], "int a")
        self.assertEqual(signature["parameters"][0]["label"], [6, 11])


BANG_TEMPLATED_STRUCT = """module bang_struct;

struct TD(T)
{
    T data;
}

struct Constrained(T : int)
{
    T data;
}
"""

BANG_TEMPLATED_CLASS = """module bang_class;

class ClassPair(K, V)
{
    K key;
    V value;
}
"""


class TemplateParameterListLabelTests(DlsTestCase):
    """`Name!(...)` asks for the template parameter list.

    The list is a field of the signature now, so the label is the declaration
    (`TD(T)`, `ClassPair(K, V)`) rather than whatever the struct's rendered
    body happened to look like.
    """

    PROJECT = {
        "bang_struct.d": BANG_TEMPLATED_STRUCT + "\nvoid main()\n{\n    Constrained!(\n}\n",
        "bang_class.d": BANG_TEMPLATED_CLASS + "\nvoid main()\n{\n    ClassPair!(\n}\n",
    }

    def signature_at(self, doc_name, needle):
        doc = self.open_doc(doc_name)
        result = doc.signature_help(needle)
        self.assertEqual(len(result["signatures"]), 1)
        return result["signatures"][0]

    def test_a_constrained_parameter_keeps_its_constraint(self):
        signature = self.signature_at("bang_struct.d", "Constrained!(")
        self.assertEqual(signature["label"], "Constrained(T : int)")
        self.assertEqual(param_texts(signature), ["T : int"])

    def test_a_templated_class_lists_its_parameters_in_order(self):
        signature = self.signature_at("bang_class.d", "ClassPair!(")
        self.assertEqual(signature["label"], "ClassPair(K, V)")
        self.assertEqual(param_texts(signature), ["K", "V"])


INSTANCE_MEMBER = """module instance_member;

struct HashMap(K, V)
{
    V get(K key)
    {
        return V.init;
    }
}

HashMap!(int, int*) data;

void testme()
{
    data.
}
"""


class InstantiatedMemberSignatureTests(DlsTestCase):
    """A member copied into a template instance gets its return type
    substituted in its signature, the way `substituteCallTipReturnType` used
    to rewrite the head of the call tip string.
    """

    PROJECT = {"instance_member.d": INSTANCE_MEMBER}

    def test_the_return_type_is_substituted_and_the_parameters_kept(self):
        doc = self.open_doc("instance_member.d")
        items = doc.completion("data.")["items"]
        item = find_item(items, "get")
        self.assertEqual(item["labelDetails"]["description"], "int*")
        self.assertEqual(item["labelDetails"]["detail"], "(K key)")


FUNCTION_POINTER_MEMBER = """module fp_member;

struct S
{
    void function(int) fp;
}

void main()
{
    S s;
    s.fp;
}
"""

FUNCTION_POINTER_CALL = """module fp_call;

struct S
{
    void function(int) fp;
}

void main()
{
    S s;
    s.fp(
}
"""


class FunctionPointerTypeTests(DlsTestCase):
    """A `T function(Args)` type is rendered from its signature too (hover
    goes through `formatType`), and signature help reads its parameters from
    there rather than splitting the rendered type.
    """

    PROJECT = {
        "fp_member.d": FUNCTION_POINTER_MEMBER,
        "fp_call.d": FUNCTION_POINTER_CALL,
    }

    def test_hover_on_a_function_pointer_member(self):
        doc = self.open_doc("fp_member.d")
        result = doc.hover("s.fp", offset=-len("s.fp") + 3)
        values = [entry["value"] for entry in result["contents"]]
        self.assertIn("void function(int) fp;", values)

    def test_a_call_through_the_pointer_shows_the_type_and_its_parameter(self):
        doc = self.open_doc("fp_call.d")
        result = doc.signature_help("s.fp(")
        self.assertEqual(len(result["signatures"]), 1)
        signature = result["signatures"][0]
        self.assertEqual(signature["label"], "void function(int)")
        self.assertEqual(param_texts(signature), ["int"])
VARIADIC = """module variadic;

void f(int a, ...) {}

void main()
{
    f(1, 
}
"""


class VariadicParameterTests(DlsTestCase):
    """`...` is the last entry of the value parameter list, exactly as the
    formatter spelled it inside the old call tip - which is also what
    signature help used to hand back for it.
    """

    PROJECT = {"variadic.d": VARIADIC}

    def test_varargs_is_a_parameter_entry(self):
        doc = self.open_doc("variadic.d")
        result = doc.signature_help("f(1, ")
        self.assertEqual(len(result["signatures"]), 1)
        signature = result["signatures"][0]
        self.assertEqual(signature["label"], "void f(int a, ...)")
        self.assertEqual(param_texts(signature), ["int a", "..."])


IN_CALL = """module in_call;

int add(int a, int b) { return a + b; }

struct TD(T)
{
    T data;
}

void main()
{
    add(
}
"""


class CalltipCompletionTests(DlsTestCase):
    """Typing inside a call dispatches to the calltip completion path
    (`complete.d`'s `setCompletions` with `CompletionType.calltips`), which is
    what offers the callee rather than an identifier list.
    """

    PROJECT = {"in_call.d": IN_CALL}

    def test_completing_inside_a_call_offers_the_callee(self):
        doc = self.open_doc("in_call.d")
        items = doc.completion("add(")["items"]
        self.assertEqual([item["label"] for item in items], ["add"])
        # The signature's return type is what the item is described by.
        self.assertEqual(items[0]["labelDetails"]["description"], "int")
