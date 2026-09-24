"""A suffix (`*`, `[]`, `[K]`) written *inside* a type constructor's parens
(`const(T*)`, `immutable(T[])`) used to be dropped entirely, not just the
qualifier.

`resolveDeclaredType` (`dsymbol/conversion/second.d`) only ever resolves a
*base name*: suffix-wrapping is the caller's job, applied once to the
outermost `Type` node's own `typeSuffixes`. A type constructor's operand
(`t2.type` in `const(X)`) is itself a full `Type` node with its own
`typeSuffixes` list -- and nothing ever read it, so `const(T**)` resolved as
bare `T`, not `T**`: not just missing `const`, but silently downgrading a
double pointer to a plain value. Fixed by applying the operand's own
suffixes where it's resolved, the same way the outer type's are applied.

`const`/`immutable`/`shared`/`inout` themselves used to be invisible in the
resolved type graph too -- a separate, deliberately deferred limitation at
the time this file was first written. That gap is now closed as well:
`resolveTypeFromTypeNode` (`second.d`) reads `Type.typeConstructors` (the
bare `const T` form) and `Type2.typeConstructor` (the parenthesized
`const(T)` form) and stamps `DSymbol.Flags.declaredTypeIs*` on the
declaration-site symbol, which hover/completion render as a `const(...)`
wrap around the formatted type. These tests now pin both the suffix shape
and the qualifier keyword.

An `auto x = f()` local's type is deduced through a separate pipeline
(`resolveInitializerNode`'s function-call handling, not
`resolveTypeFromTypeNode`), which at first did not consult or propagate the
callee's `declaredTypeIs*` flags -- `auto x = getDataPtr()` from
`const(Data*) getDataPtr();` hovered as `Data* x`, not `const(Data*) x`, even
though hovering `getDataPtr` itself already showed the qualifier correctly.
Closed too: the call-expression branch inside `resolveInitializerNode`
captures the callee's flags before its own internal `typeSwap` collapses the
function symbol to its return type (where the association would otherwise be
lost), threaded back out through a new `out TypeConstructorFlags qualifiers`
parameter and applied by `resolveTypeFromInitializer` alongside the existing
`symbol.type = currentSymbol` assignment. A second, narrower shape needed its
own fallback: `auto x = getDoublePtr!(Data);` with no trailing `()` never
enters the call branch at all (it is a bare reference to an instantiated
template, resolved by `evalIoti`) -- for that shape
`resolveTypeFromInitializer` reads `currentSymbol`'s own `declaredTypeIs*`
directly, before its *own* `typeSwap` call collapses it, whenever the call
branch didn't already supply a qualifier. `GenericReturnTypeSuffixTests` and
`NonGenericFunctionReturnPointerTests` below hit both of these paths and now
pin the qualifier being shown.

Two more shapes closed the same pass: a bare-const/immutable *parameter*
copied into an `auto` local (`void f(const int a) { auto c = a; }`) -- D's
qualifiers are transitive, so `a`'s own type already is `const(int)`, not
`int` with a separate attribute; `parameterIsConst`/`Immutable` (a different
flag family, the bare-attribute AST shape) are read as a second fallback in
`resolveTypeFromInitializer`, tried only once `declaredTypeIs*` found nothing
(`ParameterTransitivityTests`). And a real bug the IFTI-plus-qualifier case
caught during development: an argument that is itself a call
(`get(Data())`) recurses back into the same call-expression branch while
being evaluated for deduction, silently clobbering the outer call's captured
qualifier with the argument's (almost always none) -- fixed by snapshotting
the callee's flags into a branch-local variable, applied to the shared result
only as that branch's last step (`IFTICallQualifierTests`).

Both fallbacks exclude `CompletionKind.aliasName`: an alias's own name is
already a complete type name that may itself encode a qualifier (`string` is
`alias string = immutable(char)[];`), so re-wrapping a reference to it would
double up (`immutable(string)`, not `string`) -- `AutoAliasEdgeCaseTests`
pins that.

A related gap, closed in the same pass: a variable declared through a
qualified alias (`alias P = const(Data*); P orig;`) did not itself pick up
the qualifier -- `orig`'s own declaration syntax is just the identifier `P`,
with no `const(...)` token at that site for `collectTypeConstructors` to
read. Fixed in `resolveTypeFromTypeNode` by reading `P`'s own
`declaredTypeIs*` directly off `base` (the resolved, not-yet-dereferenced
alias symbol) when nothing was found in the written syntax -- but *only* for
a *same-file* alias, gated on the exact `symbolFile` comparison `dll.d`'s
hover already uses to decide whether to dereference an alias for display at
all. That gate is the whole point: a same-file alias like `P` gets
dereferenced to its target (`Data*`) for display, so wrapping it in `P`'s own
qualifier is correct and non-redundant; a cross-file alias like the builtin
`string` never gets dereferenced (hover shows the bare name `string`), so
qualifying it too would reintroduce the exact double-wrap bug
`AutoAliasEdgeCaseTests` guards against -- confirmed by temporarily dropping
the gate and watching `test_string_parameter_copy_is_not_double_wrapped` and
`test_string_literal_is_not_double_wrapped` fail with `immutable(string)`.
`orig`'s fix also closes `auto copy = orig;` transitively, for free, through
the existing non-alias fallback in `resolveTypeFromInitializer` (`copy` is a
plain `variableName`, not itself an alias).
"""

from harness import DlsTestCase, find_item


PLAIN_VARIABLES = """module app;

void test()
{
    const(int*) ptr;
    immutable(int[]) arr;
    const(int**) doublePtr;

    int useThem = 1;
}
"""

POINTER_EDGE_CASES = """module app;

struct Data
{
    int value;
}

void test()
{
    const(int***) triple;
    const(int*[]) arrOfPtr;
    const(int[3]*) ptrToStaticArr;
    const(int[][]) doubleArr;
    shared(int*) sharedPtr;

    const(Data*) dataPtr;
    dataPtr.va

    int useThem = 1;
}
"""

NON_GENERIC_RETURN_TYPES = """module app;

struct Data
{
    int value;
}

const(Data*) getDataPtr();
Data** getDoubleDataPtr();

void test()
{
    auto p = getDataPtr();
    p.va

    auto pp = getDoubleDataPtr();
}
"""

FIELD_TYPES = """module app;

struct Data
{
    int value;
}

struct Holder
{
    const(Data*) dataPtr;
    const(int**) intDoublePtr;
}

void test()
{
    Holder h;
    h.dataPtr.va
}
"""

GENERIC_RETURN_TYPES = """module app;

struct Data
{
    int value;
}

const(T**) getDoublePtr(T)();
const(T[]) getArray(T)();
immutable(T*) getPtr(T)();

void test()
{
    auto viaDoublePtr = getDoublePtr!(Data);
    auto viaArray = getArray!(Data);
    auto viaPtr = getPtr!(Data);
}
"""

IFTI_CALL_RETURN_TYPES = """module app;

struct Data
{
    int value;
}

const(T**) getViaCall(T)(T seed)
{
    return null;
}

void test()
{
    auto viaCall = getViaCall(Data());
    viaCall
}
"""

PARAMETER_TRANSITIVITY = """module app;

void test(const int a, immutable int b)
{
    auto c = a;
    auto d = b;
    int useThem = c + d;
}
"""

AUTO_ALIAS_EDGE_CASES = """module app;

struct Data
{
    int value;
}

alias ConstDataPtr = const(Data*);

void useString(string s)
{
    auto local = s;
    int useLocal = cast(int) local.length;
}

void test()
{
    auto literal = "hello";

    ConstDataPtr orig;
    auto copy = orig;
    copy.va
}
"""

BARE_QUALIFIERS = """module app;

void test()
{
    const int bareConst;
    immutable int bareImmutable;

    int useThem = 1;
}
"""

QUALIFIER_KEYWORD_COVERAGE = """module app;

struct Data
{
    int value;
}

alias ConstDataPtr = const(Data*);

inout(int*) identity(inout(int*) p)
{
    return p;
}

void useParam(const(Data*) constParam, const int bareConstParam)
{
    constParam.va
}

void test()
{
    ConstDataPtr aliased;
}
"""


class DeclaredVariableSuffixTests(DlsTestCase):
    """The bug reproduces without templates at all -- a plain local
    variable's declared type already loses inner suffixes.
    """

    PROJECT = {"app.d": PLAIN_VARIABLES}

    def _hover(self, doc, needle):
        result = doc.hover(needle, offset=-1)
        return "\n".join(entry["value"] for entry in result["contents"])

    def test_pointer_inside_const(self):
        doc = self.open_doc("app.d")
        self.assertIn("const(int*) ptr", self._hover(doc, "const(int*) ptr"))

    def test_array_inside_immutable(self):
        doc = self.open_doc("app.d")
        self.assertIn("immutable(int[]) arr", self._hover(doc, "immutable(int[]) arr"))

    def test_double_pointer_inside_const(self):
        doc = self.open_doc("app.d")
        self.assertIn("const(int**) doublePtr", self._hover(doc, "const(int**) doublePtr"))


class GenericReturnTypeSuffixTests(DlsTestCase):
    """The same suffix gap through a generic function's return type, deduced
    via an explicit `get!(Data)` instantiation -- the shape that surfaced the
    bug originally.

    `getDoublePtr!(Data)`/etc. here have no trailing `()` -- a bare reference
    to an instantiated template, not a call -- so this exercises
    `resolveTypeFromInitializer`'s fallback read of `currentSymbol`'s own
    `declaredTypeIs*` flags before its own `typeSwap`, not the call-expression
    capture inside `resolveInitializerNode` (see the module docstring; that
    path is `NonGenericFunctionReturnPointerTests` below).
    """

    PROJECT = {"app.d": GENERIC_RETURN_TYPES}

    def _hover(self, doc, needle):
        result = doc.hover(needle, offset=-len(needle) + 5)
        return "\n".join(entry["value"] for entry in result["contents"])

    def test_double_pointer_return_type(self):
        doc = self.open_doc("app.d")
        self.assertIn("const(Data**) viaDoublePtr", self._hover(doc, "auto viaDoublePtr"))

    def test_array_return_type(self):
        doc = self.open_doc("app.d")
        self.assertIn("const(Data[]) viaArray", self._hover(doc, "auto viaArray"))

    def test_pointer_return_type(self):
        doc = self.open_doc("app.d")
        self.assertIn("immutable(Data*) viaPtr", self._hover(doc, "auto viaPtr"))


class PointerEdgeCaseTests(DlsTestCase):
    """Pointer-specific shapes beyond a bare `T*`/`T**`: more indirection,
    a pointer combined with array suffixes on either side, another
    qualifier keyword (`shared`), and -- the functional check, not just a
    display string -- member completion through a `const(Data*)` local,
    which needs `getParts`/`memberStep` to walk through the
    `POINTER_SYMBOL_NAME` wrapper the fix now actually builds.
    """

    PROJECT = {"app.d": POINTER_EDGE_CASES}

    def _hover(self, doc, needle):
        result = doc.hover(needle, offset=-1)
        return "\n".join(entry["value"] for entry in result["contents"])

    def test_triple_pointer(self):
        doc = self.open_doc("app.d")
        self.assertIn("const(int***) triple", self._hover(doc, "const(int***) triple"))

    def test_array_of_pointers(self):
        doc = self.open_doc("app.d")
        self.assertIn("const(int*[]) arrOfPtr", self._hover(doc, "const(int*[]) arrOfPtr"))

    def test_pointer_to_static_array(self):
        doc = self.open_doc("app.d")
        self.assertIn("const(int[3]*) ptrToStaticArr",
            self._hover(doc, "const(int[3]*) ptrToStaticArr"))

    def test_array_of_arrays(self):
        doc = self.open_doc("app.d")
        self.assertIn("const(int[][]) doubleArr", self._hover(doc, "const(int[][]) doubleArr"))

    def test_shared_pointer(self):
        doc = self.open_doc("app.d")
        self.assertIn("shared(int*) sharedPtr", self._hover(doc, "shared(int*) sharedPtr"))

    def test_member_completion_through_a_const_pointer(self):
        doc = self.open_doc("app.d")
        items = doc.completion("dataPtr.va")["items"]
        self.assertEqual(find_item(items, "value")["labelDetails"]["description"], "int")


class NonGenericFunctionReturnPointerTests(DlsTestCase):
    """The same fix, reached without any template involved at all: a plain
    function's own declared return type goes through the identical
    `resolveDeclaredType` path.

    `p = getDataPtr()` has a real `()` call, so this is the call-expression
    capture path (as opposed to `GenericReturnTypeSuffixTests`'s bare
    template-instance-reference fallback): `getDataPtr`'s own
    `declaredTypeIsConst` flag, captured inside `resolveInitializerNode`'s
    call branch before its internal `typeSwap` collapses the function symbol
    to its return type, then applied to `p` by `resolveTypeFromInitializer`.
    """

    PROJECT = {"app.d": NON_GENERIC_RETURN_TYPES}

    def test_hover_shows_the_pointer(self):
        doc = self.open_doc("app.d")
        result = doc.hover("auto p", offset=-len("auto p") + 5)
        text = "\n".join(entry["value"] for entry in result["contents"])
        self.assertIn("const(Data*) p", text)

    def test_member_completion_through_the_returned_pointer(self):
        doc = self.open_doc("app.d")
        items = doc.completion("p.va")["items"]
        self.assertEqual(find_item(items, "value")["labelDetails"]["description"], "int")

    def test_double_pointer_return_type_without_a_qualifier(self):
        doc = self.open_doc("app.d")
        result = doc.hover("auto pp", offset=-len("auto pp") + 5)
        text = "\n".join(entry["value"] for entry in result["contents"])
        self.assertIn("Data** pp", text)


class IFTICallQualifierTests(DlsTestCase):
    """The exact shape that originally motivated this fix:
    `auto f = get(Data());` calling `T get(T)(T data)`, but with the return
    type also qualified. This combines both propagation paths at once --
    positional IFTI deduction (`deduceTemplateArguments`/`instantiateSymbol`,
    unrelated to qualifier tracking) *and* the call-expression qualifier
    capture inside `resolveInitializerNode` -- so it's the one place a
    regression in how those two interact would show up.

    A real bug this shape caught during development: `Data()` (the argument)
    is itself parsed as a function-call expression, so evaluating it for
    deduction recurses back into the same call-expression branch and clobbers
    the closure-captured qualifier -- `getViaCall`'s `const` got overwritten
    by `Data`'s (a plain struct name, never qualified) on the way back out of
    the recursion, silently losing the qualifier. Fixed by snapshotting the
    callee's flags into a branch-local variable and writing it to the shared
    result only as that branch's very last step, after argument evaluation
    has already had its chance to (wrongly) touch the shared variable.
    """

    PROJECT = {"app.d": IFTI_CALL_RETURN_TYPES}

    def test_hover_shows_the_qualifier(self):
        doc = self.open_doc("app.d")
        result = doc.hover("auto viaCall", offset=-len("auto viaCall") + 5)
        text = "\n".join(entry["value"] for entry in result["contents"])
        self.assertIn("const(Data**) viaCall", text)


class ParameterTransitivityTests(DlsTestCase):
    """D's `const`/`immutable` are transitive: a bare-const/immutable
    *parameter*'s own type already includes the qualifier (`const int a`
    means `a`'s type is `const(int)`, not `int` with a separate attribute),
    so copying it into an `auto` local should carry the qualifier along --
    the same way it would for any other already-qualified value, not
    something specific to parameters.

    This reads `parameterIsConst`/`Immutable` (the bare-attribute flag
    family from `first.d`'s parameter-attribute switch), a second, later
    fallback in `resolveTypeFromInitializer` -- distinct from
    `declaredTypeIsConst` (the type-constructor flag family this whole file
    is otherwise about), tried first and applicable when a parameter is
    instead written with parens (`const(int) a`).
    """

    PROJECT = {"app.d": PARAMETER_TRANSITIVITY}

    def _hover(self, doc, needle):
        result = doc.hover(needle, offset=-len(needle) + 5)
        return "\n".join(entry["value"] for entry in result["contents"])

    def test_const_parameter_copy(self):
        doc = self.open_doc("app.d")
        self.assertIn("const(int) c", self._hover(doc, "auto c"))

    def test_immutable_parameter_copy(self):
        doc = self.open_doc("app.d")
        self.assertIn("immutable(int) d", self._hover(doc, "auto d"))


class AutoAliasEdgeCaseTests(DlsTestCase):
    """The fallbacks above read a symbol's own flags before it gets
    collapsed to its type -- risky specifically for an *alias*, whose name
    is already a complete, self-contained type name that may itself encode a
    qualifier (`string` is `alias string = immutable(char)[];`). Wrapping an
    alias reference in another qualifier layer double-counts it: `string s`
    would wrongly become `immutable(string) s`. `resolveTypeFromInitializer`
    excludes `CompletionKind.aliasName` from both fallbacks for exactly this
    reason; these tests are the regression guard for that exclusion, found
    while implementing this fix -- `useString`'s `s` parameter and
    `test`'s `"hello"` string literal both resolve, at some point in the
    chain, straight to the builtin `string` alias symbol itself.

    `copy`, copied from `orig` (`ConstDataPtr orig;`), now picks up the
    qualifier too, for free: `orig` is a plain `variableName`, not an alias,
    so the non-alias fallback in `resolveTypeFromInitializer` applies
    normally once `orig.flags.declaredTypeIsConst` is itself true -- true
    since `resolveTypeFromTypeNode`'s same-file-alias read now sets it (see
    `QualifierKeywordCoverageTests.test_a_variable_declared_through_a_same_file_qualified_alias_shows_it`).
    """

    PROJECT = {"app.d": AUTO_ALIAS_EDGE_CASES}

    def test_string_parameter_copy_is_not_double_wrapped(self):
        doc = self.open_doc("app.d")
        result = doc.hover("auto local", offset=-len("auto local") + 5)
        text = "\n".join(entry["value"] for entry in result["contents"])
        self.assertIn("string local", text)
        self.assertNotIn("immutable(string)", text)

    def test_string_literal_is_not_double_wrapped(self):
        doc = self.open_doc("app.d")
        result = doc.hover("auto literal", offset=-len("auto literal") + 5)
        text = "\n".join(entry["value"] for entry in result["contents"])
        self.assertIn("string literal", text)
        self.assertNotIn("immutable(string)", text)

    def test_copy_of_an_aliased_qualified_variable_keeps_the_qualifier(self):
        doc = self.open_doc("app.d")
        result = doc.hover("auto copy", offset=-len("auto copy") + 5)
        text = "\n".join(entry["value"] for entry in result["contents"])
        self.assertIn("const(Data*) copy", text)

    def test_member_completion_through_the_copy(self):
        doc = self.open_doc("app.d")
        items = doc.completion("copy.va")["items"]
        self.assertEqual(find_item(items, "value")["labelDetails"]["description"], "int")


class FieldTypeSuffixTests(DlsTestCase):
    """The declared type of a struct *field* goes through the same
    resolution as a local variable's -- pinned separately since fields are
    collected through a different first-pass visitor path
    (`structFieldTypes`) before ending up at the same `resolveDeclaredType`.
    """

    PROJECT = {"app.d": FIELD_TYPES}

    def test_hover_on_a_pointer_field(self):
        doc = self.open_doc("app.d")
        result = doc.hover("const(Data*) dataPtr", offset=-1)
        text = "\n".join(entry["value"] for entry in result["contents"])
        self.assertIn("const(Data*) dataPtr", text)

    def test_hover_on_a_double_pointer_field(self):
        doc = self.open_doc("app.d")
        result = doc.hover("const(int**) intDoublePtr", offset=-1)
        text = "\n".join(entry["value"] for entry in result["contents"])
        self.assertIn("const(int**) intDoublePtr", text)

    def test_member_completion_through_a_field_pointer(self):
        doc = self.open_doc("app.d")
        items = doc.completion("h.dataPtr.va")["items"]
        self.assertEqual(find_item(items, "value")["labelDetails"]["description"], "int")


class BareQualifierTests(DlsTestCase):
    """A qualifier written bare, with no parens (`const int x`), as opposed
    to the parenthesized `const(int) x` form every other fixture in this file
    uses.

    Investigated and found to be a *different* gap than the one this file's
    fix closes: dparse's grammar disambiguates a leading `const`/`immutable`/
    `shared`/`inout` on a declaration through `parseStorageClass`
    (`dparse/parser.d`'s `isStorageClass`/`parseDeclaration`), not through
    `parseType`'s `Type.typeConstructors` -- so `collectTypeConstructors`
    (`second.d`) never sees it; it stays on the `Declaration` node as a
    storage class, the same family of AST shape `parameterIsConst` already
    reads for a *parameter*'s bare `const`, just never wired up for a local/
    field/return-type declaration. Tracking it would mean reading storage
    classes at the point each of those is built in the first pass
    (`dsymbol/conversion/first.d`), a separate mechanism from this fix's
    `resolveTypeFromTypeNode` change -- out of scope here; pinned as the
    still-current (missing) behavior instead of silently going untested.
    """

    PROJECT = {"app.d": BARE_QUALIFIERS}

    def _hover(self, doc, needle):
        result = doc.hover(needle, offset=-1)
        return "\n".join(entry["value"] for entry in result["contents"])

    def test_bare_const_qualifier_is_not_tracked_yet(self):
        doc = self.open_doc("app.d")
        text = self._hover(doc, "const int bareConst")
        self.assertIn("int bareConst", text)
        self.assertNotIn("const(int)", text)

    def test_bare_immutable_qualifier_is_not_tracked_yet(self):
        doc = self.open_doc("app.d")
        text = self._hover(doc, "immutable int bareImmutable")
        self.assertIn("int bareImmutable", text)
        self.assertNotIn("immutable(int)", text)


class QualifierKeywordCoverageTests(DlsTestCase):
    """Shapes not covered by any fixture above: `inout`, an alias to a
    qualified type, and a parameter typed with a type-constructor qualifier
    (`const(T*) x`) as opposed to a bare storage-class attribute
    (`const T x`) -- confirming `declaredTypeIsConst` and `parameterIsConst`
    are independent flags that don't double up or clobber each other.
    """

    PROJECT = {"app.d": QUALIFIER_KEYWORD_COVERAGE}

    def _hover(self, doc, needle, offset=-1):
        result = doc.hover(needle, offset=offset)
        return "\n".join(entry["value"] for entry in result["contents"])

    def test_inout_return_type(self):
        doc = self.open_doc("app.d")
        needle = "inout(int*) identity(inout(int*) p)"
        text = self._hover(doc, needle, offset=-len(needle) + len("inout(int*) ") + 1)
        self.assertIn("inout(int*) identity", text)

    def test_inout_parameter(self):
        doc = self.open_doc("app.d")
        needle = "inout(int*) p)"
        text = self._hover(doc, needle, offset=-len(needle) + len("inout(int*) "))
        self.assertIn("inout(int*) p", text)

    def test_hovering_the_alias_name_itself_shows_the_qualifier(self):
        """Hovering the *type reference* `ConstDataPtr` (not the variable it
        declares) shows the alias's own definition, which does carry the
        qualifier -- this is `dll.d`'s separate alias-hover block, wired to
        `declaredTypeQualifierWrap` directly off `ConstDataPtr`'s own
        `declaredTypeIsConst` (set when *its* declaration, `alias
        ConstDataPtr = const(Data*);`, was resolved).
        """
        doc = self.open_doc("app.d")
        needle = "ConstDataPtr aliased;"
        text = self._hover(doc, needle, offset=-len(needle) + 1)
        self.assertIn("alias ConstDataPtr => const(Data*)", text)

    def test_a_variable_declared_through_a_same_file_qualified_alias_shows_it(self):
        """The variable itself (`aliased`, not the alias reference above):
        `collectTypeConstructors` (`second.d`) only reads the literal `Type`
        syntax written at `aliased`'s own declaration -- just the identifier
        `ConstDataPtr`, no `const(...)` token there -- so on its own it would
        never see that the target is qualified. `resolveTypeFromTypeNode`
        closes this for a *same-file* alias specifically: `base` (the
        resolved `ConstDataPtr` symbol, before any dereferencing) is read
        directly for its own `declaredTypeIsConst`, gated on
        `base.symbolFile == symbol.symbolFile` -- the same condition
        `dll.d`'s hover already uses to decide whether to dereference an
        alias to its target for display at all, so the qualifier is only
        added when the target (not just the alias's bare name) is what ends
        up shown. See `AutoAliasEdgeCaseTests` for the cross-file case
        (`string`), which must NOT pick this up.
        """
        doc = self.open_doc("app.d")
        needle = "ConstDataPtr aliased;"
        text = self._hover(doc, needle, offset=-len(needle) + len("ConstDataPtr "))
        self.assertIn("const(Data*) aliased", text)

    def test_parameter_with_a_type_constructor_qualifier(self):
        doc = self.open_doc("app.d")
        needle = "const(Data*) constParam"
        text = self._hover(doc, needle, offset=-len(needle) + len("const(Data*) ") + 1)
        self.assertIn("const(Data*) constParam", text)

    def test_bare_attribute_parameter_is_not_double_wrapped(self):
        doc = self.open_doc("app.d")
        needle = "const int bareConstParam"
        text = self._hover(doc, needle, offset=-len(needle) + len("const int ") + 1)
        self.assertIn("const int bareConstParam", text)
        self.assertNotIn("const(const", text)

    def test_member_completion_through_a_qualified_parameter(self):
        doc = self.open_doc("app.d")
        items = doc.completion("constParam.va")["items"]
        self.assertEqual(find_item(items, "value")["labelDetails"]["description"], "int")
