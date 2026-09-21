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
