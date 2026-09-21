"""Canaries for behaviour the module cache must keep after the eviction fix.

Making ``ModuleCache.cacheModule`` stop dropping the freshly cached entry
means cache entries now survive, which is exactly what could introduce
regressions: stale content, missed edits, or unbalanced re-caching.  Every
test in ``ModuleCacheSideEffectTests`` passed before the fix and had to keep
passing after it.  ``EmptyModuleRecoveryTests`` pins the other half of the
same lifecycle: a module that is empty (or missing) when it is first cached
has to be picked up once it has content.

Each test uses its own fixture files, because the module cache is keyed by
absolute path and is shared by every test in the class.
"""

import os

from harness import DlsTestCase, labels, write_text


INT_SIZE = "    int size;\n"
WITH_EXTRA = "    int size;\n    int extra;\n"


def library(module: str, members: str) -> str:
    return f"""module {module};

struct Widget
{{
{members}}}
"""


def app(module: str, imported: str, declaration: str, statement: str) -> str:
    return f"""module {module};

import {imported};

void main()
{{
    {declaration}
    {statement}
}}
"""


class ModuleCacheSideEffectTests(DlsTestCase):
    PROJECT = {
        # 1. a file changed on disk only (no didChange / didSave)
        "s1_leaf.d": library("s1_leaf", INT_SIZE),
        "s1_app.d": app("s1_app", "s1_leaf", "Widget w;", "w.ex"),
        # 2. members must disappear again when a save removes them
        "s2_leaf.d": library("s2_leaf", INT_SIZE),
        "s2_app.d": app("s2_app", "s2_leaf", "Widget w;", "w.ex"),
        # 3. circular public imports must still resolve
        "s3_a.d": "module s3_a;\n\npublic import s3_b;\n\nstruct Aye { int av; }\n",
        "s3_b.d": "module s3_b;\n\npublic import s3_a;\n\nstruct Bee { int bv; }\n",
        "s3_app_a.d": app("s3_app_a", "s3_a", "Bee x;", "x.bv"),
        "s3_app_b.d": app("s3_app_b", "s3_a", "Aye y;", "y.av"),
        # 4. closing the dependency buffer must not break completions
        "s4_leaf.d": library("s4_leaf", INT_SIZE),
        "s4_app.d": app("s4_app", "s4_leaf", "Widget w;", "w.si"),
        # 5. repeated close/re-open cycles, then an edit
        "s5_leaf.d": library("s5_leaf", INT_SIZE),
        "s5_app.d": app("s5_app", "s5_leaf", "Widget w;", "w.si"),
        "s5_app_extra.d": app("s5_app_extra", "s5_leaf", "Widget w;", "w.ex"),
        # 6. every importer must see an updated dependency
        "s6_leaf.d": library("s6_leaf", INT_SIZE),
        "s6_app_one.d": app("s6_app_one", "s6_leaf", "Widget w;", "w.ex"),
        "s6_app_two.d": app("s6_app_two", "s6_leaf", "Widget w;", "w.ex"),
        # 7. repeated saves must end up on the latest content
        "s7_leaf.d": library("s7_leaf", INT_SIZE),
        "s7_app.d": app("s7_app", "s7_leaf", "Widget w;", "w.ex"),
        # 8. other requests must survive a dependency re-cache
        "s8_leaf.d": library("s8_leaf", INT_SIZE),
        "s8_app.d": app("s8_app", "s8_leaf", "Widget w;", "w.ex"),
    }

    def save(self, doc, text: str) -> None:
        """Simulate an editor save: the file hits the disk, then the LSP."""
        with open(os.path.join(self.root, doc.relpath), "w", encoding="utf-8") as handle:
            handle.write(text)
        doc.change(text)
        self.client.did_save(doc.uri)

    def test_external_disk_change_is_picked_up(self):
        self.open_doc("s1_leaf.d")
        app_doc = self.open_doc("s1_app.d")

        self.assertEqual(labels(app_doc.completion("w.ex")["items"]), [])

        # The file changes behind the server's back: no didChange, no didSave.
        with open(os.path.join(self.root, "s1_leaf.d"), "w", encoding="utf-8") as handle:
            handle.write(library("s1_leaf", WITH_EXTRA))

        self.assertIn("extra", labels(app_doc.completion("w.ex")["items"]))

    def test_member_removed_by_a_save_disappears_again(self):
        leaf = self.open_doc("s2_leaf.d")
        app_doc = self.open_doc("s2_app.d")

        self.save(leaf, library("s2_leaf", WITH_EXTRA))
        self.assertIn("extra", labels(app_doc.completion("w.ex")["items"]))

        self.save(leaf, library("s2_leaf", INT_SIZE))
        self.assertEqual(labels(app_doc.completion("w.ex")["items"]), [])

    def test_circular_public_imports_still_resolve(self):
        self.open_doc("s3_a.d")
        self.open_doc("s3_b.d")
        app_a = self.open_doc("s3_app_a.d")
        app_b = self.open_doc("s3_app_b.d")

        self.assertEqual(labels(app_a.completion("x.bv")["items"]), ["bv"])
        self.assertEqual(labels(app_b.completion("y.av")["items"]), ["av"])
        self.assertIsNone(self.client.process.poll(), "server died on circular imports")

    def test_completions_survive_closing_the_dependency_buffer(self):
        leaf = self.open_doc("s4_leaf.d")
        app_doc = self.open_doc("s4_app.d")
        self.assertIn("size", labels(app_doc.completion("w.si")["items"]))

        leaf.close()
        self.assertIn("size", labels(app_doc.completion("w.si")["items"]))

    def test_reopening_a_dependency_keeps_completions_and_edits(self):
        leaf = self.open_doc("s5_leaf.d")
        app_doc = self.open_doc("s5_app.d")
        extra_doc = self.open_doc("s5_app_extra.d")

        for _ in range(3):
            leaf.close()
            leaf.open()
            self.assertIn("size", labels(app_doc.completion("w.si")["items"]))

        self.save(leaf, library("s5_leaf", WITH_EXTRA))
        self.assertIn("extra", labels(extra_doc.completion("w.ex")["items"]))

    def test_every_importer_sees_the_updated_dependency(self):
        leaf = self.open_doc("s6_leaf.d")
        first = self.open_doc("s6_app_one.d")
        second = self.open_doc("s6_app_two.d")

        self.save(leaf, library("s6_leaf", WITH_EXTRA))

        for doc in (first, second):
            self.assertIn("extra", labels(doc.completion("w.ex")["items"]))

    def test_repeated_saves_end_on_the_latest_content(self):
        leaf = self.open_doc("s7_leaf.d")
        app_doc = self.open_doc("s7_app.d")

        for _ in range(2):
            self.save(leaf, library("s7_leaf", WITH_EXTRA))
            self.assertIn("extra", labels(app_doc.completion("w.ex")["items"]))

        self.save(leaf, library("s7_leaf", INT_SIZE))
        self.assertEqual(labels(app_doc.completion("w.ex")["items"]), [])

    def test_other_requests_survive_a_dependency_recache(self):
        leaf = self.open_doc("s8_leaf.d")
        app_doc = self.open_doc("s8_app.d")

        self.save(leaf, library("s8_leaf", WITH_EXTRA))

        symbols = {symbol["name"] for symbol in app_doc.document_symbols()}
        self.assertIn("main", symbols)

        result = app_doc.hover("w.ex", offset=-len("w.ex") + 1)
        text = "\n".join(entry["value"] for entry in result["contents"])
        self.assertIn("Widget", text)

        self.assertIsInstance(app_doc.definition("w.ex", offset=-3), list)


EMPTY_LIBS_APP = """module eapp;

import elib;

void main()
{
    Widget w;
    w.
}
"""

LIBRARY_WITH_SIZE = """module elib;

struct Widget
{
    int size;
}
"""


class EmptyModuleRecoveryTests(DlsTestCase):
    """A module that was empty once is cached again once it has content.

    ``ModuleCache.cacheModule`` inserts the path into ``recursionGuard`` and
    then used to return early -- without removing it again -- on the ``> empty``
    path (a zero-length file, or a zero-length ``didSave`` text) and on the
    failed C-header path.  Every later call for that path hit the guard and
    returned immediately, so the module stayed uncached for the rest of the
    session: ``didOpen``/``didSave`` for it never reached the parser, no
    dependent was ever notified, and completions for symbols from it stayed
    empty.  A file that was still empty when an importer first cached it --
    the state every editor starts a new file in -- broke that symbol until the
    server restarted.

    The guard is now released on every return path (``scope(exit)`` next to
    the insert).  Here ``elib.d`` is empty while ``eapp.d`` is opened, and
    gains its content afterwards the way a save would.
    """

    PROJECT = {"eapp.d": EMPTY_LIBS_APP, "elib.d": ""}

    def test_library_is_picked_up_once_it_has_content(self):
        app_doc = self.open_doc("eapp.d")
        # A request, so the server has certainly handled that didOpen -- and
        # therefore tried and failed to cache the still-empty elib.d -- before
        # elib.d gains its content.
        app_doc.completion("w.")

        lib = self.doc("elib.d")
        write_text(lib.path, LIBRARY_WITH_SIZE)
        lib.open(LIBRARY_WITH_SIZE)

        self.assertIn("size", labels(app_doc.completion("w.")["items"]))
