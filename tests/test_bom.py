"""A byte order mark at the start of a file must not move anything.

The lexer used to *slice* a UTF-8 BOM off its input instead of walking past
it, which shifted every token three bytes towards the start of the file.  No
editor-relative position agrees with that: the byte offset the server computes
for a cursor counts the BOM, so completion, hover and everything else missed
on a file that starts with one - on every platform, not only on Windows.
"""

from harness import DlsTestCase, labels


BOM = "\ufeff"

BOM_SOURCE = BOM + """module app;

struct Widget
{
    int size;
}

void main()
{
    Widget w;
    w.
}
"""


class ByteOrderMarkTests(DlsTestCase):
    PROJECT = {"app.d": BOM_SOURCE}

    def test_member_completion_works_after_a_byte_order_mark(self):
        doc = self.open_doc("app.d")
        self.assertIn("size", labels(doc.completion("    w.")["items"]))

    def test_hover_finds_the_symbol_after_a_byte_order_mark(self):
        doc = self.open_doc("app.d")
        contents = doc.hover("w.", offset=-len("w.") + 1)["contents"]
        text = "\n".join(entry["value"] for entry in contents)
        self.assertIn("Widget", text)
