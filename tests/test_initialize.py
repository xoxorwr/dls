"""Server lifecycle: the initialize handshake, capabilities and shutdown."""

from harness import DlsTestCase


class InitializeTests(DlsTestCase):
    # The handshake does not depend on import paths, so skip dls.json here.
    WRITE_DLS_JSON = False
    PROJECT = {"app.d": "module app;\n\nvoid main() {}\n"}

    def test_server_info(self):
        self.assertEqual(self.client.server_info["name"], "dls")
        self.assertTrue(self.client.server_info["version"])

    def test_supported_providers_are_advertised(self):
        caps = self.client.capabilities
        self.assertTrue(caps["hoverProvider"])
        self.assertTrue(caps["definitionProvider"])
        self.assertTrue(caps["documentSymbolProvider"])
        self.assertIn("completionProvider", caps)
        self.assertIn("signatureHelpProvider", caps)

    def test_completion_provider_metadata(self):
        completion = self.client.capabilities["completionProvider"]
        self.assertFalse(completion["resolveProvider"])
        self.assertEqual(completion["triggerCharacters"], [".", "=", "/", "*", "+", "-"])
        self.assertTrue(completion["completionItem"]["labelDetailsSupport"])

    def test_signature_help_trigger_characters(self):
        signature = self.client.capabilities["signatureHelpProvider"]
        self.assertEqual(signature["triggerCharacters"], ["(", "{", ","])
        self.assertEqual(signature["retriggerCharacters"], [","])

    def test_text_document_sync(self):
        sync = self.client.capabilities["textDocumentSync"]
        self.assertTrue(sync["openClose"])
        # 1 == full document sync.
        self.assertEqual(sync["change"], 1)
        self.assertTrue(sync["save"]["includeText"])

    def test_shutdown_answers_with_null_result(self):
        self.assertIsNone(self.client.request("shutdown", {}))

    def test_unknown_method_is_ignored_and_server_survives(self):
        # Notifications for unimplemented requests must not take the server down.
        self.client.notify("workspace/didChangeWatchedFiles", {"changes": []})
        doc = self.open_doc("app.d")
        symbols = doc.document_symbols()
        self.assertIn("main", {symbol["name"] for symbol in symbols})

    def test_single_file_features_work_without_dls_json(self):
        # No dls.json on disk: the server has no other channel to be told
        # about import paths, but single-file analysis must keep working.
        doc = self.open_doc("app.d")
        self.assertEqual(doc.document_symbols()[0]["name"], "main")
