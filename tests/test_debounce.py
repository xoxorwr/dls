"""The debounce/idle mechanism behind the diagnostics dispatcher.

`didChange` no longer runs the lint dispatcher inline: it schedules it via
`schedule_lint` (server/dls/io.d), and the main loop (server/dls/main.d)
only actually runs it once `debounceMs` has passed with no further change for
that document - each new change pushes the deadline out again.  `didOpen`/
`didSave` stay eager, and both the built-in unused-symbol check and the
external ``check`` command now go through one dispatcher (`lsp_lint`), so a
document that trips both publishes exactly one `publishDiagnostics` carrying
both.
"""

import time

from harness import DlsTestCase


FAKE_CHECKER = r"printf 'app.d:3:5: Error: fake error\n'"

APP = """module app;

import unused_mod;

void main()
{
    int x;
}
"""


class DebounceTests(DlsTestCase):
    PROJECT = {
        "app.d": APP,
        "unused_mod.d": "module unused_mod;\nvoid something() {}\n",
    }
    # Generous relative to how long 8 sequential didChange writes take over a
    # pipe in a loaded test environment: the point being tested is "one
    # publish after the burst", not the exact debounce latency, so the burst
    # needs to reliably land inside one window rather than risk a legitimate
    # quiet gap mid-burst re-arming it (which would not be a bug - just not
    # what this particular assertion wants to depend on timing to avoid).
    DEBOUNCE_MS = 1000

    def _diagnostics_notifications(self, uri, start=0):
        return [
            m for m in self.client.notifications("textDocument/publishDiagnostics")[start:]
            if m["params"]["uri"] == uri
        ]

    def _wait_for_unused_import(self, doc, start):
        """The publish carrying this fixture's always-present unused import -
        scoped to 'start' and matched by content, not just uri, so a stale
        notification from another test/this doc's own close cannot match."""
        _, message = self.client.wait_for_notification(
            "textDocument/publishDiagnostics",
            lambda m: m["params"]["uri"] == doc.uri
            and any(d.get("code") == "unused-import" for d in m["params"]["diagnostics"]),
            start=start,
            timeout=10.0,
        )
        return message

    def test_a_burst_of_changes_produces_exactly_one_publish_after_it_settles(self):
        doc = self.open_doc("app.d")
        # The didOpen publish (eager) is not what is being measured here.
        start = len(self.client.notifications())

        for i in range(8):
            doc.change(APP + f"// edit {i}\n")

        # Nothing yet: still inside the debounce window (the burst above
        # took far less than DEBOUNCE_MS to send).
        time.sleep(self.DEBOUNCE_MS / 1000 / 2)
        self.assertEqual(self._diagnostics_notifications(doc.uri, start), [])

        self._wait_for_unused_import(doc, start)
        # Give a would-be second publish a chance to arrive before counting.
        time.sleep(self.DEBOUNCE_MS / 1000 / 2)
        self.assertEqual(len(self._diagnostics_notifications(doc.uri, start)), 1)

    def test_did_save_publishes_immediately_even_with_a_debounce_pending(self):
        doc = self.open_doc("app.d")
        start = len(self.client.notifications())

        doc.change(APP.replace("int x;", "int x; int y;"))
        # Still well inside the (generous) debounce window: only a save, not
        # the debounce settling, could produce a publish this soon.
        self.client.did_save(doc.uri)

        message = self._wait_for_unused_import(doc, start)
        self.assertTrue(message["params"]["diagnostics"])
        doc.change(APP)


class DispatcherCompositionTests(DlsTestCase):
    """Both diagnostic sources land in the same publishDiagnostics."""

    PROJECT = {
        "app.d": APP,
        "unused_mod.d": "module unused_mod;\nvoid something() {}\n",
    }
    CHECK = [{"path": "", "cmd": FAKE_CHECKER}]

    def test_the_external_checker_and_the_unused_import_check_both_publish_together(self):
        doc = self.open_doc("app.d")
        _, message = self.client.wait_for_notification(
            "textDocument/publishDiagnostics",
            lambda m: m["params"]["uri"] == doc.uri,
            timeout=20.0,
        )
        diagnostics = message["params"]["diagnostics"]

        from_checker = [d for d in diagnostics if d.get("message") == "fake error"]
        from_unused = [d for d in diagnostics if d.get("code") == "unused-import"]
        self.assertEqual(len(from_checker), 1)
        self.assertEqual(len(from_unused), 1)
