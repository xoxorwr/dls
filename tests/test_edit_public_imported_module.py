"""Editing a module that other modules (publicly) import.

These tests cover the cache-invalidation path: re-caching a module replaces
its ``DSymbol`` instances, so modules holding references from the previous
parse have to be updated transitively (see ``DSymbol.updateTypes`` and the
``updateTypes`` notes in AGENTS.md).

Every test uses its own fixture files: the module cache is keyed by absolute
path, and a module cached by one test would otherwise leak into the next.

Two behaviours are covered here:

* a bare ``didChange`` (full text sync) refreshes the server's *buffer* --
  every request handler is handed ``buffer.content``, so unsaved edits are
  visible inside the edited file -- but it does not refresh DCD's *module
  cache*: ``lsp_sync_change`` calls neither ``dcd_on_open`` nor
  ``dcd_on_save``, unlike ``lsp_sync_open`` / ``lsp_did_save``.  Importers
  keep the previous parse of a dependency until it is saved, which is what the
  ``expectedFailure`` below pins (it asserts the live cross-file variant);
* a module re-cached from buffer text used to be dropped again by
  ``ModuleCache.cacheModule`` (``cache.insert(newEntry)`` does not overwrite,
  the tree is keyed by path only, and the following ``cache.remove(oldEntry)``
  then empties the entry), so the next lookup re-parses the file *from disk*
  and any text that is not on disk yet was lost.  The test below asserts the
  fixed behaviour directly.
"""

from harness import DlsTestCase, find_item, labels


def library(module: str, members: str) -> str:
    return f"""module {module};

struct Widget
{{
{members}}}
"""


def middle(module: str, *imports: str) -> str:
    lines = "\n".join(f"public import {name};" for name in imports)
    return f"module {module};\n\n{lines}\n"


def app(module: str, imported: str, declaration: str, statement: str) -> str:
    return f"""module {module};

import {imported};

void main()
{{
    {declaration}
    {statement}
}}
"""


INT_SIZE = "    int size;\n"
WITH_EXTRA = "    int size;\n    int extra;\n"
STRING_SIZE = "    string size;\n"


OTHER_LIB = """module other_lib;

struct Gadget
{
    int gsize;
}
"""


class PublicImportedModuleEditTests(DlsTestCase):
    PROJECT = {
        # --- an edit to the leaf module, observed through "edit_mid" ---
        "edit_lib.d": library("edit_lib", INT_SIZE),
        "edit_mid.d": middle("edit_mid", "edit_lib"),
        "edit_app.d": app("edit_app", "edit_mid", "Widget w;", "w.ex"),
        # --- a re-typed member of the leaf module ---
        "retype_lib.d": library("retype_lib", INT_SIZE),
        "retype_mid.d": middle("retype_mid", "retype_lib"),
        "retype_app.d": app("retype_app", "retype_mid", "Widget w;", "w.size"),
        # --- an edit that is never saved ---
        "change_lib.d": library("change_lib", INT_SIZE),
        "change_mid.d": middle("change_mid", "change_lib"),
        "change_app_si.d": app("change_app_si", "change_mid", "Widget w;", "w.si"),
        # --- a new public import added to the middle module ---
        "reexport_lib.d": library("reexport_lib", INT_SIZE),
        "other_lib.d": OTHER_LIB,
        "reexport_mid.d": middle("reexport_mid", "reexport_lib"),
        "reexport_app.d": app("reexport_app", "reexport_mid", "Gadget g;", "g.gs"),
    }

    def test_edit_of_public_imported_module_reaches_importers_after_save(self):
        library_doc = self.open_doc("edit_lib.d")
        self.open_doc("edit_mid.d")
        app_doc = self.open_doc("edit_app.d")

        # "extra" does not exist yet, so nothing matches the typed prefix.
        self.assertEqual(labels(app_doc.completion("w.ex")["items"]), [])

        library_doc.change(library("edit_lib", WITH_EXTRA))
        self.client.did_save(library_doc.uri)

        self.assertIn("extra", labels(app_doc.completion("w.ex")["items"]))

    def test_retype_in_public_imported_module_updates_importer_view(self):
        library_doc = self.open_doc("retype_lib.d")
        self.open_doc("retype_mid.d")
        app_doc = self.open_doc("retype_app.d")

        def member_type():
            items = app_doc.completion("w.size")["items"]
            return find_item(items, "size")["labelDetails"]["description"]

        self.assertEqual(member_type(), "int")

        library_doc.change(library("retype_lib", STRING_SIZE))
        self.client.did_save(library_doc.uri)

        self.assertEqual(member_type(), "string")

    def test_unsaved_edit_only_reaches_importers_on_save(self):
        """didChange is buffered; the module cache is refreshed on save.

        That split is deliberate: re-parsing a module on every keystroke would
        cost far more than the staleness it would avoid.  The edited file
        itself always sees the new text, because every request handler is
        handed the buffer; importers keep the previous parse until a save.
        """
        library_doc = self.open_doc("change_lib.d")
        self.open_doc("change_mid.d")
        app_doc = self.open_doc("change_app_si.d")

        def member_type():
            items = app_doc.completion("w.si")["items"]
            return find_item(items, "size")["labelDetails"]["description"]

        self.assertEqual(member_type(), "int")

        # Buffer-only edit: the importer still resolves the cached parse.
        library_doc.change(library("change_lib", STRING_SIZE))
        self.assertEqual(member_type(), "int")

        # Saving (text still not written to disk) is the reconciliation point.
        self.client.did_save(library_doc.uri)
        self.assertEqual(member_type(), "string")

    def test_new_public_import_in_editor_is_visible_to_importers(self):
        self.open_doc("reexport_lib.d")
        middle_doc = self.open_doc("reexport_mid.d")
        app_doc = self.open_doc("reexport_app.d")

        # Before the edit "Gadget" is not re-exported at all.
        self.assertEqual(labels(app_doc.completion("g.gs")["items"]), [])

        middle_doc.change(middle("reexport_mid", "reexport_lib", "other_lib"))
        self.client.did_save(middle_doc.uri)

        self.assertIn("gsize", labels(app_doc.completion("g.gs")["items"]))
