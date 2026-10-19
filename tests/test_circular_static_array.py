"""Cyclic module dependencies with indexed array field access.

When two modules mutually import each other (e.g. types <-> context) and a
struct in one holds a static array of structs defined in the other:
    LayoutNode[MAX_LAYOUT_NODES] nodes;
accessing `ctx.nodes[idx].text_style` must complete and hover correctly.
"""

from harness import DlsTestCase, labels


TYPES = """module dawn.ui2.types;

import dawn.ui2.context;

struct TextStyle
{
    int color;
}

struct LayoutNode
{
    TextStyle text_style;
}
"""

CONTEXT = """module dawn.ui2.context;

import dawn.ui2.types;

struct UIContext
{
    enum MAX_LAYOUT_NODES = 4096;
    LayoutNode[MAX_LAYOUT_NODES] nodes;
}
"""

WIDGETS = """module dawn.ui2.widgets;

import dawn.ui2.types;
import dawn.ui2.context;

void ui_label(UIContext* ctx, int idx)
{
    ctx.nodes[idx].text_style;
}
"""


class CircularStaticArrayTests(DlsTestCase):
    PROJECT = {
        "dawn/ui2/types.d": TYPES,
        "dawn/ui2/context.d": CONTEXT,
        "dawn/ui2/widgets.d": WIDGETS,
    }

    def test_completion_on_indexed_static_array_field(self):
        doc = self.open_doc("dawn/ui2/widgets.d")
        comp = doc.completion("ctx.nodes[idx].")
        items = labels(comp.get("items", []))
        self.assertIn("text_style", items)

    def test_hover_on_member_of_indexed_static_array(self):
        doc = self.open_doc("dawn/ui2/widgets.d")
        hover = doc.hover("text_style", offset=-2)
        contents = hover.get("contents", [])
        self.assertTrue(contents, "hover on text_style returned nothing")
        text = "\n".join(entry.get("value", "") for entry in contents)
        self.assertIn("TextStyle", text)

    def test_hover_on_static_array_field_shows_array_type(self):
        doc = self.open_doc("dawn/ui2/widgets.d")
        hover = doc.hover("nodes", offset=-2)
        contents = hover.get("contents", [])
        self.assertTrue(contents, "hover on nodes returned nothing")
        text = "\n".join(entry.get("value", "") for entry in contents)
        self.assertNotIn("struct LayoutNode nodes;", text)
        self.assertTrue("[" in text and "]" in text, f"expected array type in hover, got {text!r}")
