"""Diagnostics pushed by the configured ``check`` command in dls.json."""

from harness import DlsTestCase

# A fake compiler: it always reports one error in app.d.  This keeps the
# diagnostics pipeline testable without invoking a real D compiler.
FAKE_CHECKER = r"printf 'app.d:3:5: Error: fake error\n'"


class DiagnosticsTests(DlsTestCase):
    PROJECT = {
        "app.d": """module app;

void main()
{
    int x;
}
"""
    }
    CHECK = [{"path": "", "cmd": FAKE_CHECKER}]

    def wait_for_diagnostics(self, uri, start=0):
        return self.client.wait_for_notification(
            "textDocument/publishDiagnostics",
            lambda message: message["params"]["uri"] == uri,
            start=start,
            timeout=20.0,
        )

    def test_diagnostics_are_published_on_open(self):
        doc = self.open_doc("app.d")
        _, message = self.wait_for_diagnostics(doc.uri)

        diagnostics = message["params"]["diagnostics"]
        self.assertEqual(len(diagnostics), 1)
        diagnostic = diagnostics[0]
        self.assertEqual(diagnostic["severity"], 1)  # 1 == Error
        self.assertEqual(diagnostic["message"], "fake error")
        # "app.d:3:5:" is 1-based, the LSP range is 0-based.
        self.assertEqual(diagnostic["range"]["start"], {"line": 2, "character": 4})
        self.assertEqual(diagnostic["range"]["end"], {"line": 2, "character": 5})

    def test_diagnostics_are_cleared_when_the_document_closes(self):
        doc = self.open_doc("app.d")
        index, _ = self.wait_for_diagnostics(doc.uri)

        doc.close()
        _, message = self.wait_for_diagnostics(doc.uri, start=index + 1)
        self.assertEqual(message["params"]["diagnostics"], [])
