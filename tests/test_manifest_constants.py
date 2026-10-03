"""Hover on a manifest constant: ``enum name = <initializer>;``.

A manifest constant's type is the type of its initializer, so ``int`` is
reported for ``enum JsonFalse = (1 << 0);`` exactly like it is for
``enum JsonInvalid = 0;``.  The walker in ``dsymbol/conversion/second.d``
models literals and ``cast``, and derives the builtin operators from their
operands: `bool` for a comparison or a logical operator, the promoted left
operand for a shift, and the common type of the two (D's usual arithmetic
conversions) for the rest.  A symbol it cannot type still hovers as the
``???`` placeholder (``dll.d``) and is described as a plain ``variable`` in
the completion list.  The initializer itself is rendered back next to the
name, so the tooltip carries the value (``int JsonInvalid = 0;``) and not
just the type.
"""

from harness import KIND_VARIABLE, DlsTestCase, find_item


MANIFEST_CONSTANTS = """module manifest_constants;

enum JsonInvalid = 0;
enum JsonFalse = (1 << 0);
enum JsonMasked = 1 << 1;
enum JsonFlag = 1 <= 2;
enum JsonWide = 1 + 2L;
enum uint Typed = 5;

void main()
{
    int x = 5;
}
"""


COMPLETION = """module manifest_constant_site;

enum JsonInvalid = 0;
enum JsonFalse = (1 << 0);

void main()
{
    Json
}
"""


ENUM_VALUES = """module enum_values;

enum Color { Red = 3, Green, Blue = 9 }

void main()
{
    Color c;
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
        self.assertEqual(self._hover_value(doc, "JsonInvalid"), "int JsonInvalid = 0;")

    def test_a_parenthesized_expression_reports_the_expression_type(self):
        doc = self.open_doc("manifest_constants.d")
        self.assertEqual(self._hover_value(doc, "JsonFalse"), "int JsonFalse = (1 << 0);")

    def test_a_binary_expression_reports_the_expression_type(self):
        doc = self.open_doc("manifest_constants.d")
        self.assertEqual(self._hover_value(doc, "JsonMasked"), "int JsonMasked = 1 << 1;")

    def test_an_operator_result_follows_the_builtin_conversion_rules(self):
        doc = self.open_doc("manifest_constants.d")
        # A comparison is a `bool`; `int + long` is the wider `long`.
        self.assertEqual(self._hover_value(doc, "JsonFlag"), "bool JsonFlag = 1 <= 2;")
        self.assertEqual(self._hover_value(doc, "JsonWide"), "long JsonWide = 1 + 2L;")

    def test_a_typed_manifest_constant_keeps_its_declared_type(self):
        """`enum uint x = 5;` parses as a *typed* variable declaration (the
        `enum` storage class plus a real type), the other shape a manifest
        constant reaches the first pass through.
        """
        doc = self.open_doc("manifest_constants.d")
        self.assertEqual(self._hover_value(doc, "Typed"), "uint Typed = 5;")

    def test_an_ordinary_variable_does_not_gain_its_initializer(self):
        """Only `enum`-class declarations are values worth inlining; a plain
        `int x = 5;` keeps the type-only line it always had.
        """
        doc = self.open_doc("manifest_constants.d")
        # Land on the 'x' of `int x = 5;` in main.
        contents = doc.hover("int x = 5", offset=4 - len("int x = 5"))["contents"]
        self.assertEqual([entry["value"] for entry in contents], ["int x;"])


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


class EnumMemberValueHoverTests(DlsTestCase):
    """The same value rendering for a named enum's members: a member carries
    its `= initializer`, and a hover on the enum name lists them with theirs.
    """

    PROJECT = {"enum_values.d": ENUM_VALUES}

    def _hover_at(self, doc, needle, index):
        contents = doc.hover(needle, offset=index - len(needle))["contents"]
        self.assertTrue(contents, f"hover on {needle!r} returned no contents")
        return contents[0]["value"]

    def test_a_valued_member_keeps_its_initializer(self):
        doc = self.open_doc("enum_values.d")
        self.assertEqual(self._hover_at(doc, "Red = 3", 1), "enum Color.Red = 3")

    def test_a_member_without_a_value_stays_bare(self):
        doc = self.open_doc("enum_values.d")
        self.assertEqual(self._hover_at(doc, "Green,", 1), "enum Color.Green")

    def test_the_enum_body_lists_each_member_with_its_value(self):
        doc = self.open_doc("enum_values.d")
        self.assertEqual(
            self._hover_at(doc, "enum Color", 5),
            "enum Color\n{\n    Red = 3,\n    Green,\n    Blue = 9,\n}",
        )
