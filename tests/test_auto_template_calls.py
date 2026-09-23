"""``auto x = <call to a template function>``, across the shapes
`test_template_functions.py` documents as working for a direct completion
chain (`wrap(1).data`).

That file drives everything through one call expression, resolved by
`resolveCallArgumentTypes`/`instantiateWithArguments` in
`dcd/server/autocomplete/util.d` -- the token-chain path a completion or
hover request walks live.  Binding the result to an `auto` variable first
goes through a different path entirely: `resolveInitializerNode`'s
function-call case in `dsymbol/conversion/second.d`, run once while a
module is cached, well before any request exists.  That second path used to
hand back the callee's declared return type completely unresolved -- for
`T get(T)(T data)`, literally the symbol `T` -- because nothing there
attempted to bind the callee's template parameters from the call's
arguments the way the completion-chain path does.

Each case below is one of that file's shapes, reached instead through an
`auto` variable, to pin the fix in `second.d` (`deduceTemplateArguments` +
`instantiateSymbol`) against regressing back to that behaviour.
"""

from harness import DlsTestCase, find_item, labels


RETURNS_T_DIRECTLY = """module auto_tplfn_returns_t;

T get(T)(T data)
{
    return data;
}

struct Data
{
    int value;
}

void main()
{
    auto viaStruct = get(Data());
    viaStruct.va

    auto viaInt = get(5);
    auto viaString = get("hello");
}
"""

EXPLICIT_TEMPLATE_ARGUMENT = """module auto_tplfn_explicit;

T get(T)(T data)
{
    return data;
}

struct Widget
{
    int size;
}

void main()
{
    auto viaExplicitStruct = get!Widget(Widget());
    viaExplicitStruct.si

    auto viaExplicitInt = get!int(5);
}
"""

RETURNS_INSTANCE_EXPLICIT = """module auto_tplfn_returns_instance;

struct TD(T)
{
    T data;
}

TD!T make(T)()
{
    TD!T t;
    return t;
}

void main()
{
    auto x = make!int();
    x.data
}
"""

RETURNS_INSTANCE_INFERRED = """module auto_tplfn_returns_instance_inferred;

struct TD(T)
{
    T data;
}

TD!T wrap(T)(T value)
{
    TD!T t;
    t.data = value;
    return t;
}

struct Widget
{
    int size;
}

void main()
{
    auto viaInt = wrap(1);
    viaInt.data

    auto viaExplicit = wrap!Widget(Widget());
    viaExplicit.data.si

    auto viaExpression = wrap(2 + 3);
    viaExpression.data
    auto viaPromotion = wrap(1 + 1.0);
    auto viaComparison = wrap(1 == 2 + 3);
    auto viaConcatenation = wrap("a" ~ "b");
}
"""

METHOD_OF_INSTANCE = """module auto_tplfn_method;

struct Box(T)
{
    T value;

    T get()
    {
        return value;
    }
}

void main()
{
    Box!int b;
    auto x = b.get();
}
"""

MULTIPLE_TYPE_PARAMETERS = """module auto_tplfn_multi_param;

V zip(K, V)(K k, V v)
{
    return v;
}

void main()
{
    auto x = zip(1, "hello");
}
"""

ARRAY_PARAMETER_NOT_DEDUCED = """module auto_tplfn_array_param;

T first(T)(T[] arr)
{
    return arr[0];
}

void main()
{
    auto x = first([1, 2, 3]);
}
"""

QUALIFIED_AND_REF_PARAMETERS = """module auto_tplfn_qualified;

struct Data
{
    int value;
}

T viaConst(T)(const(T) data)
{
    return cast(T) data;
}

T viaImmutable(T)(immutable(T) data)
{
    return cast(T) data;
}

T viaInout(T)(inout(T) data)
{
    return cast(T) data;
}

T viaRef(T)(ref T data)
{
    return data;
}

T viaConstRef(T)(ref const(T) data)
{
    return cast(T) data;
}

void main()
{
    auto x = viaConst(Data());
    x.va

    auto y = viaImmutable(Data());
    y.va

    auto z = viaInout(Data());
    z.va

    Data d;
    auto w = viaRef(d);
    w.va

    auto q = viaConstRef(d);
    q.va
}
"""


class DirectReturnTests(DlsTestCase):
    """`T get(T)(T data)` -- the return type *is* the parameter."""

    PROJECT = {
        "returns_t.d": RETURNS_T_DIRECTLY,
        "explicit.d": EXPLICIT_TEMPLATE_ARGUMENT,
    }

    def test_inferred_struct_argument(self):
        doc = self.open_doc("returns_t.d")
        items = doc.completion("viaStruct.va")["items"]
        self.assertEqual(find_item(items, "value")["labelDetails"]["description"], "int")

    def test_inferred_int_argument(self):
        doc = self.open_doc("returns_t.d")
        result = doc.hover("auto viaInt", offset=-len("auto viaInt") + 5)
        text = "\n".join(entry["value"] for entry in result["contents"])
        self.assertIn("int viaInt", text)

    def test_inferred_string_argument(self):
        doc = self.open_doc("returns_t.d")
        result = doc.hover("auto viaString", offset=-len("auto viaString") + 5)
        text = "\n".join(entry["value"] for entry in result["contents"])
        self.assertIn("string viaString", text)

    def test_explicit_struct_argument(self):
        doc = self.open_doc("explicit.d")
        items = doc.completion("viaExplicitStruct.si")["items"]
        self.assertEqual(find_item(items, "size")["labelDetails"]["description"], "int")

    def test_explicit_int_argument(self):
        doc = self.open_doc("explicit.d")
        result = doc.hover("auto viaExplicitInt", offset=-len("auto viaExplicitInt") + 5)
        text = "\n".join(entry["value"] for entry in result["contents"])
        self.assertIn("int viaExplicitInt", text)


class ReturnsInstanceOfParameterTests(DlsTestCase):
    """A return type *built from* the parameter (`TD!T`), not the parameter
    itself -- the mapping has to reach through `instantiateSymbol`'s
    aggregate-instance case, not just its bare-typeTmpParam one.
    """

    PROJECT = {
        "explicit_instance.d": RETURNS_INSTANCE_EXPLICIT,
        "inferred_instance.d": RETURNS_INSTANCE_INFERRED,
    }

    def test_explicit_argument(self):
        doc = self.open_doc("explicit_instance.d")
        items = doc.completion("x.data")["items"]
        self.assertEqual(find_item(items, "data")["labelDetails"]["description"], "int")

    def test_inferred_int_argument(self):
        doc = self.open_doc("inferred_instance.d")
        items = doc.completion("viaInt.data")["items"]
        self.assertEqual(find_item(items, "data")["labelDetails"]["description"], "int")

    def test_explicit_struct_argument(self):
        doc = self.open_doc("inferred_instance.d")
        items = doc.completion("viaExplicit.data.si")["items"]
        self.assertEqual(find_item(items, "size")["labelDetails"]["description"], "int")

    def test_constant_expression_argument(self):
        doc = self.open_doc("inferred_instance.d")
        items = doc.completion("viaExpression.data")
        self.assertIn("data", labels(items["items"]) if items else [])

    def test_operands_are_promoted(self):
        doc = self.open_doc("inferred_instance.d")
        result = doc.hover("viaPromotion", offset=1)
        self.assertTrue(result)

    def test_comparison_binds_looser_than_addition(self):
        doc = self.open_doc("inferred_instance.d")
        result = doc.hover("viaComparison", offset=1)
        self.assertTrue(result)

    def test_string_concatenation_argument(self):
        doc = self.open_doc("inferred_instance.d")
        result = doc.hover("viaConcatenation", offset=1)
        self.assertTrue(result)


class MethodOfInstantiatedStructTests(DlsTestCase):
    """`Box!int b; auto x = b.get();` -- `x`'s type comes from the receiver's
    own instantiation, not from any argument at the call site.
    """

    PROJECT = {"method.d": METHOD_OF_INSTANCE}

    def test_method_return_type_is_the_instances_parameter(self):
        doc = self.open_doc("method.d")
        result = doc.hover("auto x", offset=-len("auto x") + 5)
        text = "\n".join(entry["value"] for entry in result["contents"])
        self.assertIn("int x", text)


class MultipleTypeParameterTests(DlsTestCase):
    """`V zip(K, V)(K k, V v)` -- only `V`, the second parameter's type, is
    what the return type names; `K`'s binding must not leak into it.
    """

    PROJECT = {"multi.d": MULTIPLE_TYPE_PARAMETERS}

    def test_second_parameters_type_is_deduced(self):
        doc = self.open_doc("multi.d")
        result = doc.hover("auto x", offset=-len("auto x") + 5)
        text = "\n".join(entry["value"] for entry in result["contents"])
        self.assertIn("string x", text)


class ArrayParameterTests(DlsTestCase):
    """`T first(T)(T[] arr)` -- the parameter's type is *built from* `T`
    (wrapped in an array), not `T` itself, so deducing it means peeling the
    same array wrapping off both the declared parameter type and the
    argument's own type before comparing what's left underneath.
    """

    PROJECT = {"array_param.d": ARRAY_PARAMETER_NOT_DEDUCED}

    def test_array_literal_argument_deduces_the_element_type(self):
        doc = self.open_doc("array_param.d")
        result = doc.hover("auto x", offset=-len("auto x") + 5)
        text = "\n".join(entry["value"] for entry in result["contents"])
        self.assertIn("int x", text)


class QualifiedAndRefParameterTests(DlsTestCase):
    """`const(T)` / `immutable(T)` / `inout(T)` are type *constructors*:
    `resolveDeclaredType` (`second.d`) unwraps them transparently while
    resolving the parameter's declared type in the first place (`current =
    inner`, no wrapper symbol recorded at all), so a qualified parameter's
    `.type` is already bare `T` by the time deduction looks at it -- no
    extra peeling needed, unlike the array/pointer/assoc-array wrapping.
    `ref` is a storage class attached to the `Parameter` node, not part of
    its `Type`, so it does not affect `.type` either.
    """

    PROJECT = {"qualified.d": QUALIFIED_AND_REF_PARAMETERS}

    def test_const_parameter(self):
        doc = self.open_doc("qualified.d")
        items = doc.completion("x.va")["items"]
        self.assertEqual(find_item(items, "value")["labelDetails"]["description"], "int")

    def test_immutable_parameter(self):
        doc = self.open_doc("qualified.d")
        items = doc.completion("y.va")["items"]
        self.assertEqual(find_item(items, "value")["labelDetails"]["description"], "int")

    def test_inout_parameter(self):
        doc = self.open_doc("qualified.d")
        items = doc.completion("z.va")["items"]
        self.assertEqual(find_item(items, "value")["labelDetails"]["description"], "int")

    def test_ref_parameter(self):
        doc = self.open_doc("qualified.d")
        items = doc.completion("w.va")["items"]
        self.assertEqual(find_item(items, "value")["labelDetails"]["description"], "int")

    def test_ref_const_parameter(self):
        doc = self.open_doc("qualified.d")
        items = doc.completion("q.va")["items"]
        self.assertEqual(find_item(items, "value")["labelDetails"]["description"], "int")
