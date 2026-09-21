"""What a save costs: reconcile dependents, but never re-parse unchanged text.

`didChange` deliberately only refreshes the server's buffer; a save is the
reconciliation point.  A save whose text is byte-identical to what DCD already
cached still has to tell the dependents (that pass is what re-points importers
at the live symbol tree), but it must not lex/parse/rebuild the module -- the
parse is the expensive half, and editors hand out identical saves constantly
(Ctrl+S, save on focus change, a format-on-save that changes nothing).

The assertions look at the server log because the cache work is otherwise
invisible: `caching: <path>` is emitted per parse, `update dep: <path>` per
dependent notification.
"""

import harness
from harness import DlsTestCase, labels

# The log scan below must not race the client's stderr ring buffer.
harness.STDERR_TAIL_LINES = 50000


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


class SaveFlowTestCase(DlsTestCase):
    def project_log(self, mark):
        """Log lines from 'mark' on that mention this project."""
        return [line for line in self.client.stderr_lines()[mark:] if self.root in line]

    def assert_reparsed(self, lines, module, expected):
        needle = f"caching: {self.root}/{module} content:"
        found = any(needle in line for line in lines)
        self.assertEqual(found, expected, f"{module} re-parse log mismatch:\n" + "\n".join(lines))


class IdenticalSaveTests(SaveFlowTestCase):
    PROJECT = {"leaf.d": LEAF, "app_si.d": APP_SI}

    def test_identical_save_only_notifies_dependents(self):
        leaf = self.open_doc("leaf.d")
        app = self.open_doc("app_si.d")
        self.assertIn("size", labels(app.completion("w.si")["items"]))

        mark = len(self.client.stderr_lines())
        for version in (2, 3, 4):
            leaf.change(LEAF, version=version)  # byte-identical to what was cached
            self.client.did_save(leaf.uri)

        # didSave is a notification: this request makes sure the server has
        # processed it, and the log wait makes sure the reader thread has
        # handed the lines over -- sampling the log right after is a race.
        app.document_symbols()
        self.client.wait_for_log_line(
            lambda line: "update dep" in line and "app_si.d" in line,
            start=mark,
            timeout=2.0,
        )
        lines = self.project_log(mark)

        self.assert_reparsed(lines, "leaf.d", expected=False)
        self.assertTrue(
            any("update dep" in line and "app_si.d" in line for line in lines),
            "identically-saved module did not notify its dependents:\n" + "\n".join(lines),
        )
        # ... and the dependents still work.
        self.assertIn("size", labels(app.completion("w.si")["items"]))


class ChangedSaveTests(SaveFlowTestCase):
    PROJECT = {"leaf.d": LEAF, "app_ex.d": APP_EX}

    def test_changed_save_reparses_and_propagates(self):
        leaf = self.open_doc("leaf.d")
        app = self.open_doc("app_ex.d")
        self.assertEqual(labels(app.completion("w.ex")["items"]), [])

        mark = len(self.client.stderr_lines())
        leaf.change(LEAF_WITH_EXTRA, version=2)
        self.client.did_save(leaf.uri)

        # The completion is a request, so the server has processed the save;
        # wait for the reader thread to hand over the log lines it wrote.
        self.assertIn("extra", labels(app.completion("w.ex")["items"]))
        self.client.wait_for_log_line(
            lambda line: f"caching: {self.root}/leaf.d content:" in line,
            start=mark,
            timeout=2.0,
        )
        lines = self.project_log(mark)
        self.assert_reparsed(lines, "leaf.d", expected=True)

    def test_member_removed_by_a_save_disappears_again(self):
        leaf = self.open_doc("leaf.d")
        app = self.open_doc("app_ex.d")

        leaf.change(LEAF_WITH_EXTRA, version=2)
        self.client.did_save(leaf.uri)
        self.assertIn("extra", labels(app.completion("w.ex")["items"]))

        leaf.change(LEAF, version=3)
        self.client.did_save(leaf.uri)
        self.assertEqual(labels(app.completion("w.ex")["items"]), [])
