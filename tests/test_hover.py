"""Hover responses: type of a variable, source of a type."""

from harness import DlsTestCase


SOURCE = """module app;

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


class HoverTests(DlsTestCase):
    PROJECT = {"app.d": SOURCE}

    def _hover_text(self, doc, needle, offset=0):
        result = doc.hover(needle, offset)
        contents = result["contents"]
        self.assertTrue(contents, "hover returned no contents")
        return "\n".join(entry["value"] for entry in contents)

    def test_hover_on_variable_reports_its_type(self):
        doc = self.open_doc("app.d")
        # Hover inside the "st" of the "st.aa" expression.
        text = self._hover_text(doc, "st.aa", offset=-len("st.aa") + 1)
        self.assertIn("State", text)

    def test_hover_contents_are_marked_as_d(self):
        doc = self.open_doc("app.d")
        result = doc.hover("st.aa", offset=-len("st.aa") + 1)
        for entry in result["contents"]:
            self.assertEqual(entry["language"], "d")
            self.assertIsInstance(entry["value"], str)

    def test_hover_on_type_name_returns_its_definition(self):
        doc = self.open_doc("app.d")
        # Hover on the "State" in the variable declaration.
        text = self._hover_text(doc, "State st;", offset=-len("State st;") + 2)
        self.assertIn("struct State", text)
        self.assertIn("aaa", text)
