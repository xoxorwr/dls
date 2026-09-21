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
