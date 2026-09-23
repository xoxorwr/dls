"""Semantic tokens that depend on another module.

A name is classified through the modules it imports, so a document's tokens
go stale when one of those modules changes even though its own text did not.
The server keeps each document's tokens until its text or the module cache
changes, and asks the client to request them again
(``workspace/semanticTokens/refresh``) when a save or an outside write changes
a module - a client has no other reason to ask, since the text it shows is
the same.
"""

from harness import DlsTestCase


LIB = """module lib;

struct Thing
{
    int size;
}
"""

LIB_AS_CLASS = """module lib;

class Thing
{
    int size;
}
"""

APP = """module app;

import lib;

void main()
{
    Thing thing;
}
"""

REFRESH = "workspace/semanticTokens/refresh"


class SemanticTokenRefreshTests(DlsTestCase):
    PROJECT = {
        "app.d": APP,
        "lib.d": LIB,
    }
    CLIENT_CAPABILITIES = {
        "workspace": {"semanticTokens": {"refreshSupport": True}},
        "textDocument": {
            "semanticTokens": {
                "requests": {"full": True},
                "tokenTypes": [],
                "tokenModifiers": [],
                "formats": ["relative"],
            }
        },
    }

    def _type_at(self, doc, needle):
        """The token type of the name ``needle`` starts with, or None."""
        types = self.client.capabilities["semanticTokensProvider"]["legend"]["tokenTypes"]
        data = doc.semantic_tokens()["data"]
        wanted = doc.position(needle, -len(needle))
        line = character = 0
        for i in range(0, len(data), 5):
            delta_line, delta_start, _, token_type, _ = data[i : i + 5]
            line += delta_line
            character = character + delta_start if delta_line == 0 else delta_start
            if (line, character) == wanted:
                return types[token_type]
        return None

    def _refreshes(self):
        """How many refreshes the server sent so far.

        The server handles messages in order, so once a request sent now has
        its answer, everything the earlier notifications made it send is in.
        """
        self.client.request("textDocument/foldingRange", {"textDocument": {"uri": self.doc("app.d").uri}})
        return len(self.client.notifications(REFRESH))

    def tearDown(self):
        # Every test starts from the module as it is on disk.
        lib = self.doc("lib.d")
        if lib.is_open:
            lib.change(LIB)
            self.client.did_save(lib.uri)
            lib.close()

    def test_a_saved_change_to_an_import_reclassifies_and_asks_for_a_refresh(self):
        app = self.open_doc("app.d")
        self.assertEqual(self._type_at(app, "Thing thing"), "struct")

        lib = self.open_doc("lib.d")
        before = self._refreshes()
        lib.change(LIB_AS_CLASS)
        self.client.did_save(lib.uri)

        self.assertEqual(self._refreshes(), before + 1)
        self.assertEqual(self._type_at(app, "Thing thing"), "class")

    def test_an_unsaved_change_to_an_import_does_not_ask_for_a_refresh(self):
        # Until the save, the other documents resolve against the saved text.
        app = self.open_doc("app.d")
        lib = self.open_doc("lib.d")
        before = self._refreshes()

        lib.change(LIB_AS_CLASS)

        self.assertEqual(self._type_at(app, "Thing thing"), "struct")
        self.assertEqual(self._refreshes(), before)

    def test_saving_the_text_the_server_already_has_does_not_ask_for_a_refresh(self):
        app = self.open_doc("app.d")
        lib = self.open_doc("lib.d")
        before = self._refreshes()

        self.client.did_save(lib.uri)

        self.assertEqual(self._type_at(app, "Thing thing"), "struct")
        self.assertEqual(self._refreshes(), before)

    def test_a_change_to_the_document_itself_is_reflected(self):
        app = self.open_doc("app.d")
        self.assertEqual(self._type_at(app, "Thing thing"), "struct")

        app.change(APP.replace("Thing thing;", "int Thing; Thing = 1;"))
        self.assertEqual(self._type_at(app, "Thing = 1"), "variable")
        app.change(APP)


class SemanticTokenNoRefreshSupportTests(DlsTestCase):
    """A client that did not say it takes a refresh never gets one."""

    PROJECT = {
        "app.d": APP,
        "lib.d": LIB,
    }

    def test_no_refresh_is_sent(self):
        self.open_doc("app.d")
        lib = self.open_doc("lib.d")
        lib.change(LIB_AS_CLASS)
        self.client.did_save(lib.uri)
        self.doc("app.d").semantic_tokens()

        self.assertEqual(self.client.notifications(REFRESH), [])
        lib.change(LIB)
        self.client.did_save(lib.uri)
