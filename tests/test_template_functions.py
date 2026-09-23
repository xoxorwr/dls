"""Template *functions*: `T get(T)()`, and return types built from parameters.

The template-instantiation tests cover a template used as a *type*
(`TD!int`).  This module covers the other direction: a function that is itself
templated, where the call's explicit arguments decide the return type.

Working today:

* `T get(T)()` with `get!int()` -- the declared return type is the function's
  parameter, substituted from the call's argument.
* the same with a struct argument (`get!Widget()`);
* a method of an instantiated struct returning that struct's parameter
  (`Box!int b; b.get()`);
* a plain function returning a struct (`make()`);
* a return type *built from* the parameter (`TD!T make(T)()` with
  `make!int()`), and the same for a parameter-taking function
  (`TD!T wrap(T)(T value)` with `wrap!int(1)`): the call's explicit arguments
  bind the function's template parameters, and the instantiated return type
  has the members of the instance it names substituted.

Inferring the argument from a value (`wrap(1)`) works too: a call with no
explicit argument binds the callee's parameters from the types of the values
written at the call site, so it resolves to the same instance `wrap!int(1)`
does.  A value may be a constant expression (`wrap(2 + 3)`): the operators
fold at D's precedences and promotions, so `1 + 1.0` binds a `double` and
`1 == 2 + 3` a `bool`.
"""

from harness import DlsTestCase, find_item


RETURNS_T = """module tplfn_returns_t;

T get(T)()
{
    return T.init;
}

void testme()
{
    get!int().si
}
"""

RETURNS_T_STRUCT_ARGUMENT = """module tplfn_returns_struct;

struct Widget
{
    int size;
}

T get(T)()
{
    return T.init;
}

void testme()
{
    get!Widget().si
}
"""

METHOD_OF_INSTANCE = """module tplfn_method;

struct Box(T)
{
    T value;

    T get()
    {
        return value;
    }
}

void testme()
{
    Box!int b;
    b.get().si
}
"""

RETURNS_INSTANCE_OF_T = """module tplfn_returns_instance;

struct TD(T)
{
    T data;
}

TD!T make(T)()
{
    TD!T t;
    return t;
}

void testme()
{
    make!int().data
}
"""

TAKES_T_RETURNS_INSTANCE = """module tplfn_takes_t;

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

void testme()
{
    wrap!int(1).data
}
"""

INFERRED_ARGUMENT = """module tplfn_inferred;

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

void testme()
{
    wrap(1).data
}
"""

INFERRED_ARGUMENT_STRUCT = """module tplfn_inferred_struct;

struct TD(T)
{
    T data;
}

struct Widget
{
    int size;
}

TD!T wrap(T)(T value)
{
    TD!T t;
    t.data = value;
    return t;
}

void testme()
{
    Widget w;
    wrap(w).data
}
"""

INFERRED_ARGUMENT_STRING = """module tplfn_inferred_string;

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

void testme()
{
    wrap("hello").data
}
"""

INFERRED_ARGUMENT_EXPRESSIONS = """module tplfn_inferred_expressions;

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

void testme()
{
    wrap(2 + 3).data;
    wrap(1 + 1.0).data;
    wrap(1 == 2 + 3).data;
    wrap("a" ~ "b").data;
}
"""


class TemplateFunctionTests(DlsTestCase):
    """The shapes that resolve today."""

    PROJECT = {
        "tplfn_returns_t.d": RETURNS_T,
        "tplfn_returns_struct.d": RETURNS_T_STRUCT_ARGUMENT,
        "tplfn_method.d": METHOD_OF_INSTANCE,
    }

    def described_as(self, doc, site, member):
        items = doc.completion(site)["items"]
        return find_item(items, member)["labelDetails"]["description"]

    def test_return_type_is_the_functions_parameter(self):
        """`T get(T)()` + `get!int()` -- `T` is the call's argument."""
        doc = self.open_doc("tplfn_returns_t.d")
        self.assertEqual(self.described_as(doc, "get!int().si", "sizeof"), "keyword")

    def test_return_type_is_the_functions_parameter_with_a_struct(self):
        doc = self.open_doc("tplfn_returns_struct.d")
        self.assertEqual(self.described_as(doc, "get!Widget().si", "size"), "int")

    def test_method_of_an_instantiated_struct(self):
        """`Box!int b; b.get()` -- the method's `T` is the instance's argument."""
        doc = self.open_doc("tplfn_method.d")
        self.assertEqual(self.described_as(doc, "b.get().si", "sizeof"), "keyword")


class TemplateReturnInstanceTests(DlsTestCase):
    """A return type *built from* the function's parameter.

    `TD!T make(T)()` is the shape a generic factory has.  The call's explicit
    arguments (`make!int`) are matched to the function's template parameters
    and the function is instantiated with that mapping, so its declared return
    type `TD!T` becomes the instance `TD!int` -- including the members of the
    instance, which is what `make!int().data` completes against.

    `instantiateWithArguments` is that entry point; the token chain of the
    completion request (`make` `!` `int` `(`) carries the arguments.
    """

    PROJECT = {
        "tplfn_returns_instance.d": RETURNS_INSTANCE_OF_T,
        "tplfn_takes_t.d": TAKES_T_RETURNS_INSTANCE,
    }

    def test_return_type_is_an_instance_of_the_parameter(self):
        doc = self.open_doc("tplfn_returns_instance.d")
        items = doc.completion("make!int().data")["items"]
        self.assertEqual(find_item(items, "data")["labelDetails"]["description"], "int")

    def test_parameter_taking_function_returning_an_instance(self):
        doc = self.open_doc("tplfn_takes_t.d")
        items = doc.completion("wrap!int(1).data")["items"]
        self.assertEqual(find_item(items, "data")["labelDetails"]["description"], "int")


class TemplateArgumentInferenceTests(DlsTestCase):
    """The argument's type binds the parameter, with no `!` written.

    `wrap(1)` names no argument, so the call's own values are the only place
    the parameter's type appears.  `resolveCallArgumentTypes` reads them off
    the call's token chain (`wrap` `(` `1` `)`), binds them to the callee's
    parameters in the order they are written, and instantiates it exactly as
    `wrap!int(1)` does.  An argument written as a constant expression is
    folded first (`wrap(2 + 3)`), through `binaryResultTypeName` -- the same
    promotion rules the initializer walk applies to an expression's AST.
    """

    PROJECT = {
        "tplfn_inferred.d": INFERRED_ARGUMENT,
        "tplfn_inferred_struct.d": INFERRED_ARGUMENT_STRUCT,
        "tplfn_inferred_string.d": INFERRED_ARGUMENT_STRING,
        "tplfn_inferred_expressions.d": INFERRED_ARGUMENT_EXPRESSIONS,
    }

    def described_as(self, doc, site, member):
        items = doc.completion(site)["items"]
        return find_item(items, member)["labelDetails"]["description"]

    def test_argument_is_inferred_from_the_value(self):
        doc = self.open_doc("tplfn_inferred.d")
        self.assertEqual(self.described_as(doc, "wrap(1).data", "data"), "int")

    def test_argument_is_inferred_from_a_variables_type(self):
        """`wrap(w)` with `Widget w` -- the argument's *type* is the binding."""
        doc = self.open_doc("tplfn_inferred_struct.d")
        self.assertEqual(self.described_as(doc, "wrap(w).data", "data"), "Widget")

    def test_string_literal_argument(self):
        """`string` is an alias in `object.d`, not a builtin type symbol."""
        doc = self.open_doc("tplfn_inferred_string.d")
        self.assertEqual(self.described_as(doc, 'wrap("hello").data', "data"), "string")

    def test_constant_expression_argument(self):
        """`wrap(2 + 3)` -- the value's type, not just a lone literal's."""
        doc = self.open_doc("tplfn_inferred_expressions.d")
        self.assertEqual(self.described_as(doc, "wrap(2 + 3).data", "data"), "int")

    def test_operands_are_promoted(self):
        """`1 + 1.0` is a `double`, the common type of its operands."""
        doc = self.open_doc("tplfn_inferred_expressions.d")
        self.assertEqual(self.described_as(doc, "wrap(1 + 1.0).data", "data"), "double")

    def test_comparison_binds_looser_than_addition(self):
        """`1 == 2 + 3` is `1 == (2 + 3)`: a `bool`, not an `int`."""
        doc = self.open_doc("tplfn_inferred_expressions.d")
        self.assertEqual(self.described_as(doc, "wrap(1 == 2 + 3).data", "data"), "bool")

    def test_string_concatenation_argument(self):
        doc = self.open_doc("tplfn_inferred_expressions.d")
        self.assertEqual(self.described_as(doc, 'wrap("a" ~ "b").data', "data"), "string")
