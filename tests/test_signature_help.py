"""textDocument/signatureHelp: call labels, parameters, active parameter."""

from harness import DlsTestCase


SOURCE = """module app;

/**
 * Adds two numbers.
 */
int add(int a, int b) { return a + b; }

int add(int a, int b, int c) { return a + b + c; }

void main()
{
    add(1, 
}
"""


class SignatureHelpTests(DlsTestCase):
    PROJECT = {"app.d": SOURCE}

    def setUp(self):
        self.doc = self.open_doc("app.d")

    def test_returns_one_entry_per_overload(self):
        result = self.doc.signature_help("add(1, ")
        labels = [signature["label"] for signature in result["signatures"]]
        self.assertEqual(
            labels,
            ["int add(int a, int b)", "int add(int a, int b, int c)"],
        )

    def test_parameters_and_active_parameter(self):
        result = self.doc.signature_help("add(1, ")
        self.assertEqual(result["activeSignature"], 0)
        # The cursor sits after the first argument's comma.
        self.assertEqual(result["activeParameter"], 1)

        parameters = result["signatures"][0]["parameters"]
        self.assertEqual([parameter["label"] for parameter in parameters], ["int a", "int b"])

    def test_active_parameter_is_zero_for_the_first_argument(self):
        # Cursor directly after the opening parenthesis of the call.
        result = self.doc.signature_help("    add(")
        self.assertEqual(result["activeParameter"], 0)

    def test_no_signature_outside_a_call(self):
        result = self.doc.signature_help("void main()", offset=0)
        self.assertEqual(result["signatures"], [])


FUNCTION_POINTERS = """module app;

struct State {}

void function(State*) free_fp;

struct Box
{
    void function(State*) fp;
}

void main()
{
    void function(State*) local_fp;
    Box b;
    free_fp();
    local_fp();
    b.fp();
}
"""


class FunctionPointerSignatureTests(DlsTestCase):
    """A call through a function pointer is still a call.

    The call tip lives on the variable's *type*, not on the variable, so the
    resolver has to follow it - including through a member access.
    """

    PROJECT = {"app.d": FUNCTION_POINTERS}

    def setUp(self):
        self.doc = self.open_doc("app.d")

    def labels_at(self, needle):
        result = self.doc.signature_help(needle)
        return [signature["label"] for signature in result["signatures"]]

    def test_a_module_level_function_pointer(self):
        self.assertEqual(self.labels_at("free_fp("), ["void function(State*)"])

    def test_a_local_function_pointer(self):
        self.assertEqual(self.labels_at("local_fp("), ["void function(State*)"])

    def test_a_function_pointer_field(self):
        self.assertEqual(self.labels_at("b.fp("), ["void function(State*)"])


TEMPLATE_SHAPES = """module app;

struct TD(T)
{
    T data;
}

struct Pair(K, V)
{
    K key;
    V value;
}

struct Constrained(T : int)
{
    T data;
}

// A template parameter list followed by a body field that itself contains
// parens - a function pointer - used to mislead the closing-paren search
// into swallowing part of the body into the parameter list.
struct TemplWithFnPtr(T)
{
    void function(T) fp;
}

struct Plain
{
    int x;
}

void main()
{
    TD!()
    TD()
    Pair!()
    Constrained!()
    TemplWithFnPtr!()
    Plain()
}
"""


class TemplateInstantiationSignatureHelpTests(DlsTestCase):
    """Regression: `Name!(...)` instantiates a template and should show its
    parameter list (`TD(T)`), not the constructor `Name(...)` calls - which
    is built from the struct's *fields*, not its template parameters, and
    used to show up here instead regardless of the `!`.
    """

    PROJECT = {"app.d": TEMPLATE_SHAPES}

    def setUp(self):
        self.doc = self.open_doc("app.d")

    def _params_at(self, needle):
        result = self.doc.signature_help(needle)
        self.assertEqual(len(result["signatures"]), 1)
        return [p["label"] for p in result["signatures"][0]["parameters"]]

    def test_bang_paren_shows_the_template_parameter_list(self):
        self.assertEqual(self._params_at("TD!("), ["T"])

    def test_plain_paren_still_shows_the_constructor(self):
        # Unlike `TD!(`, `TD(` is an ordinary call and must still resolve to
        # the (implicit) constructor, built from the struct's fields.
        self.assertEqual(self._params_at("    TD("), ["T data"])

    def test_multiple_type_parameters_stay_in_declaration_order(self):
        self.assertEqual(self._params_at("Pair!("), ["K", "V"])

    def test_a_constrained_template_parameter_is_kept_whole(self):
        self.assertEqual(self._params_at("Constrained!("), ["T : int"])

    def test_a_body_only_paren_does_not_leak_into_the_parameter_list(self):
        self.assertEqual(self._params_at("TemplWithFnPtr!("), ["T"])

    def test_a_non_templated_struct_call_is_unaffected(self):
        self.assertEqual(self._params_at("    Plain("), ["int x"])


TEMPLATED_FUNCTIONS = """module app;

T get(T)(T data)
{
    return data;
}

T2 combine(A, B)(A a, B b)
{
    T2 x;
    return x;
}

void noValueParams(T)()
{
}

void main()
{
    get()
    get!()
    combine()
    combine!()
    noValueParams()
    noValueParams!()
}
"""


class TemplateFunctionSignatureHelpTests(DlsTestCase):
    """Regression: `Name!(...)` instantiates the template, `Name(...)` calls
    it - a templated *function*'s callTip has both parameter lists back to
    back (`T get(T)(T data)`), and which one belongs in the hint depends on
    which the call site actually wrote. Only the struct/union/class case was
    fixed at first; a templated function fell through unchanged and showed
    the value parameter list for `!(` too.
    """

    PROJECT = {"app.d": TEMPLATED_FUNCTIONS}

    def setUp(self):
        self.doc = self.open_doc("app.d")

    def _params_at(self, needle):
        result = self.doc.signature_help(needle)
        self.assertEqual(len(result["signatures"]), 1)
        return [p["label"] for p in result["signatures"][0]["parameters"]]

    def test_plain_call_shows_the_value_parameters(self):
        self.assertEqual(self._params_at("    get("), ["T data"])

    def test_bang_paren_shows_the_template_parameters_instead(self):
        self.assertEqual(self._params_at("get!("), ["T"])

    def test_multiple_template_parameters_stay_in_declaration_order(self):
        self.assertEqual(self._params_at("combine!("), ["A", "B"])

    def test_bang_paren_works_even_with_no_value_parameters(self):
        # noValueParams(T)() - the value parameter list is empty, so a
        # naive "last group" pick would find it (empty) either way; this
        # only passes if `!` actually steers the choice, not the shape.
        self.assertEqual(self._params_at("noValueParams!("), ["T"])
        self.assertEqual(self._params_at("    noValueParams("), [])
