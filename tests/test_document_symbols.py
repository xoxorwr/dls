"""textDocument/documentSymbol: outline of the current file."""

from harness import KIND_FUNCTION, KIND_STRUCT, DlsTestCase


SOURCE = """module app;

struct State
{
    int aaa;
}

class Widget
{
    void draw() {}
}

int compute(int x) { return x; }

void main()
{
    State st;
    st.aaa = compute(1);
}
"""


class DocumentSymbolTests(DlsTestCase):
    PROJECT = {"app.d": SOURCE}

    def setUp(self):
        self.doc = self.open_doc("app.d")
        self.symbols = {symbol["name"]: symbol for symbol in self.doc.document_symbols()}

    def test_top_level_symbols_are_reported_with_kinds(self):
        self.assertIn("State", self.symbols)
        self.assertIn("main", self.symbols)
        self.assertIn("compute", self.symbols)

        self.assertEqual(self.symbols["State"]["kind"], KIND_STRUCT)
        self.assertEqual(self.symbols["main"]["kind"], KIND_FUNCTION)
        self.assertEqual(self.symbols["compute"]["kind"], KIND_FUNCTION)

    def test_symbol_ranges_are_ordered_and_inside_the_file(self):
        line_count = self.doc.text.count("\n")
        for name, symbol in self.symbols.items():
            start = symbol["range"]["start"]
            end = symbol["range"]["end"]
            self.assertLessEqual(start["line"], end["line"], msg=name)
            self.assertLessEqual(end["line"], line_count, msg=name)
            self.assertGreaterEqual(start["character"], 0, msg=name)

    def test_selection_range_is_present(self):
        for name, symbol in self.symbols.items():
            self.assertIn("selectionRange", symbol, msg=name)
            self.assertIn("start", symbol["selectionRange"], msg=name)
            self.assertIn("end", symbol["selectionRange"], msg=name)

    def test_struct_range_covers_its_body(self):
        state = self.symbols["State"]
        declaration_line, _ = self.doc.position("struct State")
        closing_line, _ = self.doc.position("    int aaa;\n}")
        self.assertEqual(state["range"]["start"]["line"], declaration_line)
        self.assertEqual(state["range"]["end"]["line"], closing_line)
