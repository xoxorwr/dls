"""Multi-level, non-circular import chains resolve through public imports.

``top`` publicly imports ``middle``, which publicly imports ``leaf``.  An
application that only imports ``top`` must still see symbols from every level
of the chain, including a field of a middle-level struct whose type lives in
the leaf module.

Every fixture deliberately contains a single statement: an unterminated
statement confuses the parser for the statements that follow it, so each
completion site lives in its own file.
"""

from harness import DlsTestCase, labels


LEAF = """module leaf;

struct Leaf
{
    int leaf_value;
}
"""

MIDDLE = """module middle;

public import leaf;

struct Middle
{
    Leaf nested;
    int middle_value;
}
"""

TOP = """module top;

public import middle;

struct Top
{
    int top_value;
}
"""


def app(module: str, declaration: str, statement: str) -> str:
    return f"""module {module};

import top;

void main()
{{
    {declaration}
    {statement}
}}
"""


class AcyclicDependencyTests(DlsTestCase):
    PROJECT = {
        "leaf.d": LEAF,
        "middle.d": MIDDLE,
        "top.d": TOP,
        # Symbols declared in each level, reached only through "top".
        "app_top.d": app("app_top", "Top value;", "value.top_v"),
        "app_middle.d": app("app_middle", "Middle value;", "value.middle_v"),
        "app_leaf.d": app("app_leaf", "Leaf value;", "value.leaf_v"),
        # A field typed by a module two hops away (Middle.nested is a Leaf).
        "app_deep_type.d": app("app_deep_type", "Middle value;", "value.nested.leaf_v"),
    }

    def test_directly_imported_module_symbols_resolve(self):
        doc = self.open_doc("app_top.d")
        self.assertEqual(labels(doc.completion("value.top_v")["items"]), ["top_value"])

    def test_symbols_from_a_public_import_resolve(self):
        doc = self.open_doc("app_middle.d")
        self.assertEqual(labels(doc.completion("value.middle_v")["items"]), ["middle_value"])

    def test_symbols_from_the_end_of_the_chain_resolve(self):
        doc = self.open_doc("app_leaf.d")
        self.assertEqual(labels(doc.completion("value.leaf_v")["items"]), ["leaf_value"])

    def test_field_type_from_a_distant_module_resolves(self):
        doc = self.open_doc("app_deep_type.d")
        self.assertEqual(labels(doc.completion("value.nested.leaf_v")["items"]), ["leaf_value"])

    def test_distant_field_type_is_reported_in_hover(self):
        doc = self.open_doc("app_deep_type.d")
        # Cursor inside the "nested" field of the "value.nested.leaf_v" access.
        result = doc.hover("value.nested", offset=-2)
        text = "\n".join(entry["value"] for entry in result["contents"])
        self.assertIn("Leaf", text)
