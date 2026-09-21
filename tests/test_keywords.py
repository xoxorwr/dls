"""Keyword completion: the forms whose argument list DCD completes.

``__traits(`` and ``pragma(`` are filled from ``dcd.common.constants2``, which
``dcd_templates/constants-gen`` generates from the spec's ``traits.dd`` and
``pragma.dd``.
"""

from harness import KIND_KEYWORD, DlsTestCase, find_item, labels


SOURCE = """module app;

void main()
{
    %s
}
"""


class KeywordArgumentListTests(DlsTestCase):
    PROJECT = {
        "prefix.d": SOURCE % "__tra",
        "traits.d": SOURCE % "__traits()",
        "trait_arg.d": SOURCE % "__traits(g",
        "pragma.d": SOURCE % "pragma()",
        "pragma_arg.d": SOURCE % "pragma(i",
        "version.d": SOURCE % "version()",
        "version_arg.d": SOURCE % "version(D_",
        "version_prefix.d": SOURCE % "vers",
    }

    def test_a_partial_keyword_is_offered(self):
        doc = self.open_doc("prefix.d")
        item = find_item(doc.completion("__tra")["items"], "__traits")
        self.assertEqual(item["kind"], KIND_KEYWORD)

    def test_the_trait_list_follows_the_open_paren(self):
        doc = self.open_doc("traits.d")
        found = labels(doc.completion("__traits(")["items"])
        self.assertIn("allMembers", found)
        self.assertIn("compiles", found)
        self.assertIn("getMember", found)

    def test_the_trait_list_is_filtered_by_the_typed_prefix(self):
        # Cursor after the "g" of "__traits(g".
        doc = self.open_doc("trait_arg.d")
        found = labels(doc.completion("__traits(g")["items"])
        self.assertIn("getMember", found)
        self.assertIn("getOverloads", found)
        self.assertNotIn("allMembers", found)

    def test_the_pragma_list_follows_the_open_paren(self):
        doc = self.open_doc("pragma.d")
        found = labels(doc.completion("pragma(")["items"])
        self.assertIn("inline", found)
        self.assertIn("msg", found)

    def test_the_pragma_list_is_filtered_by_the_typed_prefix(self):
        doc = self.open_doc("pragma_arg.d")
        found = labels(doc.completion("pragma(i")["items"])
        self.assertEqual(found, ["inline"])

    def test_the_predefined_versions_follow_the_open_paren(self):
        doc = self.open_doc("version.d")
        found = labels(doc.completion("version(")["items"])
        self.assertIn("X86_64", found)
        self.assertIn("Posix", found)

    def test_the_predefined_versions_are_filtered_by_the_typed_prefix(self):
        doc = self.open_doc("version_arg.d")
        found = labels(doc.completion("version(D_")["items"])
        self.assertIn("D_Version2", found)
        self.assertNotIn("X86_64", found)

    def test_the_version_keyword_is_offered_by_prefix(self):
        doc = self.open_doc("version_prefix.d")
        item = find_item(doc.completion("vers")["items"], "version")
        self.assertEqual(item["kind"], KIND_KEYWORD)

    def test_a_request_does_not_corrupt_the_buffer_for_the_next_one(self):
        # Several requests on one document, with no edit in between: DCD's
        # incomplete-statement hack writes a ';' over whatever sits at the
        # cursor, and it used to do that in the server's open document.
        doc = self.open_doc("traits.d")
        doc.completion("__traits(")
        doc.completion("__tra")
        found = labels(doc.completion("__traits(")["items"])
        self.assertIn("allMembers", found)
