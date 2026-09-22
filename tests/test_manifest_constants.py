"""The type of a manifest constant: ``enum name = <initializer>;``.

A manifest constant's type is the type of its initializer, so ``int`` is
reported for ``enum JsonFalse = (1 << 0);`` exactly like it is for
``enum JsonInvalid = 0;``.  The walker in ``dsymbol/conversion/second.d``
models literals and ``cast``, and derives the builtin operators from their
operands: `bool` for a comparison or a logical operator, the promoted left
operand for a shift, and the common type of the two (D's usual arithmetic
conversions) for the rest.  A symbol it cannot type still hovers as the
``???`` placeholder (``dll.d``) and is described as a plain ``variable`` in
the completion list.
"""

from harness import KIND_VARIABLE, DlsTestCase, find_item


MANIFEST_CONSTANTS = """module manifest_constants;

enum JsonInvalid = 0;
enum JsonFalse = (1 << 0);
enum JsonMasked = 1 << 1;
enum JsonFlag = 1 <= 2;
enum JsonWide = 1 + 2L;

void main() {}
"""


COMPLETION = """module manifest_constant_site;

enum JsonInvalid = 0;
enum JsonFalse = (1 << 0);

void main()
{
    Json
}
"""


class ManifestConstantHoverTests(DlsTestCase):
    PROJECT = {"manifest_constants.d": MANIFEST_CONSTANTS}

    def _hover_value(self, doc, name):
        contents = doc.hover(name, offset=-1)["contents"]
        self.assertTrue(contents, f"hover on {name!r} returned no contents")
        return contents[0]["value"]

    def test_a_literal_initializer_reports_the_literal_type(self):
        doc = self.open_doc("manifest_constants.d")
        self.assertEqual(self._hover_value(doc, "JsonInvalid"), "int JsonInvalid;")

    def test_a_parenthesized_expression_reports_the_expression_type(self):
        doc = self.open_doc("manifest_constants.d")
        self.assertEqual(self._hover_value(doc, "JsonFalse"), "int JsonFalse;")

    def test_a_binary_expression_reports_the_expression_type(self):
        doc = self.open_doc("manifest_constants.d")
        self.assertEqual(self._hover_value(doc, "JsonMasked"), "int JsonMasked;")

    def test_an_operator_result_follows_the_builtin_conversion_rules(self):
        doc = self.open_doc("manifest_constants.d")
        # A comparison is a `bool`; `int + long` is the wider `long`.
        self.assertEqual(self._hover_value(doc, "JsonFlag"), "bool JsonFlag;")
        self.assertEqual(self._hover_value(doc, "JsonWide"), "long JsonWide;")


class ManifestConstantCompletionTests(DlsTestCase):
    """The same type, on the other surface an editor shows it."""

    PROJECT = {"completion.d": COMPLETION}

    def test_a_manifest_constant_is_described_by_its_type(self):
        doc = self.open_doc("completion.d")
        items = doc.completion("    Json")["items"]
        literal = find_item(items, "JsonInvalid")
        expression = find_item(items, "JsonFalse")

        self.assertEqual(literal["kind"], KIND_VARIABLE)
        self.assertEqual(literal["labelDetails"]["description"], "int")
        self.assertEqual(expression["labelDetails"]["description"], "int")
