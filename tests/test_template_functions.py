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

Not working yet, pinned as `expectedFailure`: inferring the argument from a
value (`wrap(1)`) -- the call carries no explicit argument to bind, so the
return type stays the generic `TD!T` and the field reports `T`.
"""

import unittest

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
    """Known gap: no inference from argument values.

    `wrap(1)` has no explicit template argument, so the call resolves to the
    generic `TD` and the field reports `T`.  DCD does not infer template
    arguments from the values at the call site; pinned so the behaviour is
    visible rather than surprising.
    """

    PROJECT = {"tplfn_inferred.d": INFERRED_ARGUMENT}

    @unittest.expectedFailure
    def test_argument_is_inferred_from_the_value(self):
        doc = self.open_doc("tplfn_inferred.d")
        items = doc.completion("wrap(1).data")["items"]
        self.assertEqual(find_item(items, "data")["labelDetails"]["description"], "int")
