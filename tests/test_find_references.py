"""textDocument/references: every occurrence of a symbol across the project.

Scoped to 'importPaths' from dls.json (see 'DlsTestCase' and
'workspace/symbol'), not every import path the server knows about - see
'ModuleCache.getWorkspaceSymbols' in dsymbol/modulecache.d and
'dcd_find_references' in dll.d for why the compiler's stdlib paths are
excluded from the eager per-file scan this needs.

Click positions here always land inside or at the start of an identifier's
own token, one character short of its end (`offset=-1`) - not bang on the
boundary right after it. `textDocument/definition` has the same requirement:
clicking exactly at the end of a *bare, uninitialized* declaration's type
name (`Gadget g;`, as opposed to `Gadget g2 = new Gadget();`) makes the
shared resolution pipeline ('getSymbolsForCompletion' with
'CompletionType.location', dcd/server/autocomplete/util.d) resolve to the
variable's own declaration instead of the type - a pre-existing quirk of
that shared pipeline (confirmed identical on `textDocument/definition`), not
something 'dcd_find_references' introduces. Tests below click on the
initialized declaration/an expression use instead, which resolves correctly.
"""

from harness import DlsTestCase


APP = """module app;
import other;

struct Widget
{
    int value;

    void bump()
    {
        value = value + 1;
    }
}

int unrelatedValue(int value)
{
    return value;
}

void useGadget()
{
    Gadget g2 = new Gadget();
    g2.run();
}

void main()
{
    Widget w;
    w.bump();
}
"""

OTHER = """module other;

class Gadget
{
    void run() {}
}
"""


class FindReferencesTests(DlsTestCase):
    PROJECT = {"app.d": APP, "other.d": OTHER}

    def setUp(self):
        self.app = self.open_doc("app.d")
        self.other = self.open_doc("other.d")

    def test_finds_member_references_within_one_file(self):
        results = self.app.references("int value", offset=-1)
        self.assertEqual(len(results), 3)  # declaration + 2 uses in bump()
        for r in results:
            self.assertTrue(r["uri"].endswith("app.d"))

    def test_excludes_unrelated_same_named_symbol(self):
        results = self.app.references("int value", offset=-1)
        lines = {r["range"]["start"]["line"] for r in results}
        unrelated_line, _ = self.app.position("int value)")
        self.assertNotIn(unrelated_line, lines)

    def test_include_declaration_false_drops_the_declaration_site(self):
        with_decl = self.app.references("int value", offset=-1, include_declaration=True)
        without_decl = self.app.references("int value", offset=-1, include_declaration=False)
        self.assertEqual(len(with_decl), 3)
        self.assertEqual(len(without_decl), 2)

    def test_finds_references_across_files(self):
        results = self.other.references("class Gadget", offset=-1)
        # declaration (other.d) + 2 uses in app.d ('Gadget g2 = new Gadget();')
        self.assertEqual(len(results), 3)
        by_file = sorted(r["uri"].rsplit("/", 1)[-1] for r in results)
        self.assertEqual(by_file, ["app.d", "app.d", "other.d"])

    def test_lookup_from_a_usage_site_finds_the_same_set(self):
        from_decl = self.other.references("class Gadget", offset=-1)
        # the second 'Gadget' on that line: 'new Gadget()'.
        from_use = self.app.references("Gadget", offset=-1, occurrence=1)
        self.assertEqual(len(from_decl), len(from_use))

    def test_no_symbol_at_position_returns_empty(self):
        # right after the import statement's ';' - no identifier there
        results = self.app.references("import other;")
        self.assertEqual(results, [])
