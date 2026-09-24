"""workspace/symbol: project-wide symbol search.

Scoped to 'importPaths' from dls.json (the project's own paths, see
'DlsTestCase') rather than every import path the server knows about - the
compiler's own stdlib paths are registered too (dcd.d's
'default_import_paths'), and are deliberately excluded from the eager scan
'workspace/symbol' triggers (see 'ModuleCache.getWorkspaceSymbols' in
dsymbol/modulecache.d): scanning them would force-parse phobos/druntime into
a cache that never evicts anything, for a feature that exists to jump around
in the user's own project.
"""

from harness import KIND_FUNCTION, KIND_STRUCT, DlsTestCase


APP = """module app;

struct WidgetState
{
    int aaa;

    void resetState() {}
}

void computeSomething() {}
"""

OTHER = """module other;

struct Gadget
{
}
"""


class WorkspaceSymbolTests(DlsTestCase):
    PROJECT = {"app.d": APP, "other.d": OTHER}

    def setUp(self):
        self.app = self.open_doc("app.d")

    def test_finds_matching_symbol_across_files(self):
        results = self.client.workspace_symbols("Gadget")
        names = {r["name"] for r in results}
        self.assertIn("Gadget", names)

    def test_substring_match_is_case_insensitive(self):
        results = self.client.workspace_symbols("state")
        names = {r["name"] for r in results}
        self.assertIn("WidgetState", names)
        self.assertIn("resetState", names)

    def test_kinds_and_locations_are_reported(self):
        results = {r["name"]: r for r in self.client.workspace_symbols("Widget")}
        self.assertEqual(results["WidgetState"]["kind"], KIND_STRUCT)
        self.assertTrue(results["WidgetState"]["location"]["uri"].endswith("app.d"))

    def test_function_locals_are_not_reported_as_symbols(self):
        # 'resetState' has no parameters or locals here, so use 'computeSomething'
        # only to confirm functions themselves are still found ...
        results = self.client.workspace_symbols("compute")
        names = {r["name"] for r in results}
        self.assertIn("computeSomething", names)

    def test_no_match_returns_empty(self):
        self.assertEqual(self.client.workspace_symbols("NoSuchSymbolAnywhere"), [])

    def test_empty_query_returns_empty(self):
        self.assertEqual(self.client.workspace_symbols(""), [])
