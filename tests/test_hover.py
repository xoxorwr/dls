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

TEMPLATED = """module app;

struct TD(T)
{
    T data;
}

union UD(T)
{
    T a;
    int b;
}

void main()
{
    TD!int x;
}
"""

TEMPLATE_SHAPES = """module app;

struct Constrained(T : int)
{
    T data;
}

struct Triple(A, B, C)
{
    A a;
    B b;
    C c;
}
"""


class HoverTests(DlsTestCase):
    PROJECT = {"app.d": SOURCE, "templated.d": TEMPLATED, "shapes.d": TEMPLATE_SHAPES}

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

    def test_hover_on_a_templated_struct_keeps_its_parameter_list(self):
        """Regression: a templated struct's/union's hover text used to
        strip its template parameter list entirely - `struct TD(T)` hovered
        as plain `struct TD`, indistinguishable from a non-templated one.
        """
        doc = self.open_doc("templated.d")
        # Land on the 'D' of "TD" in "struct TD(T)".
        text = self._hover_text(doc, "struct TD(T)", offset=-len("struct TD(T)") + 8)
        self.assertIn("struct TD(T)", text)

        # Land on the 'D' of "UD" in "union UD(T)".
        text = self._hover_text(doc, "union UD(T)", offset=-len("union UD(T)") + 7)
        self.assertIn("union UD(T)", text)

    def test_hover_on_a_templated_struct_usage_keeps_its_parameter_list(self):
        doc = self.open_doc("templated.d")
        # Land on the 'D' of "TD" in "TD!int x;".
        text = self._hover_text(doc, "TD!int x;", offset=-len("TD!int x;") + 1)
        self.assertIn("struct TD(T)", text)

    def test_hover_on_a_templated_struct_usage_keeps_the_generic_body(self):
        """Not a substitution: hovering the type name at a use site
        (`TD!int x`) shows the *declaration's* body, `T data;`, not `int
        data;` - true before the migration off `callTip` too
        (`instantiated.callTip = s.callTip` was already an unconditional
        copy of the generic string, with no substitution logic), and still
        true now that `instantiateAggregate` (`second.d`) shares the same
        `Signature` pointer instead. Pinned so a future change to that
        sharing doesn't silently start rendering a half-substituted body.
        """
        doc = self.open_doc("templated.d")
        text = self._hover_text(doc, "TD!int x;", offset=-len("TD!int x;") + 1)
        self.assertIn("T data", text)

    def test_hover_on_a_constrained_template_parameter_keeps_the_constraint(self):
        doc = self.open_doc("shapes.d")
        text = self._hover_text(
            doc, "struct Constrained(T : int)",
            offset=-len("struct Constrained(T : int)") + len("struct ") + 1,
        )
        self.assertIn("struct Constrained(T : int)", text)

    def test_hover_on_multiple_type_parameters_keeps_declaration_order(self):
        """Regression: opSlice() does not hand symbols back in declaration
        order, so a naive rebuild of the parameter list from it can come out
        scrambled (`Triple(C, A, B)`) rather than as declared.
        """
        doc = self.open_doc("shapes.d")
        text = self._hover_text(
            doc, "struct Triple(A, B, C)",
            offset=-len("struct Triple(A, B, C)") + len("struct ") + 1,
        )
        self.assertIn("struct Triple(A, B, C)", text)
