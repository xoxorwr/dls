"""Completions for symbols forwarded by ``public import`` must survive caching.

Regression tests for a module-cache lifecycle bug.  With a two-level
forwarding chain::

    app --import--> m1 --public import--> m2 --public import--> leaf

opening the documents in the order ``app, m1, m2, leaf`` makes the app lose
*every* completion for symbols that reach it through the chain, while opening
``leaf`` first is fine.  Saving a forwarder restores the completions and
re-opening the origin drops them again, which is why the failure looks
intermittent while editing.

Why: every ``didOpen``/``didSave`` re-caches the module, and
``ModuleCache.cacheModule`` does ``cache.insert(newEntry)`` (a no-op, the tree
is keyed by path and ``TTree.insert`` does not overwrite) followed by
``cache.remove(oldEntry)``, which empties the entry.  The module is therefore
absent from ``cache[]`` afterwards, so the ``update_dependen`` scan cannot
find it, no dependent gets rewired -- and the old symbol tree is disposed
anyway.  Importers that resolved ``leaf`` through a forwarder keep pointers
into that freed tree, so lookups come back empty.  Direct imports survive
because they re-resolve the module through the cache instead of following a
cached pointer chain.

``cacheModule`` used to drop the freshly cached entry (see the module-cache
notes in tests/README.md), which made these tests fail; they now guard the
fixed behaviour.
"""

from harness import DlsTestCase, labels


LEAF = """module leaf;

struct Widget
{
    int size;
}
"""

M2 = """module m2;

public import leaf;
"""

M1 = """module m1;

public import m2;
"""


def app(module: str, imported: str) -> str:
    return f"""module {module};

import {imported};

void main()
{{
    Widget w;
    w.si
}}
"""


class ForwardedSymbolOriginFirstTests(DlsTestCase):
    """Control: caching the origin before the forwarders works today."""

    PROJECT = {
        "leaf.d": LEAF,
        "m2.d": M2,
        "m1.d": M1,
        "app.d": app("app", "m1"),
    }
    OPEN_ORDER = ("leaf.d", "m2.d", "m1.d", "app.d")

    def test_forwarded_symbol_completes(self):
        for name in self.OPEN_ORDER:
            self.open_doc(name)

        items = labels(self.doc("app.d").completion("w.si")["items"])
        self.assertIn("size", items)


class ForwardedSymbolOriginLastTests(DlsTestCase):
    """The bug: the same project opened origin-last loses those completions."""

    PROJECT = {
        "leaf.d": LEAF,
        "m2.d": M2,
        "m1.d": M1,
        "app.d": app("app", "m1"),
    }

    def test_forwarded_symbol_survives_opening_the_origin_last(self):
        for name in ("app.d", "m1.d", "m2.d", "leaf.d"):
            self.open_doc(name)

        items = labels(self.doc("app.d").completion("w.si")["items"])
        self.assertIn("size", items)

    def test_forwarded_symbol_survives_opening_only_the_inner_forwarder_first(self):
        # The outer forwarder does not even have to be opened: caching m2
        # before leaf is enough to break the chain.
        for name in ("app.d", "m2.d", "leaf.d"):
            self.open_doc(name)

        items = labels(self.doc("app.d").completion("w.si")["items"])
        self.assertIn("size", items)


class DirectImportOriginLastTests(DlsTestCase):
    """Contrast: a direct import is not affected by the same ordering."""

    PROJECT = {
        "leaf.d": LEAF,
        "app.d": app("app", "leaf"),
    }

    def test_direct_import_survives_opening_the_origin_last(self):
        for name in ("app.d", "leaf.d"):
            self.open_doc(name)

        items = labels(self.doc("app.d").completion("w.si")["items"])
        self.assertIn("size", items)
