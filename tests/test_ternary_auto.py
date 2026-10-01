"""``auto x = cond ? a : b;`` -- a value that is one of two types.

D's own rule is that a ternary has a single static type (the common type of its
branches), so two unrelated structs do not compile; "either" is the state an
editor sees mid-edit, or when the common type needs a conversion the walker
does not model.  What the tool can usefully do there is offer both candidates'
members and say which candidate each item came from.
"""

from harness import DlsTestCase

LIB_A = """module lib_a;

struct TypeA
{
    int aaa;
    int shared_name;
}

TypeA make_a()
{
    return TypeA();
}
"""

LIB_B = """module lib_b;

struct TypeB
{
    int bbb;
    int shared_name;
}

TypeB make_b()
{
    return TypeB();
}
"""

APP = """module app;

import lib_a;
import lib_b;

struct Local
{
    int loc;
}

void main()
{
    bool is_true;
    Local l;
    auto what = is_true ? make_a() : make_b();
    auto same = is_true ? make_a() : make_a();
    auto mixed = is_true ? make_a() : l;
    auto from_init = is_true ? make_a() : Local.init;
    what.si
    same.si
    mixed.si
    from_init.si
}
"""

REVERSED = APP.replace("make_a() : make_b()", "make_b() : make_a()")

DIFF = """module diff;

struct TypeA
{
    int same;
}

struct TypeB
{
    float same;
}

TypeA make_a()
{
    return TypeA();
}

TypeB make_b()
{
    return TypeB();
}

void main()
{
    bool is_true;
    auto what = is_true ? make_a() : make_b();
    what.sa
}
"""


class TernaryAutoTests(DlsTestCase):
    PROJECT = {
        "lib_a.d": LIB_A,
        "lib_b.d": LIB_B,
        "app.d": APP,
        "reversed.d": REVERSED,
        "diff.d": DIFF,
    }

    def _items(self, doc, needle):
        return doc.completion(needle, 0)["items"]

    def _label(self, doc, needle, label):
        return [item for item in self._items(doc, needle) if item["label"] == label]

    def _hover(self, doc, needle, char=1):
        contents = doc.hover(needle, offset=char - len(needle))["contents"]
        self.assertTrue(contents, f"hover on {needle!r} was empty")
        return "\n".join(entry["value"] for entry in contents)

    def test_members_of_both_candidates_are_offered(self):
        doc = self.open_doc("app.d")
        labels = [item["label"] for item in self._items(doc, "what.")]
        self.assertIn("aaa", labels)
        self.assertIn("bbb", labels)

    def test_member_on_both_candidates_is_one_entry_naming_both(self):
        doc = self.open_doc("app.d")
        shared = self._label(doc, "what.", "shared_name")
        self.assertEqual(len(shared), 1)
        self.assertEqual(shared[0]["detail"], "TypeA | TypeB")

    def test_a_member_the_candidates_disagree_about_is_one_entry_each(self):
        doc = self.open_doc("diff.d")
        same = self._label(doc, "what.", "same")
        self.assertEqual(sorted(item["detail"] for item in same), ["TypeA", "TypeB"])
        self.assertEqual(
            sorted(item["labelDetails"]["description"].split(" from ")[0] for item in same),
            ["float", "int"])

    def test_the_origin_is_visible_in_the_row(self):
        """The origin goes in the label's inline description, not only in the
        item `detail`, which clients show in the documentation pane."""
        doc = self.open_doc("app.d")
        shared = self._label(doc, "what.", "shared_name")[0]
        self.assertEqual(shared["labelDetails"]["description"], "int from TypeA | TypeB")

    def test_unique_members_name_their_own_candidate(self):
        doc = self.open_doc("app.d")
        self.assertEqual(self._label(doc, "what.", "aaa")[0]["detail"], "TypeA")
        self.assertEqual(self._label(doc, "what.", "bbb")[0]["detail"], "TypeB")

    def test_the_value_reports_both_types(self):
        doc = self.open_doc("app.d")
        what = self._label(doc, "auto what", "what")[0]
        self.assertEqual(what["labelDetails"]["description"], "TypeA | TypeB")

    def test_hover_reports_both_types(self):
        doc = self.open_doc("app.d")
        self.assertIn("TypeA | TypeB", self._hover(doc, "what = is_true"))

    def test_hover_on_auto_reports_both_types(self):
        doc = self.open_doc("app.d")
        self.assertIn("TypeA | TypeB", self._hover(doc, "auto what"))

    def test_branch_order_does_not_matter(self):
        direct = [item["label"] for item in self._items(self.open_doc("app.d"), "what.")]
        other = [item["label"] for item in self._items(self.open_doc("reversed.d"), "what.")]
        self.assertEqual(sorted(direct), sorted(other))

    def test_the_same_type_on_both_sides_is_not_ambiguous(self):
        doc = self.open_doc("app.d")
        same = self._label(doc, "auto same", "same")[0]
        self.assertEqual(same["labelDetails"]["description"], "TypeA")
        self.assertIn("struct TypeA", self._hover(doc, "same = is_true"))

    def test_a_local_branch_keeps_its_declared_name(self):
        doc = self.open_doc("app.d")
        self.assertIn("TypeA | Local", self._hover(doc, "mixed = is_true"))
        self.assertEqual(self._label(doc, "mixed.", "loc")[0]["detail"], "Local")

    def test_a_type_property_is_a_value_of_its_own_type(self):
        """`cond ? make_a() : Local.init` -- `T.init` is a `T`, not a symbol
        named `init`."""
        doc = self.open_doc("app.d")
        self.assertIn("TypeA | Local", self._hover(doc, "from_init = is_true"))
        self.assertEqual(self._label(doc, "from_init.", "loc")[0]["detail"], "Local")
