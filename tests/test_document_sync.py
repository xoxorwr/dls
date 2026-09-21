"""Full-document sync: didOpen, didChange, didSave, didClose."""

from harness import DlsTestCase, find_item, labels


#: The fixed size of the open-document table the server used to have
#: (``BUFFER_LENGTH`` in ``dls/io.d``); it grows now.
OLD_BUFFER_TABLE_LENGTH = 128


V1 = """module app;

struct State
{
    int aaa;
}

void main()
{
    State st;
    st.aa
}
"""

# Same file with an extra member and a cursor-compatible use of it.
V2 = """module app;

struct State
{
    int aaa;
    int zzz;
}

void main()
{
    State st;
    st.zz
}
"""

OTHER = """module other;

struct Point
{
    int x;
    int y;
}

void main()
{
    Point p;
    p.x
}
"""

TYPED_INT = """module app;

struct State
{
    int aaa;
}

void main()
{
    State st;
    st.aaa
}
"""

TYPED_STRING = TYPED_INT.replace("int aaa;", "string aaa;")


class DocumentSyncTests(DlsTestCase):
    PROJECT = {
        "app.d": V1,
        "changed.d": V1,
        "other.d": OTHER,
        "typed.d": TYPED_INT,
    }

    def test_two_documents_are_tracked_independently(self):
        app = self.open_doc("app.d")
        other = self.open_doc("other.d")

        app_items = labels(app.completion("st.aa")["items"])
        other_items = labels(other.completion("p.x")["items"])

        self.assertIn("aaa", app_items)
        self.assertNotIn("aaa", other_items)
        self.assertIn("x", other_items)

    def test_did_change_is_visible_to_completion(self):
        doc = self.open_doc("changed.d")
        doc.change(V2, version=2)
        items = labels(doc.completion("st.zz")["items"])
        self.assertIn("zzz", items)

    def test_did_save_keeps_the_document_usable(self):
        doc = self.open_doc("app.d")
        self.client.did_save(doc.uri)
        self.assertIn("aaa", labels(doc.completion("st.aa")["items"]))

    def test_did_change_updates_resolved_types(self):
        doc = self.open_doc("typed.d")

        def member_type():
            items = doc.completion("st.aaa")["items"]
            return find_item(items, "aaa")["labelDetails"]["description"]

        self.assertEqual(member_type(), "int")
        doc.change(TYPED_STRING, version=2)
        self.assertEqual(member_type(), "string")

    def test_closing_one_document_keeps_the_other_alive(self):
        first = self.open_doc("app.d")
        second = self.open_doc("other.d")

        first.close()
        # A closed document must not break requests for the still-open one.
        self.assertIn("x", labels(second.completion("p.x")["items"]))


def _tiny_module(index: int) -> str:
    return (
        f"module many{index:03d};\n\n"
        f"struct P{index:03d}\n{{\n    int field;\n}}\n\n"
        f"void main()\n{{\n    P{index:03d} p;\n    p.fi\n}}\n"
    )


class BufferTableCapacityTests(DlsTestCase):
    """The open-document table grows instead of dropping documents.

    ``dls/io.d`` used to keep open documents in a fixed ``BUFFER[128]`` array
    with ``first_empty_buf`` as the high-water mark.  Once all 128 slots were
    taken, ``open_buffer`` logged ``buffer table is full (128 documents),
    ignoring ...`` and returned an empty ``BUFFER``: the ``didOpen`` was
    dropped without any client-visible error, the document never reached
    ``dcd_on_open``, and every request for it answered with an empty result
    (``get_buffer`` returns a null-initialised ``BUFFER``) until some other
    document was closed.  Only ``didClose`` freed a slot, so an editor that
    kept more than 128 files open silently lost completions in all of them.

    The table is now grown through the long-lived heap allocator, so the
    129th document is tracked like any other.  These tests pin both halves of
    that: documents past the old limit complete, and closing one still frees
    its slot afterwards.
    """

    PROJECT = {
        f"many{index:03d}.d": _tiny_module(index)
        for index in range(OLD_BUFFER_TABLE_LENGTH + 1)
    }

    def test_one_past_the_old_table_limit_still_completes(self):
        docs = [self.open_doc(relpath) for relpath in self.PROJECT]

        self.assertIn("field", labels(docs[0].completion("p.fi")["items"]))
        self.assertIn(
            "field",
            labels(docs[OLD_BUFFER_TABLE_LENGTH - 1].completion("p.fi")["items"]),
        )
        # The 129th document used to be dropped.
        self.assertIn("field", labels(docs[-1].completion("p.fi")["items"]))

    def test_closing_a_document_frees_its_slot(self):
        docs = [self.open_doc(relpath) for relpath in self.PROJECT]
        docs[0].close()

        self.write_file("many999.d", _tiny_module(999))
        late = self.open_doc("many999.d")
        self.assertIn("field", labels(late.completion("p.fi")["items"]))
