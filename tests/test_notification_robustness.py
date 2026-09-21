"""Late, malformed or wrongly-typed notifications must never take the server down.

A language server sees notifications it did not ask for: a save that arrives
after the document was closed, a client that saves a file it never opened, a
tracker that sends a change without an open, a malformed payload with no URI.
Today each of these kills the process (``exit(1)`` from the buffer lookup, or
a null dereference), which costs the editor every language feature until it
restarts the server.

Each test sends the odd notification, then sends a normal request: the request
must still be answered, and the server must still be alive afterwards.

``JsonShapeTests`` covers the other half of the same contract: a field whose
*type* is wrong (a URI that isn't a string, a position that isn't a number, a
capability flag that isn't a boolean) has to read as absent rather than as
garbage -- every handler looks its fields up through the JSON reader, and a
missing node must never reach an asserting accessor.
"""

import os

from harness import DlsTestCase, labels


APP = """module app;

import lib;

void main()
{
    Widget w;
    w.si
}
"""

LIB = """module lib;

struct Widget
{
    int size;
}
"""


class NotificationRobustnessTests(DlsTestCase):
    PROJECT = {"app.d": APP, "app_extra.d": APP.replace("w.si", "w.ex"), "lib.d": LIB}

    def open_app(self):
        return self.open_doc("app.d")

    def assert_server_still_works(self, doc):
        """A plain request must be answered (this raises if the server died)."""
        symbols = {symbol["name"] for symbol in doc.document_symbols()}
        self.assertIn("main", symbols)
        self.assertIn("size", labels(doc.completion("w.si")["items"]))
        self.assertIsNone(self.client.process.poll(), "server is not running")

    def test_did_save_for_a_uri_that_was_never_opened(self):
        doc = self.open_app()
        never_opened = "file://" + os.path.join(self.root, "never_opened.d")

        self.client.notify("textDocument/didSave", {"textDocument": {"uri": never_opened}})

        self.assert_server_still_works(doc)

    def test_did_save_without_a_uri_field(self):
        doc = self.open_app()

        # No "uri" at all: the server used to dereference null here.
        self.client.notify("textDocument/didSave", {"textDocument": {"version": 2}})

        self.assert_server_still_works(doc)

    def test_did_save_after_the_document_was_closed(self):
        doc = self.open_app()
        uri = doc.uri
        doc.close()

        self.client.notify("textDocument/didSave", {"textDocument": {"uri": uri}})

        self.assert_server_still_works(doc)

    def test_did_change_for_a_uri_that_was_never_opened(self):
        doc = self.open_app()

        self.client.notify(
            "textDocument/didChange",
            {
                "textDocument": {"uri": "file://" + os.path.join(self.root, "ghost.d"), "version": 2},
                "contentChanges": [{"text": "module ghost;\n"}],
            },
        )

        self.assert_server_still_works(doc)

    def test_did_close_for_a_uri_that_was_never_opened(self):
        doc = self.open_app()

        self.client.notify(
            "textDocument/didClose",
            {"textDocument": {"uri": "file://" + os.path.join(self.root, "ghost.d")}},
        )

        self.assert_server_still_works(doc)

    def test_did_open_without_text(self):
        doc = self.open_app()

        self.client.notify(
            "textDocument/didOpen",
            {"textDocument": {"uri": "file://" + os.path.join(self.root, "ghost.d"), "languageId": "d", "version": 1}},
        )

        self.assert_server_still_works(doc)

    def test_did_open_without_text_reads_the_file_from_disk(self):
        # A didOpen with no "text" falls back to the file on disk, keyed by URI.
        uri = "file://" + os.path.join(self.root, "lib.d")
        self.addCleanup(self.client.did_close, uri)

        self.client.notify(
            "textDocument/didOpen",
            {"textDocument": {"uri": uri, "languageId": "d", "version": 1}},
        )

        symbols = {symbol["name"] for symbol in self.client.document_symbols(uri)}
        self.assertIn("Widget", symbols)

    def test_duplicate_did_open_keeps_a_single_buffer_entry(self):
        # Opening the same URI twice must not leave a second entry behind, or
        # the later didClose only closes one of them.
        uri = "file://" + os.path.join(self.root, "lib.d")

        self.client.did_open(os.path.join(self.root, "lib.d"), LIB)
        self.client.did_open(os.path.join(self.root, "lib.d"), LIB)
        self.client.did_close(uri)

        self.assertEqual(self.client.document_symbols(uri), [])

    def test_did_save_with_text_updates_the_cache_after_close(self):
        app = self.open_doc("app_extra.d")
        lib_uri = "file://" + os.path.join(self.root, "lib.d")
        self.client.did_open(os.path.join(self.root, "lib.d"), LIB)
        self.client.did_close(lib_uri)

        # The document is gone from the buffer table; the client sends the text
        # with the save (save.includeText is advertised).
        new_lib = LIB.replace("int size;", "int size;\n    int extra;")
        self.client.notify(
            "textDocument/didSave",
            {"textDocument": {"uri": lib_uri}, "text": new_lib},
        )

        self.assertIn("extra", labels(app.completion("w.ex")["items"]))


class UnopenedDocumentRequestTests(DlsTestCase):
    """Requests for an unopened document must answer, not abort the process."""

    PROJECT = {"app.d": APP, "lib.d": LIB}

    @property
    def ghost_uri(self):
        return "file://" + os.path.join(self.root, "ghost.d")

    def test_completion_for_an_unopened_document(self):
        doc = self.open_doc("app.d")
        result = self.client.completion(self.ghost_uri, 0, 0)
        self.assertFalse(result["isIncomplete"])
        self.assertEqual(result["items"], [])
        self.assertIn("size", labels(doc.completion("w.si")["items"]))

    def test_hover_for_an_unopened_document(self):
        doc = self.open_doc("app.d")
        self.assertEqual(self.client.hover(self.ghost_uri, 0, 0)["contents"], [])
        self.assertIn("size", labels(doc.completion("w.si")["items"]))

    def test_definition_for_an_unopened_document(self):
        doc = self.open_doc("app.d")
        self.assertEqual(self.client.definition(self.ghost_uri, 0, 0), [])
        self.assertIn("size", labels(doc.completion("w.si")["items"]))

    def test_document_symbols_for_an_unopened_document(self):
        doc = self.open_doc("app.d")
        self.assertEqual(self.client.document_symbols(self.ghost_uri), [])
        self.assertIn("size", labels(doc.completion("w.si")["items"]))


class JsonShapeTests(DlsTestCase):
    """A field of the wrong type reads as absent, not as garbage.

    The client is not always right: a URI can arrive as a number, a position
    as a string, "contentChanges" as an object.  Each of these used to reach a
    lookup that only checked for the *presence* of the field, so the wrong
    type turned into a null dereference or a nonsense offset.
    """

    PROJECT = {"app.d": APP, "lib.d": LIB}

    def assert_server_still_works(self, doc):
        self.assertIn("size", labels(doc.completion("w.si")["items"]))
        self.assertIsNone(self.client.process.poll(), "server is not running")

    def test_completion_with_a_uri_that_is_not_a_string(self):
        doc = self.open_doc("app.d")
        result = self.client.request(
            "textDocument/completion",
            {"textDocument": {"uri": 42}, "position": {"line": 0, "character": 0}},
        )
        self.assertEqual(result["items"], [])
        self.assert_server_still_works(doc)

    def test_completion_with_a_position_that_is_not_a_number(self):
        doc = self.open_doc("app.d")
        result = self.client.completion(doc.uri, "0", "0")
        self.assertEqual(result["items"], [])
        self.assert_server_still_works(doc)

    def test_did_change_without_content_changes(self):
        doc = self.open_app_and_keep_the_buffer()
        for changes in (None, [], {"text": "module app;\n"}, [{"text": 7}]):
            params = {"textDocument": {"uri": doc.uri, "version": 2}}
            if changes is not None:
                params["contentChanges"] = changes
            self.client.notify("textDocument/didChange", params)
            self.assert_server_still_works(doc)

    def test_watched_file_change_without_a_usable_uri(self):
        doc = self.open_app_and_keep_the_buffer()
        self.client.notify(
            "workspace/didChangeWatchedFiles",
            {"changes": [{}, {"uri": 3, "type": "2"}, {"uri": doc.uri, "type": "2"}]},
        )
        self.assert_server_still_works(doc)

    def open_app_and_keep_the_buffer(self):
        """Open 'app.d' without registering a cleanup close for every test."""
        doc = self.doc("app.d")
        doc.open()
        self.addCleanup(doc.close)
        return doc
