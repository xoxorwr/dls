"""The remove-unused-import quickfix (`textDocument/codeAction`).

No analysis happens on the request itself: the client hands back a
diagnostic it already has from `publishDiagnostics` in `context.diagnostics`,
and the server reads the removal byte range straight out of that
diagnostic's own `data` field (put there by `lint_unused_symbols`) to build
the edit.
"""

from harness import DlsTestCase


LONE_IMPORT = """module app;

import unused_mod;

void main() {}
"""

MULTI_WHOLE_IMPORT = """module app;

import used_mod, unused_mod;

void main()
{
    used_mod.usedThing();
}
"""

MULTI_SELECTIVE_IMPORT = """module app;

import lib : used, unused;

void main()
{
    used();
}
"""

UNUSED_PARAM = """module app;

void plain(int drop)
{
}
"""

TWO_UNUSED_WHOLE_IMPORTS = """module app;

import first_mod;
import second_mod;

void main() {}
"""

# `second` and `third` are unused and adjacent in the same selective list,
# with `first` (used) ahead of them - the shape that used to leave a
# dangling `, ;` once `second`'s and `third`'s individually-computed
# removal ranges (each built as if it alone were being deleted) were merged
# into one edit: `second`'s own range reaches only its own trailing comma,
# never the one separating it from `first`, and only `third` - the actual
# last binding - reaches backward for the shared comma between them.
TRAILING_UNUSED_SELECTIVE_IMPORTS = """module app;

import lib2 : first, second, third;

void main()
{
    first();
}
"""


class CodeActionTests(DlsTestCase):
    PROJECT = {
        "app.d": LONE_IMPORT,
        "unused_mod.d": "module unused_mod;\nvoid something() {}\n",
        "used_mod.d": "module used_mod;\nvoid usedThing() {}\n",
        "lib.d": "module lib;\nvoid used() {}\nvoid unused() {}\n",
        "first_mod.d": "module first_mod;\nvoid firstThing() {}\n",
        "second_mod.d": "module second_mod;\nvoid secondThing() {}\n",
        "lib2.d": "module lib2;\n"
                  "void first() {}\nvoid second() {}\nvoid third() {}\n",
    }

    def _open_and_wait_for(self, text, code, name, relpath="app.d"):
        """Open (or re-open) 'relpath' with 'text' and wait for the
        publishDiagnostics that carries the ('code', 'name') diagnostic this
        test is about.

        The server and its notification log are shared across every test in
        this class, and two things race against "the next publishDiagnostics
        for this uri": a closed-then-reopened document's own close (from a
        previous test's cleanup) can still publish an empty one after this
        open, and an *earlier* test's fixture can carry the same ('code',
        'name') this one does (two fixtures both importing 'unused_mod', say)
        and so satisfy a content check on its own stale notification.  A
        'start' index scoped to after this open, plus waiting for the
        content this test actually wants rather than just any notification
        for the uri, is what makes both races harmless.
        """
        start = len(self.client.notifications())
        doc = self.open_doc(relpath, text)

        def has_it(message):
            if message["params"]["uri"] != doc.uri:
                return False
            return self._find(message["params"]["diagnostics"], code, name) is not None

        _, message = self.client.wait_for_notification(
            "textDocument/publishDiagnostics", has_it, start=start, timeout=20.0
        )
        return doc, message["params"]["diagnostics"]

    @staticmethod
    def _find(diagnostics, code, name):
        for d in diagnostics:
            if d.get("code") == code and d.get("data", {}).get("name") == name:
                return d
        return None

    @staticmethod
    def _offset(text, position):
        lines = text.split("\n")
        return sum(len(l) + 1 for l in lines[: position["line"]]) + position["character"]

    def _apply(self, text, edits):
        # Every fixture here produces exactly one edit; applied by byte
        # offset the way a client would.
        assert len(edits) == 1
        edit = edits[0]
        start = self._offset(text, edit["range"]["start"])
        end = self._offset(text, edit["range"]["end"])
        return text[:start] + edit["newText"] + text[end:]

    def test_a_lone_import_is_removed_whole_with_its_line(self):
        doc, diagnostics = self._open_and_wait_for(LONE_IMPORT, "unused-import", "unused_mod")
        diagnostic = self._find(diagnostics, "unused-import", "unused_mod")

        actions = doc.code_action(diagnostics=[diagnostic])
        self.assertEqual(len(actions), 1)
        action = actions[0]
        self.assertEqual(action["kind"], "quickfix")
        self.assertIn("unused_mod", action["title"])

        edits = action["edit"]["changes"][doc.uri]
        result = self._apply(LONE_IMPORT, edits)
        # The import's own line is gone; the blank line that surrounded it
        # on both sides is not collapsed further than that.
        self.assertEqual(result, "module app;\n\n\nvoid main() {}\n")
        self.assertNotIn("import", result)

    def test_only_the_unused_name_is_removed_from_a_multi_import_statement(self):
        doc, diagnostics = self._open_and_wait_for(MULTI_WHOLE_IMPORT, "unused-import", "unused_mod")
        diagnostic = self._find(diagnostics, "unused-import", "unused_mod")

        actions = doc.code_action(diagnostics=[diagnostic])
        edits = actions[0]["edit"]["changes"][doc.uri]
        result = self._apply(MULTI_WHOLE_IMPORT, edits)

        self.assertIn("import used_mod;", result)
        self.assertNotIn("unused_mod", result)

    def test_only_the_unused_binding_is_removed_from_a_selective_import(self):
        doc, diagnostics = self._open_and_wait_for(MULTI_SELECTIVE_IMPORT, "unused-import", "unused")
        diagnostic = self._find(diagnostics, "unused-import", "unused")

        actions = doc.code_action(diagnostics=[diagnostic])
        edits = actions[0]["edit"]["changes"][doc.uri]
        result = self._apply(MULTI_SELECTIVE_IMPORT, edits)

        self.assertIn("import lib : used;", result)
        self.assertNotIn("unused;", result)

    def test_no_action_is_offered_for_an_unused_parameter(self):
        start = len(self.client.notifications())
        doc = self.open_doc("app.d", UNUSED_PARAM)

        def has_it(message):
            if message["params"]["uri"] != doc.uri:
                return False
            return any(d.get("code") == "unused-parameter"
                       for d in message["params"]["diagnostics"])

        _, message = self.client.wait_for_notification(
            "textDocument/publishDiagnostics", has_it, start=start, timeout=20.0
        )
        diagnostic = next(d for d in message["params"]["diagnostics"]
                           if d.get("code") == "unused-parameter")

        actions = doc.code_action(diagnostics=[diagnostic])
        self.assertEqual(actions, [])

    def test_no_action_is_offered_for_an_unrelated_diagnostic(self):
        doc, _ = self._open_and_wait_for(LONE_IMPORT, "unused-import", "unused_mod")
        fake = {
            "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 1}},
            "severity": 1,
            "message": "not one of ours",
        }
        self.assertEqual(doc.code_action(diagnostics=[fake]), [])

    def _apply_all(self, text, edits):
        # Applies every edit of a (possibly multi-edit) action, by byte
        # offset, back to front so an earlier edit's range stays valid.
        result = text
        for edit in sorted(edits, key=lambda e: -self._offset(text, e["range"]["start"])):
            start = self._offset(text, edit["range"]["start"])
            end = self._offset(text, edit["range"]["end"])
            result = result[:start] + edit["newText"] + result[end:]
        return result

    def test_no_bulk_action_with_a_single_unused_import(self):
        # LONE_IMPORT has exactly one unused import: only its own quickfix
        # is offered, no separate "remove all" alongside it.
        doc, diagnostics = self._open_and_wait_for(LONE_IMPORT, "unused-import", "unused_mod")
        diagnostic = self._find(diagnostics, "unused-import", "unused_mod")
        actions = doc.code_action(diagnostics=[diagnostic])
        self.assertEqual(len(actions), 1)
        self.assertNotIn("all", actions[0]["title"].lower())

    def test_bulk_action_removes_every_unused_whole_module_import(self):
        doc, diagnostics = self._open_and_wait_for(
            TWO_UNUSED_WHOLE_IMPORTS, "unused-import", "second_mod"
        )
        # The client only handed back a fake, unrelated diagnostic here - a
        # stand-in for a real client that only sends the diagnostics
        # overlapping the requested range, not the whole file's. The bulk
        # action must find every unused import on its own regardless.
        actions = doc.code_action(diagnostics=[])
        bulk = next(a for a in actions if a["title"].startswith("Remove all unused imports"))
        self.assertIn("(2)", bulk["title"])
        self.assertEqual(bulk["kind"], "quickfix")

        edits = bulk["edit"]["changes"][doc.uri]
        result = self._apply_all(TWO_UNUSED_WHOLE_IMPORTS, edits)
        self.assertNotIn("import", result)
        # The blank lines that surrounded the import block are not collapsed
        # any further, same as removing a single import (see
        # test_a_lone_import_is_removed_whole_with_its_line).
        self.assertEqual(result, "module app;\n\n\nvoid main() {}\n")

    def test_bulk_action_does_not_leave_a_dangling_comma(self):
        """Regression: merging two adjacent unused selective-import bindings
        whose individually-computed removal ranges overlap on the comma
        between them must not leave a trailing ", ;" - that doesn't compile.
        """
        doc, diagnostics = self._open_and_wait_for(
            TRAILING_UNUSED_SELECTIVE_IMPORTS, "unused-import", "third"
        )
        actions = doc.code_action(diagnostics=[])
        bulk = next(a for a in actions if a["title"].startswith("Remove all unused imports"))
        self.assertIn("(2)", bulk["title"])

        edits = bulk["edit"]["changes"][doc.uri]
        result = self._apply_all(TRAILING_UNUSED_SELECTIVE_IMPORTS, edits)
        self.assertIn("import lib2 : first;", result)
        self.assertNotIn(",", result.split("import lib2")[1].split("\n")[0])
        self.assertNotIn("second", result)
        self.assertNotIn("third", result)
