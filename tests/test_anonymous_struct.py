"""Named variables of anonymous struct type (``struct { ... } name;``)."""

from harness import KIND_FIELD, DlsTestCase, find_item, labels


def outer(body: str) -> str:
    return f"""module app;

struct Outer
{{
    struct {{ int x; int y; }} pos;
}}

void main()
{{
    Outer o;
{body}
}}
"""


class AnonymousStructVariableTests(DlsTestCase):
    PROJECT = {
        "member.d": outer("    o.pos.x"),
        "all_members.d": outer("    o.pos."),
        "not_flattened.d": outer("    o.x"),
    }

    def test_member_of_anonymous_struct_variable(self):
        doc = self.open_doc("member.d")
        items = doc.completion("o.pos.x")["items"]

        field = find_item(items, "x")
        self.assertEqual(field["kind"], KIND_FIELD)
        self.assertEqual(field["labelDetails"]["description"], "int")

    def test_all_anonymous_struct_members_are_exposed(self):
        doc = self.open_doc("all_members.d")
        found = labels(doc.completion("o.pos.")["items"])
        self.assertIn("x", found)
        self.assertIn("y", found)

    def test_anonymous_struct_members_are_not_flattened_into_the_parent(self):
        doc = self.open_doc("not_flattened.d")
        self.assertNotIn("x", labels(doc.completion("o.x")["items"]))
