"""textDocument/definition: jump from a use to its declaration."""

from harness import DlsTestCase


SOURCE = """module app;

struct State
{
    int aaa;
}

int compute(int x) { return x; }

void main()
{
    State st;
    st.aa
    compute(1);
}
"""


class DefinitionTests(DlsTestCase):
    PROJECT = {"app.d": SOURCE}

    def test_definition_returns_locations_with_ranges(self):
        doc = self.open_doc("app.d")
        # Cursor on the "st" of "st.aa".
        locations = doc.definition("st.aa", offset=-3)

        self.assertIsInstance(locations, list)
        self.assertTrue(locations, "definition returned no location")
        location = locations[0]
        self.assertEqual(location["uri"], doc.uri)
        start = location["range"]["start"]
        end = location["range"]["end"]
        self.assertLessEqual((start["line"], start["character"]), (end["line"], end["character"]))

    def test_definition_of_variable_points_at_its_type_declaration(self):
        doc = self.open_doc("app.d")
        locations = doc.definition("st.aa", offset=-3)

        # Position right after "struct ", i.e. on the declaration name.
        offset = len("struct ") - len("struct State")
        expected_line, expected_character = doc.position("struct State", offset=offset)
        self.assertEqual(locations[0]["range"]["start"]["line"], expected_line)
        self.assertEqual(locations[0]["range"]["start"]["character"], expected_character)

    def test_definition_on_non_symbol_returns_no_location(self):
        doc = self.open_doc("app.d")
        line, character = doc.position("module app;", offset=-len("module app;"))
        locations = self.client.definition(doc.uri, line, character)
        self.assertEqual(locations, [])
