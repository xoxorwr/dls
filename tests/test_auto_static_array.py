"""Inferred static arrays: `auto[$]`, `auto[n]` and `int[$]`.

dmd infers the static shape from the initializer (`auto[$] a = [1, 2]` is
`int[2]`), which needs no GC and is the `-betterC` way to write the
`auto a = [...]` from the original report. The server has to do the same:
`auto[$]` parses as a declared type (not an `AutoDeclaration`), and the
`$` / `auto` it names only resolve together with the initializer.
"""

from harness import DlsTestCase, labels


SOURCE = """module auto_static_array;

struct Widget
{
    int size;
}

Widget global_widget;

void main()
{
    auto[$] arrAuto = [1, 2];
    arrAuto.le
    int[$] arrInt = [1, 2, 3];
    arrInt.le
    auto[3] arrExplicit = [1, 2, 3];
    arrExplicit.le
    auto[$] widgets = [global_widget, global_widget];
    widgets[0].si
    auto[$][$] nested = [[1, 2], [3, 4]];
    nested.le
    auto[$] attrs = ["a_position", "a_normal"];
    attrs.le
}
"""


class AutoStaticArrayTests(DlsTestCase):
    PROJECT = {"auto_static_array.d": SOURCE}

    def test_auto_dollar_completes_array_properties(self):
        """`arrAuto.le` offers `length`: the shape resolved as a static array."""
        doc = self.open_doc("auto_static_array.d")
        self.assertIn("length", labels(doc.completion("arrAuto.le")["items"]))

    def test_int_dollar_completes_array_properties(self):
        doc = self.open_doc("auto_static_array.d")
        self.assertIn("length", labels(doc.completion("arrInt.le")["items"]))

    def test_auto_explicit_dim_completes_array_properties(self):
        """`auto[3]` infers only the element; the shape still resolves."""
        doc = self.open_doc("auto_static_array.d")
        self.assertIn("length", labels(doc.completion("arrExplicit.le")["items"]))

    def test_indexed_element_completes_members(self):
        """`widgets[0].si` steps through the inferred array into `Widget`."""
        doc = self.open_doc("auto_static_array.d")
        self.assertIn("size", labels(doc.completion("widgets[0].si")["items"]))

    def test_nested_completes_array_properties(self):
        doc = self.open_doc("auto_static_array.d")
        self.assertIn("length", labels(doc.completion("nested.le")["items"]))

    def test_string_literal_element_completes(self):
        doc = self.open_doc("auto_static_array.d")
        self.assertIn("length", labels(doc.completion("attrs.le")["items"]))

    def _hover_text(self, doc, needle, occurrence=0):
        result = doc.hover(needle, occurrence=occurrence)
        contents = result["contents"]
        self.assertTrue(contents, f"hover on {needle!r} returned nothing")
        return "\n".join(entry["value"] for entry in contents)

    def test_hover_shows_inferred_int_static_array(self):
        doc = self.open_doc("auto_static_array.d")
        self.assertIn("int[2] arrAuto;", self._hover_text(doc, "arrAuto"))

    def test_hover_resolves_dollar_to_length(self):
        """`int[$]` hovers as the inferred `int[3]`, not `int[]`."""
        doc = self.open_doc("auto_static_array.d")
        self.assertIn("int[3] arrInt;", self._hover_text(doc, "arrInt"))

    def test_hover_shows_explicit_dim_with_inferred_element(self):
        doc = self.open_doc("auto_static_array.d")
        self.assertIn("int[3] arrExplicit;", self._hover_text(doc, "arrExplicit"))

    def test_hover_shows_struct_element_static_array(self):
        doc = self.open_doc("auto_static_array.d")
        self.assertIn("Widget[2] widgets;", self._hover_text(doc, "widgets"))

    def test_hover_shows_nested_static_array(self):
        doc = self.open_doc("auto_static_array.d")
        self.assertIn("int[2][2] nested;", self._hover_text(doc, "nested"))

    def test_hover_shows_string_static_array(self):
        doc = self.open_doc("auto_static_array.d")
        self.assertIn("string[2] attrs;", self._hover_text(doc, "attrs"))

    def test_hover_on_auto_keyword_shows_inferred_array(self):
        """Hovering the `auto` of `auto[$]` answers like the variable itself."""
        doc = self.open_doc("auto_static_array.d")
        needle = "auto[$] arrAuto"
        line, character = doc.position(needle, offset=1 - len(needle))
        result = self.client.hover(doc.uri, line, character)
        contents = result["contents"]
        self.assertTrue(contents, "hover on `auto` returned nothing")
        text = "\n".join(entry["value"] for entry in contents)
        self.assertIn("int[2] arrAuto;", text)

    def test_definition_on_use_points_at_declaration(self):
        doc = self.open_doc("auto_static_array.d")
        locations = doc.definition("widgets[0].si", offset=-9)
        self.assertTrue(locations, "definition returned no location")
        self.assertEqual(locations[0]["uri"], doc.uri)
        expected_line, _ = doc.position("auto[$] widgets")
        self.assertEqual(locations[0]["range"]["start"]["line"], expected_line)
