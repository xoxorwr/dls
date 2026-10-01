"""A unary `!` is not part of the token chain that follows it.

`if (!cook_all(state.scratch, heap))` made dls resolve the chain
`[!, cook_all]`: hover, go-to-definition and completion all came back empty,
because the resolver looked up a symbol literally named `!` and gave up on
the whole chain.  A `!` belongs to the expression only as the template
instantiation operator (`get!int()`), which is what `getExpression` keeps it
for; that side is covered by `test_template_functions.py` and by the last
test here.

It is the unary operator that has to stop the chain, wherever it sits: at
the head of a call, in front of a member access, or behind `&&`.
"""

from harness import DlsTestCase, labels


SOURCE = """module app;

int callee(int a) { return a; }

int ignore(int a) { return a; }

struct S
{
    int field;
}

T get(T)() { return T.init; }

void main()
{
    if (callee(1)) {}
    if (!callee(1)) {}
    bool b = !callee(1);
    bool c = true && !callee(2);
    S s;
    if (!s.field) {}
    get!int().si
    if (!igno) {}
}
"""


class UnaryNotChainTests(DlsTestCase):
    PROJECT = {"app.d": SOURCE}

    def _hover_text(self, doc, needle, occurrence=0):
        """Hover with the cursor right after `needle`, which is cut so that
        it lands *inside* the identifier under test."""
        result = doc.hover(needle, occurrence=occurrence)
        contents = result["contents"]
        self.assertTrue(contents, f"hover on {needle!r} returned no contents")
        return "\n".join(entry["value"] for entry in contents)

    def _declaration_line(self, doc, needle, occurrence=0):
        """The line the declaration of `needle` sits on."""
        locations = doc.definition(needle, occurrence=occurrence)
        self.assertTrue(locations, f"definition of {needle!r} returned no location")
        return locations[0]["range"]["start"]["line"]

    def test_hover_inside_the_negated_call_finds_the_callee(self):
        doc = self.open_doc("app.d")
        # "!cal" stops inside the "callee" of "if (!callee(1))".
        text = self._hover_text(doc, "!cal")
        self.assertIn("int callee(int a)", text)

    def test_definition_inside_the_negated_call_points_at_the_declaration(self):
        doc = self.open_doc("app.d")
        line, character = doc.position("!cal")
        locations = doc.client.definition(doc.uri, line, character)
        self.assertTrue(locations, "definition inside a negated call returned nothing")

        expected_line, _ = doc.position("int callee(int a)")
        self.assertEqual(locations[0]["range"]["start"]["line"], expected_line)

    def test_hover_on_the_member_of_a_negated_expression_finds_it(self):
        doc = self.open_doc("app.d")
        # "!s.fi" stops inside the "field" of "if (!s.field)".
        text = self._hover_text(doc, "!s.fi")
        self.assertIn("int field", text)

    def test_definition_on_the_member_of_a_negated_expression(self):
        doc = self.open_doc("app.d")
        expected_line, _ = doc.position("int field;")
        self.assertEqual(self._declaration_line(doc, "!s.fi"), expected_line)

    def test_hover_behind_a_logical_and_still_finds_the_callee(self):
        """`a && !callee(2)` -- the operator before the `!` is not a `(`."""
        doc = self.open_doc("app.d")
        text = self._hover_text(doc, "&& !cal")
        self.assertIn("int callee(int a)", text)

    def test_completion_after_a_unary_not_lists_scope_symbols(self):
        """The same chain used to eat the completion list: it went through
        `getSymbolsByTokenChain` with `[!]` left in front of the partial name
        instead of falling back to the names in scope."""
        doc = self.open_doc("app.d")
        items = doc.completion("!igno")["items"]
        self.assertIn("ignore", labels(items))

    def test_template_instance_after_a_unary_not_is_still_one_chain(self):
        """`get!int().si` resolves through the `!` to the chain's callee; the
        fix only drops a `!` that is *not* preceded by the template's name."""
        doc = self.open_doc("app.d")
        items = doc.completion("get!int().si")["items"]
        self.assertIn("sizeof", labels(items))
