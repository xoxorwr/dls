"""The built-in unused-import / unused-parameter lint.

Unlike ``test_diagnostics.py`` (the external ``check`` command pipeline),
this one needs no external tool: ``dls`` classifies the file itself
(``dcd_unused_symbols``) and publishes a ``Hint`` + ``Unnecessary`` diagnostic
per unused import name/binding or parameter, each carrying a ``code`` the
remove-import code action (see ``test_code_action.py``) matches on.
"""

from harness import DlsTestCase


LIB = """module lib;

struct Thing
{
    int x;
}

void helper() {}
"""

SELECTIVE_LIB = """module selective_lib;

void usedThing() {}
void unusedThing() {}
"""

UNUSED_MOD = """module unused_mod;

void something() {}
"""

LIB2 = """module lib2;

void lib2Thing() {}
"""

LOCAL_UNUSED_MOD = """module local_unused_mod;

void neverCalled() {}
"""

APP = """module app;

import lib;
import unused_mod;
public import lib2;
import selective_lib : usedThing, unusedThing;

interface Greeter
{
    void greet(string name);
}

class EnglishGreeter : Greeter
{
    override void greet(string name)
    {
    }
}

void plain(int keep, int drop)
{
    int y = keep;
}

void withUnderscore(int _ignored)
{
}

void main()
{
    import local_unused_mod;

    helper();
    Thing t;
    usedThing();
    auto cb = (int x) { };
}
"""


class UnusedDiagnosticsTests(DlsTestCase):
    PROJECT = {
        "app.d": APP,
        "lib.d": LIB,
        "selective_lib.d": SELECTIVE_LIB,
        "unused_mod.d": UNUSED_MOD,
        "lib2.d": LIB2,
        "local_unused_mod.d": LOCAL_UNUSED_MOD,
    }

    def _wait_for_diagnostics(self, uri, start=0):
        return self.client.wait_for_notification(
            "textDocument/publishDiagnostics",
            lambda message: message["params"]["uri"] == uri,
            start=start,
            timeout=20.0,
        )

    def _open_and_get_diagnostics(self, relpath="app.d"):
        doc = self.open_doc(relpath)
        _, message = self._wait_for_diagnostics(doc.uri)
        return doc, message["params"]["diagnostics"]

    @staticmethod
    def _find(diagnostics, code, needle):
        for d in diagnostics:
            if d.get("code") == code and needle in d.get("message", ""):
                return d
        return None

    def test_an_unused_whole_module_import_is_flagged(self):
        doc, diagnostics = self._open_and_get_diagnostics()
        found = self._find(diagnostics, "unused-import", "unused_mod")
        self.assertIsNotNone(found, diagnostics)
        self.assertEqual(found["severity"], 4)
        self.assertEqual(found["tags"], [1])
        self.assertEqual(found["source"], "dls")
        self.assertIn("data", found)
        self.assertIn("removeStart", found["data"])
        self.assertIn("removeLength", found["data"])

    def test_a_used_whole_module_import_is_not_flagged(self):
        doc, diagnostics = self._open_and_get_diagnostics()
        self.assertIsNone(self._find(diagnostics, "unused-import", "'lib'"))

    def test_a_public_import_is_never_flagged_even_if_unused(self):
        doc, diagnostics = self._open_and_get_diagnostics()
        self.assertIsNone(self._find(diagnostics, "unused-import", "lib2"))

    def test_a_local_import_inside_a_function_is_never_flagged(self):
        # A stated v1 limitation, not a silent gap: only module-level imports
        # are checked (dcd_unused_symbols' AST walk does not descend into
        # function bodies looking for local `import` statements), so a truly
        # unused local import is not caught - unlike an unused local
        # *variable*, which is out of scope for this check entirely either
        # way (only imports and parameters are).
        doc, diagnostics = self._open_and_get_diagnostics()
        self.assertIsNone(self._find(diagnostics, "unused-import", "local_unused_mod"))

    def test_an_unused_selective_binding_is_flagged_but_not_the_used_one(self):
        doc, diagnostics = self._open_and_get_diagnostics()
        self.assertIsNotNone(self._find(diagnostics, "unused-import", "unusedThing"))
        self.assertIsNone(self._find(diagnostics, "unused-import", "'usedThing'"))

    def test_an_unused_parameter_is_flagged(self):
        doc, diagnostics = self._open_and_get_diagnostics()
        found = self._find(diagnostics, "unused-parameter", "drop")
        self.assertIsNotNone(found, diagnostics)
        self.assertEqual(found["severity"], 4)
        self.assertEqual(found["tags"], [1])
        self.assertNotIn("data", found)

    def test_a_used_parameter_is_not_flagged(self):
        doc, diagnostics = self._open_and_get_diagnostics()
        self.assertIsNone(self._find(diagnostics, "unused-parameter", "keep"))

    def test_an_override_methods_unused_parameter_is_not_flagged(self):
        doc, diagnostics = self._open_and_get_diagnostics()
        self.assertIsNone(self._find(diagnostics, "unused-parameter", "name"))

    def test_an_underscore_prefixed_parameter_is_not_flagged(self):
        doc, diagnostics = self._open_and_get_diagnostics()
        self.assertIsNone(self._find(diagnostics, "unused-parameter", "_ignored"))

    def test_a_lambdas_unused_parameter_is_not_flagged(self):
        doc, diagnostics = self._open_and_get_diagnostics()
        # The lambda's only parameter is also named 'x' - distinguishable
        # from 'plain's here because nothing named 'x' is a flagged
        # parameter at all when lambdas are correctly skipped.
        self.assertIsNone(self._find(diagnostics, "unused-parameter", "'x'"))


class UnusedDiagnosticsDisabledTests(DlsTestCase):
    """dls.json's "unusedDiagnostics": false turns the whole check off."""

    PROJECT = {
        "app.d": """module app;

import unused_mod;

void main() {}
""",
        "unused_mod.d": UNUSED_MOD,
    }
    UNUSED_DIAGNOSTICS = False

    def test_no_unused_diagnostics_are_published(self):
        doc = self.open_doc("app.d")
        # Nothing else would publish for this file, so a folding request -
        # answered in order, after any didOpen-triggered lint - is enough to
        # know no publishDiagnostics is still coming.
        doc.folding_range()
        for message in self.client.notifications("textDocument/publishDiagnostics"):
            if message["params"]["uri"] == doc.uri:
                self.assertEqual(message["params"]["diagnostics"], [])
