"""Modules that change outside the editor: generated or written by a tool.

DCD's module cache is only reconciled by ``didOpen`` / ``didSave``, and a
lookup hands back the cached symbol without ever comparing the file's
modification time (``ModuleCache.getModuleSymbol``), so a module that a
generator - or another editor window, or ``git checkout`` - rewrote on disk
stays stale for the rest of the session.

The server therefore registers a file watcher (``client/registerCapability``
for ``workspace/didChangeWatchedFiles``) and treats a reported change exactly
like a save: re-parse the module and re-point the modules that import it.
"""

import os
import time

import harness
from harness import DlsTestCase, labels

# The log scan below must not race the client's stderr ring buffer.
harness.STDERR_TAIL_LINES = 50000

#: What a client that can be asked to watch files advertises (VS Code's
#: languageclient 8.x and Zed both implement dynamic registration, and the
#: languageclient also advertises relative patterns).
WATCHER_CAPABILITIES = {
    "workspace": {
        "didChangeWatchedFiles": {
            "dynamicRegistration": True,
            "relativePatternSupport": True,
        }
    }
}

#: A client that can be asked to watch files but takes only plain globs.
WATCHER_CAPABILITIES_WITHOUT_RELATIVE = {
    "workspace": {"didChangeWatchedFiles": {"dynamicRegistration": True}}
}

LEAF = """module leaf;

struct Widget
{
    int size;
}
"""

LEAF_WITH_EXTRA = """module leaf;

struct Widget
{
    int size;
    int extra;
}
"""

LEAF_WITH_OTHER = """module leaf;

struct Widget
{
    int size;
    int other;
}
"""

APP_SI = """module app_si;

import leaf;

void main()
{
    Widget w;
    w.si
}
"""

APP_EX = """module app_ex;

import leaf;

void main()
{
    Widget w;
    w.ex
}
"""

APP_GEN = """module app;

import gen;

void main()
{
    Gadget g;
    g.st
}
"""

GEN = """module gen;

struct Gadget
{
    int stuff;
}
"""


def change_event(path: str, type_: int) -> dict[str, object]:
    """A 'workspace/didChangeWatchedFiles' entry (1 created, 2 changed, 3 deleted)."""
    return {"uri": harness.path_to_uri(path), "type": type_}


class RegistrationTestCase(DlsTestCase):
    """Shared plumbing: pull the watcher patterns out of the registration."""

    PROJECT = {"app.d": "module app;\n\nvoid main() {}\n"}

    def watcher_registrations(self, *wanted):
        """{registration id: [globPattern, ...]}, waiting for the wanted ids.

        The server registers two: the configuration file, and the project's
        import paths.  They are sent in that order on 'initialized', so the
        second one's arrival means the first is there too.
        """
        wanted = wanted or ("dls-watch-config", "dls-watch-import-paths")

        def collected():
            found = {}
            for message in self.client.notifications("client/registerCapability"):
                for registration in message["params"]["registrations"]:
                    self.assertEqual(registration["method"], "workspace/didChangeWatchedFiles")
                    found[registration["id"]] = [
                        watcher["globPattern"]
                        for watcher in registration["registerOptions"]["watchers"]
                    ]
            return found

        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline:
            found = collected()
            if all(one in found for one in wanted):
                return found
            time.sleep(0.05)
        self.fail(f"no {wanted} registration: " + repr(collected()))

    def import_path_patterns(self):
        """The newest import-path registration's patterns, or None."""
        patterns = None
        for message in self.client.notifications("client/registerCapability"):
            for registration in message["params"]["registrations"]:
                if registration["id"] == "dls-watch-import-paths":
                    patterns = [
                        watcher["globPattern"]
                        for watcher in registration["registerOptions"]["watchers"]
                    ]
        return patterns


class WatcherRegistrationTests(RegistrationTestCase):
    CLIENT_CAPABILITIES = WATCHER_CAPABILITIES

    def test_the_configuration_is_watched(self):
        registrations = self.watcher_registrations("dls-watch-config")
        self.assertEqual(
            registrations["dls-watch-config"],
            [{"baseUri": harness.path_to_uri(self.root) + "/", "pattern": "dls.json"}],
        )

    def test_each_import_path_is_watched_instead_of_the_workspace_root(self):
        # Anchored at the import path: a multi-root workspace does not get a
        # watcher for every D file it happens to contain.
        registrations = self.watcher_registrations()
        self.assertEqual(
            registrations["dls-watch-import-paths"],
            [{"baseUri": harness.path_to_uri(self.root) + "/", "pattern": "**/*.d"}],
        )


class NestedImportPathTests(RegistrationTestCase):
    """A path inside another one must not produce a second watcher."""

    CLIENT_CAPABILITIES = WATCHER_CAPABILITIES
    IMPORT_PATHS_RELATIVE = ["", "src"]
    PROJECT = {"app.d": "module app;\n\nvoid main() {}\n", "src/lib.d": LEAF}

    def test_nested_import_paths_are_watched_once(self):
        self.assertEqual(
            self.watcher_registrations()["dls-watch-import-paths"],
            [{"baseUri": harness.path_to_uri(self.root) + "/", "pattern": "**/*.d"}],
        )


class NestedImportPathOrderTests(NestedImportPathTests):
    """... and the order in the config must not matter."""

    IMPORT_PATHS_RELATIVE = ["src", ""]


class AbsoluteGlobFallbackTests(RegistrationTestCase):
    """No relative patterns: the glob is absolute, still anchored per path."""

    CLIENT_CAPABILITIES = WATCHER_CAPABILITIES_WITHOUT_RELATIVE

    def test_the_fallback_glob_is_absolute(self):
        registrations = self.watcher_registrations()
        self.assertEqual(registrations["dls-watch-import-paths"], [f"{self.root}/**/*.d"])
        self.assertEqual(registrations["dls-watch-config"], [f"{self.root}/dls.json"])


class NonBooleanCapabilityTests(RegistrationTestCase):
    """Only a boolean 'true' asks for the watchers.

    The capability is read out of the client's JSON, where a field can hold
    anything: a client that spells the flag "yes" (or 1, or an object) must
    not be taken as one that can register watchers, or the server sends a
    request the client cannot honour.
    """

    CLIENT_CAPABILITIES = {
        "workspace": {
            "didChangeWatchedFiles": {
                "dynamicRegistration": "yes",
                "relativePatternSupport": 1,
            }
        }
    }

    def test_a_truthy_flag_does_not_enable_the_watchers(self):
        # The registration would have been sent while handling the handshake's
        # 'initialized'; the request below is answered after that, so what the
        # client has seen by then is what the server sent.
        doc = self.open_doc("app.d")
        self.assertIn("main", {symbol["name"] for symbol in doc.document_symbols()})
        self.assertEqual(self.client.notifications("client/registerCapability"), [])


class LeafProjectMixin:
    """A project whose ``leaf.d`` is imported by ``app_si.d`` / ``app_ex.d``."""

    CLIENT_CAPABILITIES = WATCHER_CAPABILITIES
    PROJECT = {"app_si.d": APP_SI, "app_ex.d": APP_EX, "leaf.d": LEAF}

    def path(self, relpath: str) -> str:
        return os.path.join(self.root, relpath)

    def report(self, relpath: str, type_: int) -> None:
        """Tell the server about a write the editor did not make."""
        self.client.notify(
            "workspace/didChangeWatchedFiles",
            {"changes": [change_event(self.path(relpath), type_)]},
        )


class GeneratedMemberTests(LeafProjectMixin, DlsTestCase):
    """A write on disk is reconciled like a save: re-parse, re-point dependents."""

    def test_generated_member_reaches_its_importers(self):
        app = self.open_doc("app_ex.d")
        self.assertEqual(labels(app.completion("w.ex")["items"]), [])

        mark = len(self.client.stderr_lines())
        # The generator writes the file; the client reports the write.
        harness.write_text(self.path("leaf.d"), LEAF_WITH_EXTRA)
        self.report("leaf.d", 2)

        # A request, so the server has processed the notification by now.
        self.assertIn("extra", labels(app.completion("w.ex")["items"]))
        self.client.wait_for_log_line(
            lambda line: f"caching: {self.path('leaf.d')} content:" in line,
            start=mark,
            timeout=2.0,
        )

    def test_member_removed_outside_the_editor_disappears_again(self):
        app = self.open_doc("app_ex.d")

        harness.write_text(self.path("leaf.d"), LEAF_WITH_EXTRA)
        self.report("leaf.d", 2)
        self.assertIn("extra", labels(app.completion("w.ex")["items"]))

        harness.write_text(self.path("leaf.d"), LEAF)
        self.report("leaf.d", 2)
        self.assertEqual(labels(app.completion("w.ex")["items"]), [])


class OpenDocumentTests(LeafProjectMixin, DlsTestCase):
    """The editor's buffer outranks whatever the write on disk says."""

    def open_leaf(self, text: str = LEAF) -> "harness.Doc":
        """Open leaf.d with 'text', with the file on disk back at 'LEAF'.

        A class shares one server *and* the fixture ``Doc`` objects, so
        whatever an earlier test left in ``Doc.text`` or on disk is still in
        play when this test starts: both are re-anchored here rather than
        inherited.
        """
        harness.write_text(self.path("leaf.d"), LEAF)
        return self.open_doc("leaf.d", text)

    def test_an_open_document_still_wins_over_the_write_on_disk(self):
        leaf = self.open_leaf()
        app = self.open_doc("app_ex.d")
        self.assertEqual(labels(app.completion("w.ex")["items"]), [])

        # The editor holds unsaved edits, and a tool rewrites the file on disk
        # behind its back: the buffer is what the user is looking at, so the
        # buffer is what DCD gets - neither the disk text nor nothing.
        leaf.change(LEAF_WITH_EXTRA, version=2)
        harness.write_text(self.path("leaf.d"), LEAF_WITH_OTHER)
        self.report("leaf.d", 2)

        items = labels(app.completion("w.ex")["items"])
        self.assertIn("extra", items)
        self.assertNotIn("other", items)

    def test_the_editors_own_save_is_reconciled_once(self):
        # A save reaches the server twice: the editor sends 'didSave' and the
        # client's file watcher reports the same write as a change.  The
        # watched copy must not make DCD re-notify every dependent again.
        leaf = self.open_leaf()
        leaf.document_symbols()  # cache whatever the open flow leaves behind

        mark = len(self.client.stderr_lines())
        self.client.did_save(leaf.uri)
        self.report("leaf.d", 2)
        leaf.document_symbols()  # a request, so both are processed

        self.assert_reconciled_once(mark)

    def test_a_save_that_changes_the_text_is_reconciled_once(self):
        leaf = self.open_leaf()
        app = self.open_doc("app_ex.d")
        self.assertEqual(labels(app.completion("w.ex")["items"]), [])

        leaf.change(LEAF_WITH_EXTRA, version=2)
        mark = len(self.client.stderr_lines())
        self.client.did_save(leaf.uri)
        self.report("leaf.d", 2)

        # ... and the save still lands: 'extra' is what the importers see.
        self.assertIn("extra", labels(app.completion("w.ex")["items"]))
        self.assert_reconciled_once(mark)

    def assert_reconciled_once(self, mark: int) -> None:
        """Exactly one 'on_save:' for leaf.d from 'mark' on."""
        self.client.wait_for_log_line(
            lambda line: "on_save:" in line and self.path("leaf.d") in line,
            start=mark,
            timeout=2.0,
        )
        # The reader thread hands stderr over asynchronously: give it room to
        # deliver a second line if the server had written one.
        time.sleep(0.2)

        lines = [
            line
            for line in self.client.stderr_lines()[mark:]
            if "on_save:" in line and self.path("leaf.d") in line
        ]
        self.assertEqual(len(lines), 1, "the save was reconciled twice:\n" + "\n".join(lines))


class DeletedModuleTests(LeafProjectMixin, DlsTestCase):
    """A deleted module must not take the server down (DCD has no eviction)."""

    def test_a_deleted_module_does_not_kill_the_server(self):
        app = self.open_doc("app_si.d")
        self.assertIn("size", labels(app.completion("w.si")["items"]))

        os.unlink(self.path("leaf.d"))
        self.addCleanup(harness.write_text, self.path("leaf.d"), LEAF)
        self.report("leaf.d", 3)

        # A request must still be answered (this raises if the server died).
        self.assertIsNone(self.client.process.poll(), "server died on a deleted file")
        self.assertEqual(app.document_symbols()[0]["name"], "main")

    def test_a_recreated_module_is_picked_up(self):
        app = self.open_doc("app_ex.d")
        self.assertEqual(labels(app.completion("w.ex")["items"]), [])

        # A generator rewrites the file the editor never saw: the create
        # report has to be enough for the new member to become visible.
        self.report("leaf.d", 3)
        harness.write_text(self.path("leaf.d"), LEAF_WITH_EXTRA)
        self.report("leaf.d", 1)

        self.assertIn("extra", labels(app.completion("w.ex")["items"]))


class GeneratedModuleTests(DlsTestCase):
    """A module a tool creates after the importing file was already cached."""

    CLIENT_CAPABILITIES = WATCHER_CAPABILITIES
    PROJECT = {"app.d": APP_GEN}

    def path(self, relpath: str) -> str:
        return os.path.join(self.root, relpath)

    def test_module_generated_later_becomes_visible(self):
        app = self.open_doc("app.d")
        # 'gen' is not on disk yet, so the import has nothing to bind to.
        self.assertEqual(labels(app.completion("g.st")["items"]), [])

        harness.write_text(self.path("gen.d"), GEN)
        self.client.notify(
            "workspace/didChangeWatchedFiles",
            {"changes": [change_event(self.path("gen.d"), 1)]},
        )

        self.assertIn("stuff", labels(app.completion("g.st")["items"]))


class ImportPathFilterTests(DlsTestCase):
    """Only the import paths are reconciled: a workspace is bigger than that."""

    CLIENT_CAPABILITIES = WATCHER_CAPABILITIES
    # Everything the project imports lives here; the workspace root does not
    # import anything else, so it must not be watched.
    IMPORT_PATHS_RELATIVE = ["src"]
    PROJECT = {
        "src/app_si.d": APP_SI,
        "src/app_ex.d": APP_EX,
        "src/leaf.d": LEAF,
        "outside/other.d": LEAF,
    }

    def path(self, relpath: str) -> str:
        return os.path.join(self.root, relpath)

    def report(self, relpath: str, type_: int) -> None:
        self.client.notify(
            "workspace/didChangeWatchedFiles",
            {"changes": [change_event(self.path(relpath), type_)]},
        )

    def test_a_write_outside_the_import_paths_is_ignored(self):
        app = self.open_doc("src/app_si.d")
        self.assertIn("size", labels(app.completion("w.si")["items"]))

        mark = len(self.client.stderr_lines())
        harness.write_text(self.path("outside/other.d"), LEAF_WITH_EXTRA)
        self.report("outside/other.d", 2)
        app.document_symbols()  # a request, so the notification is processed

        lines = self.client.stderr_lines()[mark:]
        self.assertFalse(
            any(f"caching: {self.path('outside/other.d')}" in line for line in lines),
            "a file outside the import paths was re-cached:\n" + "\n".join(lines),
        )

    def test_a_write_inside_the_import_paths_is_reconciled(self):
        app = self.open_doc("src/app_ex.d")
        self.assertEqual(labels(app.completion("w.ex")["items"]), [])

        harness.write_text(self.path("src/leaf.d"), LEAF_WITH_EXTRA)
        self.report("src/leaf.d", 2)

        self.assertIn("extra", labels(app.completion("w.ex")["items"]))

    def test_an_open_document_is_reconciled_wherever_it_lives(self):
        # Outside the import paths, but open: the editor owns it, so a report
        # for it is not noise - the buffer is what the user is looking at.
        other = self.open_doc("outside/other.d")
        other.change(LEAF_WITH_EXTRA, version=2)  # unsaved, and not re-cached

        mark = len(self.client.stderr_lines())
        self.report("outside/other.d", 2)
        other.document_symbols()

        lines = self.client.stderr_lines()[mark:]
        self.assertTrue(
            any(f"caching: {self.path('outside/other.d')}" in line for line in lines),
            "an open document outside the import paths was skipped:\n" + "\n".join(lines),
        )
