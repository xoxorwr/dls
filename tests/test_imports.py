"""Cross-module resolution through the configured import paths."""

import os
import time
import unittest

from harness import DlsTestCase, labels

# Default paths registered by lsp_initialize_params (see main.d).
SYSTEM_IMPORT_PATHS = (
    "/usr/include/dlang/dmd/",
    "/usr/include/dmd/druntime/import/",
    "/usr/include/dmd/phobos/",
)


LIB = """module lib;

struct Widget
{
    int size;
}
"""

APP = """module app;

import lib;

void main()
{
    Widget w;
    w.size
}
"""


def hover_text(doc, needle, offset=0):
    result = doc.hover(needle, offset)
    return "\n".join(entry["value"] for entry in result["contents"])


class ImportResolutionTests(DlsTestCase):
    """dls.json exists, so the server registers the project import paths."""

    PROJECT = {"lib.d": LIB, "app.d": APP}

    def test_hover_of_imported_type_reports_the_foreign_module(self):
        doc = self.open_doc("app.d")
        # Cursor on "w" in "w.size".
        text = hover_text(doc, "w.size", offset=-len("w.size") + 1)
        self.assertIn("Widget", text)

    def test_completion_after_imported_member(self):
        doc = self.open_doc("app.d")
        self.assertIn("size", labels(doc.completion("w.size")["items"]))


class ImportPathsRequireDlsJsonTests(DlsTestCase):
    """dls.json is the only source of project import paths.

    There is no editor-specific second channel any more: an editor that knows
    the import paths cannot hand them over through the protocol (or a command
    line switch) - it has to leave a dls.json in the workspace, which is what
    makes every client behave the same.  Without one, a relative import of a
    sibling file does not resolve, and only the compiler's default paths are
    registered.
    """

    WRITE_DLS_JSON = False
    PROJECT = {"lib.d": LIB, "app.d": APP}

    def test_an_import_does_not_resolve_without_dls_json(self):
        doc = self.open_doc("app.d")
        self.assertEqual(labels(doc.completion("w.size")["items"]), [])

    def test_single_file_analysis_still_works_without_dls_json(self):
        doc = self.open_doc("app.d")
        self.assertEqual(doc.document_symbols()[0]["name"], "main")


class SystemImportPathsWithoutConfigTests(DlsTestCase):
    """The druntime/phobos paths are registered even with no project paths."""

    WRITE_DLS_JSON = False
    PROJECT = {"app.d": "module app;\n\nvoid main() {}\n"}

    def wait_for_log(self, needle, timeout=10.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if any(needle in line for line in self.client.stderr_lines()):
                return True
            time.sleep(0.05)
        return False

    @unittest.skipUnless(
        any(os.path.isdir(path) for path in SYSTEM_IMPORT_PATHS),
        "no system D import paths on this machine",
    )
    def test_system_import_paths_are_registered(self):
        doc = self.open_doc("app.d")
        doc.document_symbols()  # sync: the log below is written at initialize

        expected = [path for path in SYSTEM_IMPORT_PATHS if os.path.isdir(path)]
        self.assertTrue(
            any(self.wait_for_log(f"adding import: {path}") for path in expected),
            f"none of {expected} were registered\n{self.client.stderr_tail()}",
        )
