"""``public import`` re-exports symbols to importers of the importing module."""

from harness import DlsTestCase, labels


LIB = """module lib;

struct Widget
{
    int size;
}
"""

PUBLIC_PKG = """module pkg_public;

public import lib;
"""

PRIVATE_PKG = """module pkg_private;

import lib;
"""

APP_PUBLIC = """module app_public;

import pkg_public;

void main()
{
    Widget w;
    w.si
}
"""

APP_PRIVATE = """module app_private;

import pkg_private;

void main()
{
    Widget w;
    w.si
}
"""


class PublicImportTests(DlsTestCase):
    PROJECT = {
        "lib.d": LIB,
        "pkg_public.d": PUBLIC_PKG,
        "pkg_private.d": PRIVATE_PKG,
        "app_public.d": APP_PUBLIC,
        "app_private.d": APP_PRIVATE,
    }

    def test_public_import_reexports_symbols(self):
        doc = self.open_doc("app_public.d")
        self.assertIn("size", labels(doc.completion("w.si")["items"]))

    def test_public_import_hover_points_at_the_original_module(self):
        doc = self.open_doc("app_public.d")
        # Cursor on "w" in "w.si".
        result = doc.hover("w.si", offset=-len("w.si") + 1)
        text = "\n".join(entry["value"] for entry in result["contents"])
        self.assertIn("module lib", text)
        self.assertIn("size", text)

    def test_private_import_is_not_reexported(self):
        doc = self.open_doc("app_private.d")
        # "pkg_private" does a plain "import lib;", so Widget is not visible
        # through it and the member lookup has nothing to resolve.
        self.assertEqual(labels(doc.completion("w.si")["items"]), [])
