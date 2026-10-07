"""Context-sensitive aggregate literal ``. (args)`` (the fork's dot syntax)."""

from harness import DlsTestCase, labels

DECLS = """module app;

struct Vec2 { float x; float y; }
struct State { Vec2 pos; }
"""


def with_main(body: str) -> str:
    return DECLS + f"""
void main()
{{
    State state;
{body}
}}
"""


class DotStructLiteralTests(DlsTestCase):
    PROJECT = {
        "empty.d": with_main("    state.pos = .("),
        "positional.d": with_main("    state.pos = .(1.0, "),
        "named.d": with_main("    state.pos = .(x: "),
        # A complete statement using the syntax; completion on the next line must
        # still work, i.e. the parser no longer chokes on `.()`.
        "complete.d": DECLS
        + """
void main()
{
    State state;
    state.pos = .(1.0, 2.0);
    state.
}
""",
    }

    def fields_after(self, relpath: str, needle: str) -> list[str]:
        doc = self.open_doc(relpath)
        return sorted(labels(doc.completion(needle)["items"]))

    def test_assignment_lists_the_expected_fields(self):
        self.assertEqual(self.fields_after("empty.d", "state.pos = .("), ["x", "y"])

    def test_positional_argument_still_lists_the_fields(self):
        self.assertEqual(self.fields_after("positional.d", "state.pos = .(1.0, "), ["x", "y"])

    def test_named_argument_still_lists_the_fields(self):
        self.assertEqual(self.fields_after("named.d", "state.pos = .(x: "), ["x", "y"])

    def test_parses_and_completes_after_a_complete_literal(self):
        items = self.fields_after("complete.d", "state.")
        self.assertIn("pos", items)


class DotStructLiteralParserTests(DlsTestCase):
    """The literal is understood as an expression, not just skipped."""

    PROJECT = {
        "app.d": """module app;

struct Vec2 { float x; float y; }
struct State { Vec2 pos; }

void main()
{
    State state;
    state.pos = .(1.0, 2.0);
    state.
}
"""
    }

    def test_member_completion_after_literal(self):
        doc = self.open_doc("app.d")
        items = labels(doc.completion("state.")["items"])
        self.assertIn("pos", items)
