"""dls.json is watched: editing or creating it takes effect while the server runs.

The configuration is the server's only channel (no `initializationOptions`, no
command line switches), so it is also the one thing a user must be able to
change without restarting anything: the client is asked to watch `dls.json`,
and a change to it re-applies the file - the import paths (with DCD and with
the file watcher) and the checker commands.
"""

import json
import os
import time

import harness
from harness import DlsTestCase, labels

#: A client that registers file watchers and advertises relative patterns.
WATCHER_CAPABILITIES = {
    "workspace": {
        "didChangeWatchedFiles": {
            "dynamicRegistration": True,
            "relativePatternSupport": True,
        }
    }
}

ONE = """module one;

struct Foo
{
    int aa;
}
"""

TWO = """module two;

struct Bar
{
    int bb;
}
"""

LIB = """module lib;

struct Widget
{
    int size;
}
"""

APP_ONE = """module app_one;

import one;

void main()
{
    Foo f;
    f.aa
}
"""

APP_TWO = """module app_two;

import two;

void main()
{
    Bar b;
    b.bb
}
"""

APP_LIB = """module app;

import lib;

void main()
{
    Widget w;
    w.si
}
"""


class ConfigReloadTestCase(DlsTestCase):
    CLIENT_CAPABILITIES = WATCHER_CAPABILITIES

    def path(self, relpath: str) -> str:
        return os.path.join(self.root, relpath)

    def write_config(self, import_paths: list[str]) -> None:
        harness.write_text(self.path("dls.json"), json.dumps({"importPaths": import_paths}))

    def report_config_change(self, type_: int = 2) -> None:
        self.client.notify(
            "workspace/didChangeWatchedFiles",
            {
                "changes": [
                    {"uri": harness.path_to_uri(self.path("dls.json")), "type": type_}
                ]
            },
        )

    def reloaded(self, mark: int) -> None:
        """Wait for the reload to be logged (the reader thread lags behind)."""
        self.client.wait_for_log_line(
            lambda line: "configuration applied" in line and "import path" in line,
            start=mark,
            timeout=2.0,
        )

    def newest_import_path_watchers(self):
        """The import-path registration's patterns (there may be several)."""
        patterns = None
        for message in self.client.notifications("client/registerCapability"):
            for registration in message["params"]["registrations"]:
                if registration["id"] == "dls-watch-import-paths":
                    patterns = [
                        watcher["globPattern"]
                        for watcher in registration["registerOptions"]["watchers"]
                    ]
        return patterns

    def unregistered_import_paths(self) -> bool:
        return any(
            unregistration["id"] == "dls-watch-import-paths"
            for message in self.client.notifications("client/unregisterCapability")
            for unregistration in message["params"]["unregisterations"]
        )


class AddedImportPathTests(ConfigReloadTestCase):
    """A directory added to 'importPaths' starts resolving."""

    IMPORT_PATHS_RELATIVE = ["a"]
    PROJECT = {
        "a/one.d": ONE,
        "b/two.d": TWO,
        "app_one.d": APP_ONE,
        "app_two.d": APP_TWO,
    }

    def test_an_import_path_added_to_dls_json_starts_resolving(self):
        self.start_with(["a"])
        app = self.open_doc("app_two.d")
        self.assertEqual(labels(app.completion("b.bb")["items"]), [])

        mark = len(self.client.stderr_lines())
        self.write_config(["a", "b"])
        self.report_config_change()

        # The notification is processed in order, so this request sees the
        # reload already.
        self.assertIn("bb", labels(app.completion("b.bb")["items"]))
        self.reloaded(mark)

        # ... and the new directory is watched from now on.
        self.assertIn(
            {"baseUri": harness.path_to_uri(self.path("b")) + "/", "pattern": "**/*.d"},
            self.newest_import_path_watchers(),
        )
        self.assertTrue(
            self.unregistered_import_paths(),
            "the old import-path registration was not replaced",
        )

    def test_an_import_path_removed_from_dls_json_stops_resolving(self):
        self.start_with(["a", "b"])
        app = self.open_doc("app_one.d")
        self.assertIn("aa", labels(app.completion("f.aa")["items"]))

        mark = len(self.client.stderr_lines())
        self.write_config(["b"])
        self.report_config_change()

        # DCD's cache was built against the old paths, so the reload drops it;
        # the removed directory must not resolve any more.
        self.assertEqual(labels(app.completion("f.aa")["items"]), [])
        self.reloaded(mark)
        self.assertEqual(
            self.newest_import_path_watchers(),
            [{"baseUri": harness.path_to_uri(self.path("b")) + "/", "pattern": "**/*.d"}],
        )

    def test_a_checker_only_change_keeps_the_registration(self):
        self.start_with(["a"])
        app = self.open_doc("app_one.d")
        self.assertIn("aa", labels(app.completion("f.aa")["items"]))

        mark = len(self.client.stderr_lines())
        harness.write_text(
            self.path("dls.json"),
            json.dumps({"importPaths": ["a"], "check": [{"path": "a/", "cmd": "true"}]}),
        )
        self.report_config_change()

        self.assertIn("aa", labels(app.completion("f.aa")["items"]))
        self.reloaded(mark)
        self.assertFalse(
            self.unregistered_import_paths(),
            "unchanged import paths must not churn the registration",
        )

    def test_a_second_report_of_the_same_save_is_ignored(self):
        # A save reaches the server more than once (one event per write, and
        # two for a rename-based save), so the second report of identical text
        # must not re-apply the configuration: the checkers would run again
        # over every open document, and a changed path list would rebuild
        # DCD's cache a second time.
        self.start_with(["a"])
        app = self.open_doc("app_two.d")
        self.assertEqual(labels(app.completion("b.bb")["items"]), [])

        mark = len(self.client.stderr_lines())
        self.write_config(["a", "b"])
        self.report_config_change()
        self.report_config_change()

        self.assertIn("bb", labels(app.completion("b.bb")["items"]))
        self.reloaded(mark)

        lines = self.client.stderr_lines()[mark:]
        applied = [line for line in lines if "configuration applied" in line]
        rebuilt = [line for line in lines if "rebuilding DCD's cache" in line]
        self.assertEqual(len(applied), 1, "the configuration was applied twice:\n" + "\n".join(lines))
        self.assertEqual(len(rebuilt), 1, "DCD was rebuilt twice:\n" + "\n".join(lines))
        # The repeated report leaves no trace at all in the log: 'info' is off
        # by default, and the client shows every stderr line as an error.
        self.assertFalse(
            any("applying dls.json" in line for line in lines[lines.index(applied[0]) + 1 :]),
            "the repeated report was applied again:\n" + "\n".join(lines),
        )

    def start_with(self, import_paths: list[str]) -> None:
        """Put 'importPaths' in effect before the test body runs.

        A class shares one server *and* one dls.json, so a test cannot assume
        the file another test left behind; asking for the state it needs is
        also free when the state is already there (an unchanged config is not
        re-applied).
        """
        self.write_config(import_paths)
        self.report_config_change()


class CreatedConfigTests(ConfigReloadTestCase):
    """A workspace whose dls.json appears after the server started."""

    WRITE_DLS_JSON = False
    PROJECT = {"src/lib.d": LIB, "app.d": APP_LIB}

    def test_creating_dls_json_starts_resolving_imports(self):
        app = self.open_doc("app.d")
        self.assertEqual(labels(app.completion("w.si")["items"]), [])

        mark = len(self.client.stderr_lines())
        self.write_config(["src"])
        self.report_config_change(1)  # FileChangeType.Created

        self.assertIn("size", labels(app.completion("w.si")["items"]))
        self.reloaded(mark)
        self.assertEqual(
            self.newest_import_path_watchers(),
            [{"baseUri": harness.path_to_uri(self.path("src")) + "/", "pattern": "**/*.d"}],
        )

    def test_deleting_dls_json_takes_the_import_paths_away(self):
        self.write_config(["src"])
        # The server read dls.json at initialize, before the file existed, so
        # this is the create path - then the file goes away again.
        app = self.open_doc("app.d")
        self.report_config_change(1)
        self.assertIn("size", labels(app.completion("w.si")["items"]))

        mark = len(self.client.stderr_lines())
        os.unlink(self.path("dls.json"))
        self.addCleanup(self.write_config, ["src"])
        self.report_config_change(3)  # FileChangeType.Deleted

        self.assertEqual(labels(app.completion("w.si")["items"]), [])
        self.reloaded(mark)
