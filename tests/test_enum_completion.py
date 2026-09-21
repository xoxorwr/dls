"""Dot-shorthand enum completion (``.MEMBER`` with the type inferred)."""

from harness import KIND_ENUM_MEMBER, DlsTestCase, labels


ENUM = "enum Color { Red, Green, Blue }\n"

MEMBER = """module app;

enum Color { Red, Green, Blue }

struct Motor
{
    Color speed_tier;
}

void main()
{
    Motor motor;
    motor.speed_tier = .Gr
}
"""

# The parameter the dot-shorthand stands for comes *after* an argument that
# contains a comma of its own: `S{1, 2}`.  Counting commas in the token stream
# used to mistake that inner comma for an argument separator and ask for
# parameter 2, which does not exist.
STRUCT_LITERAL_ARGUMENT = """module app;

enum Color { Red, Green, Blue }

struct S { int a; int b; }

void paint(S s, Color c) {}

void main()
{
    paint(S{1, 2}, .Bl)
}
"""

COMPARISON_WITHOUT_IDENTIFIER = """module app;

enum Color { Red, Green, Blue }

void main()
{
    Color c = Color.Red;
    if (c == .)
}
"""

CALL_IN_ASSIGNMENT = """module app;

enum Color { Red, Green, Blue }

Color pick(Color c) { return c; }

void main()
{
    Color c = Color.Red;
    c = pick(.Bl)
}
"""

CALL_IN_THE_LEFT_HAND_SIDE = """module app;

enum Color { Red, Green, Blue }

struct Motor
{
    Color speed_tier;
}

Motor makeMotor()
{
    Motor motor;
    return motor;
}

void main()
{
    makeMotor().speed_tier = .Gr
}
"""


def wrap(body: str) -> str:
    return f"""module app;

{ENUM}
void paint(Color c) {{}}

void main()
{{
    Color c = Color.Red;
{body}
}}
"""


class EnumDotShorthandTests(DlsTestCase):
    PROJECT = {
        "assign_prefix.d": wrap("    c = .Gr"),
        "assign_empty.d": wrap("    c = ."),
        "compare.d": wrap("    if (c == .Gr)"),
        "argument.d": wrap("    paint(.Bl)"),
        "member_assign.d": MEMBER,
        "struct_literal_argument.d": STRUCT_LITERAL_ARGUMENT,
        "comparison_no_identifier.d": COMPARISON_WITHOUT_IDENTIFIER,
        "call_in_assignment.d": CALL_IN_ASSIGNMENT,
        "call_in_lhs.d": CALL_IN_THE_LEFT_HAND_SIDE,
    }

    def test_assignment_with_partial_identifier(self):
        doc = self.open_doc("assign_prefix.d")
        items = doc.completion("c = .Gr")["items"]
        self.assertEqual(labels(items), ["Green"])

    def test_assignment_without_identifier_lists_every_member(self):
        doc = self.open_doc("assign_empty.d")
        items = doc.completion("c = .")["items"]

        members = {item["label"]: item for item in items}
        self.assertEqual(set(members), {"Red", "Green", "Blue"})
        for item in members.values():
            self.assertEqual(item["kind"], KIND_ENUM_MEMBER)

    def test_comparison_resolves_the_expected_enum(self):
        doc = self.open_doc("compare.d")
        items = doc.completion("c == .Gr")["items"]
        self.assertEqual(labels(items), ["Green"])

    def test_function_argument_resolves_the_expected_enum(self):
        doc = self.open_doc("argument.d")
        items = doc.completion("paint(.Bl")["items"]
        self.assertEqual(labels(items), ["Blue"])

    def test_member_assignment_resolves_the_expected_enum(self):
        """The LHS is a member chain: `motor.speed_tier = .Gr`.

        Resolved from the request's syntax tree (the assignment's left hand
        side and a typed path through it), not by scanning tokens backwards.
        """
        doc = self.open_doc("member_assign.d")
        items = doc.completion("motor.speed_tier = .Gr")["items"]
        self.assertEqual(labels(items), ["Green"])

    def test_argument_after_a_struct_literal_resolves_the_expected_enum(self):
        """A comma inside `S{1, 2}` is not an argument separator."""
        doc = self.open_doc("struct_literal_argument.d")
        items = doc.completion("paint(S{1, 2}, .Bl")["items"]
        self.assertEqual(labels(items), ["Blue"])

    def test_comparison_without_identifier_lists_every_member(self):
        """`if (c == .)` -- a bare dot whose statement has no `;` yet.

        The parser used to drop the condition (missing semicolon, failed right
        hand side), so the expected type had to be inferred from tokens.
        """
        doc = self.open_doc("comparison_no_identifier.d")
        items = doc.completion("c == .")["items"]
        members = {item["label"]: item for item in items}
        self.assertEqual(set(members), {"Red", "Green", "Blue"})
        for item in members.values():
            self.assertEqual(item["kind"], KIND_ENUM_MEMBER)

    def test_call_argument_inside_an_assignment_resolves_the_expected_enum(self):
        """`c = pick(.Bl` -- the call node and the argument index come from the
        request's tree."""
        doc = self.open_doc("call_in_assignment.d")
        items = doc.completion("pick(.Bl")["items"]
        self.assertEqual(labels(items), ["Blue"])

    def test_call_in_the_left_hand_side_resolves_the_expected_enum(self):
        """`makeMotor().speed_tier = .Gr` -- the typed path has to apply a call.

        The path is `makeMotor` (a function) → call (its return type) →
        `speed_tier`; without the call step the resolver has nothing to work
        with and the completion falls back to scanning tokens.
        """
        doc = self.open_doc("call_in_lhs.d")
        items = doc.completion("makeMotor().speed_tier = .Gr")["items"]
        self.assertEqual(labels(items), ["Green"])
