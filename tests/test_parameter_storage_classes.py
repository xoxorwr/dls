"""A parameter's storage classes (`ref`, `out`, `lazy`, `scope`, `return`,
`auto ref`, and a bare `const`/`immutable`/`shared`/`inout`) used to be
tracked on `DSymbol` (`parameterIsRef` etc., set in
`dsymbol/conversion/first.d`'s `processParameters`) but never read back out
anywhere: hovering or completing a `ref int param1` parameter showed plain
`int`, indistinguishable from a by-value parameter of the same type.

`parameterStorageClassPrefix` (`dcd/server/autocomplete/util.d`) renders the
flags already on the symbol into a prefix, applied both to a completion
item's `labelDetails.description` (`makeSymbolCompletionInfo`, `util.d`) and
to hover text (`dll.d`'s `dcd_hover`).

`const`/`immutable`/`shared`/`inout` have two distinct spellings that behave
differently: written bare (`const int x`) they are a *parameter attribute*,
exactly like `ref` -- tracked and shown here. Written with parens
(`const(int) x`) they are a *type constructor*, resolved (and silently
discarded) the same way any declared type's qualifier is -- `DSymbol`'s
resolved-type graph was never built to track qualifiers at all, which is a
separate, structural limitation this fix does not touch (see
`docs/problem-calltips.md`); `test_type_constructor_form_is_not_shown` pins
that gap so it does not read as a regression later.
"""

from harness import DlsTestCase, find_item


PARAMETERS = """module param_storage_classes;

void test(ref int refParam, out int outParam, lazy int lazyParam,
    scope int* scopeParam, const ref int constRefParam,
    ref const int refConstParam, immutable ref int immutableRefParam,
    const(int) parenConstParam)
{
    int useRef = refParam;
}
"""


class ParameterStorageClassHoverTests(DlsTestCase):
    PROJECT = {"app.d": PARAMETERS}

    def _hover_after(self, doc, prefix_needle):
        # -1: land on the identifier's last character, not the whitespace or
        # punctuation right after it.
        result = doc.hover(prefix_needle, offset=-1)
        return "\n".join(entry["value"] for entry in result["contents"])

    def test_ref_parameter(self):
        doc = self.open_doc("app.d")
        self.assertIn("ref int refParam;", self._hover_after(doc, "ref int refParam"))

    def test_out_parameter(self):
        doc = self.open_doc("app.d")
        self.assertIn("out int outParam;", self._hover_after(doc, "out int outParam"))

    def test_lazy_parameter(self):
        doc = self.open_doc("app.d")
        self.assertIn("lazy int lazyParam;", self._hover_after(doc, "lazy int lazyParam"))

    def test_scope_pointer_parameter(self):
        doc = self.open_doc("app.d")
        self.assertIn("scope int* scopeParam;", self._hover_after(doc, "scope int* scopeParam"))

    def test_bare_const_ref_parameter_either_source_order(self):
        """`const ref` and `ref const` both normalize to the same rendering
        (constness before `ref`), since the flags are read back independent
        of the order they were declared in.
        """
        doc = self.open_doc("app.d")
        self.assertIn("const ref int constRefParam;",
            self._hover_after(doc, "const ref int constRefParam"))
        self.assertIn("const ref int refConstParam;",
            self._hover_after(doc, "ref const int refConstParam"))

    def test_bare_immutable_ref_parameter(self):
        doc = self.open_doc("app.d")
        self.assertIn("immutable ref int immutableRefParam;",
            self._hover_after(doc, "immutable ref int immutableRefParam"))

    def test_type_constructor_form_is_not_shown(self):
        """`const(int) x` -- the parens make this a type constructor, not a
        parameter attribute; known gap, not what this fix covers.
        """
        doc = self.open_doc("app.d")
        text = self._hover_after(doc, "const(int) parenConstParam")
        self.assertIn("int parenConstParam;", text)
        self.assertNotIn("const int parenConstParam", text)


class ParameterStorageClassCompletionTests(DlsTestCase):
    PROJECT = {"app.d": PARAMETERS}

    def test_ref_parameter_description(self):
        doc = self.open_doc("app.d")
        items = doc.completion("int useRef = refParam")["items"]
        self.assertEqual(find_item(items, "refParam")["labelDetails"]["description"], "ref int")
