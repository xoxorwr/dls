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


RENAMED_IMPORT_APP = """module app;

import lib : Renamed = Target;

void main()
{
    Rene
}
"""

UNRESOLVED_ALIAS_LIB = """module lib;

alias Target = Missing;
"""

RENAMED_IMPORT_OF_A_TYPE = """module app2;

import lib2 : Renamed = Widget;

void main()
{
    Ren
}
"""

WIDGET_LIB = """module lib2;

struct Widget
{
    int size;
}
"""


class RenamedSelectiveImportTests(DlsTestCase):
    """`import lib : name = other;` binds `name` to `other`.

    The resolving pass used to leave the import's bind data on the symbol, so
    the alias retry -- which runs for every alias whose operand is still
    unresolved, and a rename of an unresolved symbol is one -- handed a
    `selectiveImport` lookup to `resolveType`, whose "How did this happen?"
    assertion took the whole server down.  That is not an exotic shape:
    `import core.internal.traits : CoreUnconst = Unconst;` in std.traits is
    one, which is how a plain `import std.stdio;` used to kill the server.
    """

    PROJECT = {
        "app.d": RENAMED_IMPORT_APP,
        "lib.d": UNRESOLVED_ALIAS_LIB,
        "app2.d": RENAMED_IMPORT_OF_A_TYPE,
        "lib2.d": WIDGET_LIB,
    }

    def test_the_server_survives_a_rename_of_an_unresolved_symbol(self):
        doc = self.open_doc("app.d")
        # The crash happened while the opened module was cached, so every
        # request after the open failed; answering at all is the regression.
        self.assertEqual(
            ["Renamed", "main"], [symbol["name"] for symbol in doc.document_symbols()]
        )
        # And the next request finds a server that is still there.
        self.assertIsInstance(doc.completion("    Rene")["items"], list)

    def test_the_renamed_name_completes_where_it_resolves(self):
        doc = self.open_doc("app2.d")
        self.assertIn("Renamed", labels(doc.completion("    Ren")["items"]))
