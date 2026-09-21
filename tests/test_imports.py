"""Cross-module resolution through the configured import paths."""

import os

from harness import DlsTestCase, labels

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
    """The compiler's own import paths are registered even with no project paths.

    They are auto-detected (dmd.conf, /etc/dmd.conf, a source tree above the
    compiler binary, or a system location) - see default_import_paths() in
    main.d - so a machine with a single toolchain still finds object.d.
    """

    WRITE_DLS_JSON = False
    PROJECT = {"app.d": "module app;\n\nvoid main() {}\n"}

    def registered_import_paths(self):
        """The paths the server logged as registered at initialize."""
        marker = "adding import: "
        paths = []
        for line in self.client.stderr_lines():
            at = line.find(marker)
            if at != -1:
                paths.append(line[at + len(marker):].strip())
        return paths

    def test_the_standard_library_is_registered(self):
        doc = self.open_doc("app.d")
        doc.document_symbols()  # sync: the log below is written at initialize

        registered = self.registered_import_paths()
        self.assertTrue(
            any(
                os.path.isfile(os.path.join(path, "object.d"))
                for path in registered
            ),
            f"no registered import path holds object.d: {registered}\n"
            + self.client.stderr_tail(),
        )
