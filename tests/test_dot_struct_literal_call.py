"""Contextual completion/help through `.{...}` in call arguments."""

from harness import DlsTestCase, labels

SRC = """module app;

enum Foo { A, B, C }

struct Bar
{
    Foo foo;
    Foo bar2;
    int n;
}

void pass(Bar bar) {}
void pass2(Bar a, Bar b) {}
Bar gbar;

void main()
{
    pass(gbar);
    pass(.{});
    pass(.{.});
    pass2(.{}, .{.});
    pass(.{foo: .});
    pass(.{n: 1, .});
    pass(.{f});
}
"""


class DotStructLiteralCallTests(DlsTestCase):
    PROJECT = {"app.d": SRC}

    def fields(self, needle: str) -> list[str]:
        doc = self.open_doc("app.d")
        return sorted(labels(doc.completion(needle)["items"]))

    def members(self, needle: str) -> list[str]:
        doc = self.open_doc("app.d")
        return sorted(labels(doc.completion(needle)["items"]))

    def signatures(self, needle: str) -> list[str]:
        doc = self.open_doc("app.d")
        sh = doc.signature_help(needle)
        return [s["label"] for s in sh.get("signatures", [])]

    def test_fields_inside_literal_argument(self):
        self.assertEqual(self.fields("pass(.{"), ["bar2", "foo", "n"])

    def test_partial_field_inside_literal_argument(self):
        self.assertEqual(self.fields("pass(.{f"), ["foo"])

    def test_enum_member_inside_positional_field(self):
        self.assertEqual(self.members("pass(.{."), ["A", "B", "C"])

    def test_enum_member_inside_named_field(self):
        self.assertEqual(self.members("pass(.{foo: ."), ["A", "B", "C"])

    def test_enum_member_inside_second_literal(self):
        self.assertEqual(self.members("pass2(.{}, .{."), ["A", "B", "C"])

    def test_signature_help_after_typed_argument(self):
        self.assertEqual(self.signatures("pass(gbar"), ["void pass(Bar bar)"])

    def test_signature_help_inside_literal(self):
        self.assertEqual(self.signatures("pass(.{."), ["void pass(Bar bar)"])

    def test_signature_help_for_named_fields(self):
        self.assertEqual(self.signatures("pass(.{n: 1, "), ["void pass(Bar bar)"])
