"""Semantic tokens: what the server says each token in a file is.

The token types and modifiers are names from the legend the server sends with
``initialize`` (``semanticTokensProvider.legend``), and the tokens themselves
arrive the way LSP defines them: five numbers per token, each position
relative to the previous token.  These tests decode that the way a client
does, so both halves of the contract are covered: the legend the client has to
translate with, and the data it translates.
"""

from harness import DlsTestCase


SOURCE = """module app;

/* block
   comment */

struct State
{
    int valuea;
}

enum Color
{
    Red,
    Green,
}

void main()
{
    State state;
    state.valuea = 2;
    auto name = "text";
    // a comment
    return;
}
"""


class SemanticTokenTests(DlsTestCase):
    PROJECT = {
        "app.d": SOURCE,
        "unopened.d": "module unopened;\n\nvoid main() {}\n",
    }
    CLIENT_CAPABILITIES = {
        "textDocument": {
            "semanticTokens": {
                "requests": {"full": True},
                "tokenTypes": [],
                "tokenModifiers": [],
                "formats": ["relative"],
            }
        }
    }

    # -- decoding ----------------------------------------------------------

    def _legend(self):
        return (self.client.capabilities.get("semanticTokensProvider") or {}).get(
            "legend"
        ) or {}

    def _tokens(self, doc):
        """The document's tokens, decoded and named through the legend."""
        legend = self._legend()
        types = legend["tokenTypes"]
        modifiers = legend["tokenModifiers"]
        data = doc.semantic_tokens()["data"]

        tokens = []
        line = 0
        character = 0
        for i in range(0, len(data), 5):
            delta_line, delta_start, length, token_type, bits = data[i : i + 5]
            line += delta_line
            character = character + delta_start if delta_line == 0 else delta_start
            tokens.append(
                {
                    "line": line,
                    "character": character,
                    "length": length,
                    "type": types[token_type],
                    "modifiers": {
                        modifiers[bit]
                        for bit in range(len(modifiers))
                        if bits & (1 << bit)
                    },
                }
            )
        return tokens

    def _token(self, doc, tokens, needle, occurrence=0):
        """The token that starts where ``needle`` starts."""
        position = doc.position(needle, -len(needle), occurrence)
        for token in tokens:
            if (token["line"], token["character"]) == position:
                return token
        self.fail(
            f"no semantic token starts at {needle!r} {position}; got "
            + repr([(t["type"], t["line"], t["character"]) for t in tokens])
        )

    # -- the legend --------------------------------------------------------

    def test_the_legend_names_every_type_the_tokens_use(self):
        doc = self.open_doc("app.d")
        tokens = self._tokens(doc)

        for name in ("struct", "enum", "enumMember", "variable", "property",
                     "function", "type", "keyword", "comment", "string", "number",
                     "operator", "namespace"):
            self.assertIn(name, self._legend()["tokenTypes"])
        for token in tokens:
            self.assertIn(token["type"], self._legend()["tokenTypes"])
            self.assertTrue(token["modifiers"] <= set(self._legend()["tokenModifiers"]))
        self.assertIn("declaration", self._legend()["tokenModifiers"])

    # -- declarations ------------------------------------------------------

    def test_a_struct_and_its_field_are_declarations(self):
        doc = self.open_doc("app.d")
        tokens = self._tokens(doc)

        name = self._token(doc, tokens, "State")
        self.assertEqual(name["type"], "struct")
        self.assertIn("declaration", name["modifiers"])
        self.assertEqual(name["length"], len("State"))

        field = self._token(doc, tokens, "valuea")
        self.assertEqual(field["type"], "property")
        self.assertIn("declaration", field["modifiers"])

    def test_an_enum_and_its_members(self):
        doc = self.open_doc("app.d")
        tokens = self._tokens(doc)

        self.assertEqual(self._token(doc, tokens, "Color")["type"], "enum")
        self.assertEqual(self._token(doc, tokens, "Red")["type"], "enumMember")
        self.assertEqual(self._token(doc, tokens, "Green")["type"], "enumMember")

    def test_a_function_name_is_a_function(self):
        doc = self.open_doc("app.d")
        tokens = self._tokens(doc)

        main = self._token(doc, tokens, "main")
        self.assertEqual(main["type"], "function")
        self.assertIn("declaration", main["modifiers"])

    # -- references --------------------------------------------------------

    def test_a_type_use_is_a_struct_without_the_declaration_modifier(self):
        doc = self.open_doc("app.d")
        tokens = self._tokens(doc)

        # The second "State": the one in `State state;`.
        use = self._token(doc, tokens, "State state", occurrence=0)
        self.assertEqual(use["type"], "struct")
        self.assertNotIn("declaration", use["modifiers"])

    def test_a_variable_use_resolves_to_the_variable(self):
        doc = self.open_doc("app.d")
        tokens = self._tokens(doc)

        # The use in `state.valuea`, not the declaration in `State state;`.
        variable = self._token(doc, tokens, "state.valuea")
        self.assertEqual(variable["type"], "variable")
        self.assertNotIn("declaration", variable["modifiers"])

    def test_a_member_access_resolves_to_the_member(self):
        doc = self.open_doc("app.d")
        tokens = self._tokens(doc)

        self.assertEqual(self._token(doc, tokens, "valuea = 2")["type"], "property")

    # -- the rest of the file ----------------------------------------------

    def test_builtin_types_are_types_and_keywords_are_keywords(self):
        doc = self.open_doc("app.d")
        tokens = self._tokens(doc)

        self.assertEqual(self._token(doc, tokens, "int valuea")["type"], "type")
        self.assertEqual(self._token(doc, tokens, "void main")["type"], "type")
        self.assertEqual(self._token(doc, tokens, "return;")["type"], "keyword")
        self.assertEqual(self._token(doc, tokens, "struct State")["type"], "keyword")
        self.assertEqual(self._token(doc, tokens, "auto name")["type"], "keyword")

    def test_literals_are_numbers_and_strings(self):
        doc = self.open_doc("app.d")
        tokens = self._tokens(doc)

        number = self._token(doc, tokens, "2;")
        self.assertEqual(number["type"], "number")
        self.assertEqual(number["length"], len("2"))

        text = self._token(doc, tokens, '"text"')
        self.assertEqual(text["type"], "string")
        self.assertEqual(text["length"], len('"text"'))

    def test_comments_are_comment_tokens(self):
        doc = self.open_doc("app.d")
        tokens = self._tokens(doc)

        line_comment = self._token(doc, tokens, "// a comment")
        self.assertEqual(line_comment["type"], "comment")
        self.assertEqual(line_comment["length"], len("// a comment"))

        # A token cannot cross a line, so a block comment is one token per
        # line of it.
        first = self._token(doc, tokens, "/* block")
        second = self._token(doc, tokens, "   comment */")
        self.assertEqual(first["type"], "comment")
        self.assertEqual(second["type"], "comment")
        self.assertEqual(first["length"], len("/* block"))
        self.assertEqual(second["length"], len("   comment */"))

    def test_tokens_are_ordered_and_delta_encoded(self):
        doc = self.open_doc("app.d")
        data = doc.semantic_tokens()["data"]
        tokens = self._tokens(doc)

        self.assertEqual(len(data) % 5, 0)
        self.assertTrue(tokens, "no tokens were reported")
        positions = [(t["line"], t["character"]) for t in tokens]
        self.assertEqual(positions, sorted(positions))
        self.assertEqual(len(positions), len(set(positions)), "two tokens at one position")

    # -- requests that cannot be answered with tokens ----------------------

    def test_a_request_for_an_unopened_document_answers_with_no_tokens(self):
        # A client may ask before the server has a buffer for the file (or
        # after it was closed); an empty answer beats leaving it waiting.
        self.assertEqual(self._tokens(self.doc("unopened.d")), [])

    def test_a_range_request_answers_with_no_tokens(self):
        # The legend advertises `full` only, so a range request has to answer
        # (with nothing) instead of timing out.
        doc = self.open_doc("app.d")
        result = self.client.request(
            "textDocument/semanticTokens/range",
            {
                "textDocument": {"uri": doc.uri},
                "range": {
                    "start": {"line": 0, "character": 0},
                    "end": {"line": 1, "character": 0},
                },
            },
        )
        self.assertEqual(result["data"], [])
