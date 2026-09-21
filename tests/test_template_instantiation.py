"""Members of an instantiated struct template must show the *argument's* type.

``struct TD(T) { T data; }`` plus ``TD!int test`` plus ``test.data`` used to
report the field as ``*unittest*`` (a placeholder symbol) or as ``T``, and
several shapes resolved to nothing at all.

Three separate defects, each found by tracing one shape:

1. ``first.d`` captured the template argument's name from
   ``TemplateSingleArgument.token.text``, but the text of a *static* token (a
   builtin such as ``int`` or ``string``) is unset -- so ``TD!int`` recorded an
   argument named ``""``, and ``resolveTypeInstance`` then resolved that name
   through the module scope, where the empty name matches hundreds of symbols.
2. The argument capture lived only in the variable-declaration visitor, so a
   *parameter* instantiated with an empty mapping and its members reported
   ``T``.
3. The capture also has to land on the lookup the resolver walks: a second
   lookup (added by the function-declaration path) was resolved last and
   overwrote the instance with the generic ``TD``, which is why a *return* type
   reported ``T``.

Captures are now built by one helper (``addTypeWithContext``), reused on an
existing lookup rather than added alongside it, and builtins resolve even
without a scope.
"""

import unittest

from harness import DlsTestCase, find_item


TEMPLATE = """module {module};

struct TD(T)
{{
    T data;
}}

{body}
"""

LOCAL = TEMPLATE.format(module="tpl_local", body="""void testme()
{
    TD!int test;
    test.data
}
""")

PARENTHESIZED = TEMPLATE.format(module="tpl_parens", body="""void testme()
{
    TD!(int) test;
    test.data
}
""")

STRING_ARGUMENT = TEMPLATE.format(module="tpl_string", body="""void testme()
{
    TD!string test;
    test.data
}
""")

AS_A_PARAMETER = TEMPLATE.format(module="tpl_param", body="""void testme(TD!int test)
{
    test.data
}
""")

AS_A_FIELD = """module tpl_field;

struct TD(T)
{
    T data;
}

struct Holder
{
    TD!int field;
}

void testme()
{
    Holder h;
    h.field.data
}
"""

THROUGH_AUTO = """module tpl_auto;

struct TD(T)
{
    T data;
}

void testme()
{
    TD!int test;
    auto d = test.data;
    d.
}
"""

STRUCT_ARGUMENT = """module tpl_struct;

struct Inner
{
    int size;
}

struct TD(T)
{
    T data;
}

void testme()
{
    TD!Inner test;
    test.data.si
}
"""

RETURN_TYPE = """module tpl_return;

struct TD(T)
{
    T data;
}

TD!int make()
{
    TD!int t;
    return t;
}

void testme()
{
    make().data
}
"""

RETURN_TYPE_THROUGH_AUTO = """module tpl_return_auto;

struct TD(T)
{
    T data;
}

TD!int make()
{
    TD!int t;
    return t;
}

void testme()
{
    auto x = make();
    x.data
}
"""


class TemplateFieldTypeTests(DlsTestCase):
    PROJECT = {
        "tpl_local.d": LOCAL,
        "tpl_parens.d": PARENTHESIZED,
        "tpl_string.d": STRING_ARGUMENT,
        "tpl_param.d": AS_A_PARAMETER,
        "tpl_field.d": AS_A_FIELD,
        "tpl_auto.d": THROUGH_AUTO,
        "tpl_struct.d": STRUCT_ARGUMENT,
        "tpl_return.d": RETURN_TYPE,
        "tpl_return_auto.d": RETURN_TYPE_THROUGH_AUTO,
    }

    def described_as(self, doc, site, member):
        items = doc.completion(site)["items"]
        return find_item(items, member)["labelDetails"]["description"]

    def test_local_variable(self):
        """`TD!int test; test.data` -- a builtin argument, captured as `int`."""
        doc = self.open_doc("tpl_local.d")
        self.assertEqual(self.described_as(doc, "test.data", "data"), "int")

    def test_parenthesized_argument(self):
        doc = self.open_doc("tpl_parens.d")
        self.assertEqual(self.described_as(doc, "test.data", "data"), "int")

    def test_string_argument(self):
        doc = self.open_doc("tpl_string.d")
        self.assertEqual(self.described_as(doc, "test.data", "data"), "string")

    def test_parameter_type(self):
        """`void testme(TD!int test)` -- a parameter's type is a declaration too."""
        doc = self.open_doc("tpl_param.d")
        self.assertEqual(self.described_as(doc, "test.data", "data"), "int")

    def test_field_of_another_struct(self):
        doc = self.open_doc("tpl_field.d")
        self.assertEqual(self.described_as(doc, "h.field.data", "data"), "int")

    def test_field_reached_through_auto(self):
        """`auto d = test.data; d.` -- the field's type has to resolve."""
        doc = self.open_doc("tpl_auto.d")
        self.assertEqual(self.described_as(doc, "d.", "sizeof"), "keyword")

    def test_member_of_the_instantiated_field(self):
        """`TD!Inner` -- a member of the substituted argument."""
        doc = self.open_doc("tpl_struct.d")
        self.assertEqual(self.described_as(doc, "test.data.si", "size"), "int")

    def test_return_type(self):
        """`TD!int make(); make().data` -- the call's result type."""
        doc = self.open_doc("tpl_return.d")
        self.assertEqual(self.described_as(doc, "make().data", "data"), "int")

    def test_return_type_through_auto(self):
        doc = self.open_doc("tpl_return_auto.d")
        self.assertEqual(self.described_as(doc, "x.data", "data"), "int")


NESTED_INSTANCE = """module tpl_nested;

struct Rectf
{
    float x;
    float y;
}

struct TD(T)
{
    T data;
}

struct CTX(T)
{
    TD!T data;
}

void testme()
{
    CTX!Rectf other;

    other.data.da
    other.data.data.
}
"""


class NestedTemplateInstanceTests(DlsTestCase):
    """An instance nested *inside* another instance.

    ``CTX!Rectf`` has a member ``data`` of type ``TD!T`` -- an instance whose
    argument is the outer template's parameter:

    * ``other.`` reports the member as ``TD!Rectf``;
    * ``other.data.da`` reports the inner member as ``Rectf``;
    * the chain can be followed further (``other.data.data.`` reaches
      ``Rectf``'s own members).

    ``first.d`` records ``TD!T`` as crumbs (``["TD"]``) plus a captured
    argument ``["T"]``.  An instance carries the arguments it was built with
    (``DSymbol.templateArgs`` / ``templateArgNames``), so the outer
    instantiation can substitute its own mapping (``T -> Rectf``) and rebuild
    the member as ``TD!Rectf`` instead of reusing the unsubstituted instance.
    """

    PROJECT = {"tpl_nested.d": NESTED_INSTANCE}

    def test_member_of_the_instance_is_instantiated(self):
        doc = self.open_doc("tpl_nested.d")
        items = doc.completion("other.")["items"]
        self.assertEqual(find_item(items, "data")["labelDetails"]["description"], "TD!Rectf")

    def test_member_of_the_nested_instance(self):
        doc = self.open_doc("tpl_nested.d")
        items = doc.completion("other.data.da")["items"]
        self.assertEqual(find_item(items, "data")["labelDetails"]["description"], "Rectf")

    def test_members_of_the_innermost_type(self):
        doc = self.open_doc("tpl_nested.d")
        items = doc.completion("other.data.data.")["items"]
        self.assertEqual(find_item(items, "x")["labelDetails"]["description"], "float")


SELF_REFERENTIAL = """module tpl_recursive;

struct Node(T)
{
    T value;
    Node!T next;
}

void testme()
{
    Node!int n;
    n.
}
"""


class RecursiveTemplateInstanceTests(DlsTestCase):
    """A template that mentions itself must not send instantiation into a loop.

    Instantiating ``Node!int`` walks the members of ``Node``; the member
    ``next`` is *itself* an instance of ``Node``, so rebuilding it (the nested
    case above) rebuilds a type that contains the instance being rebuilt.  The
    resolver marks the instance it is working on and reuses it when it comes
    back around -- the members still come out right, at the price of the
    recursive member keeping the unsubstituted instance (``n.next.value.``
    finds nothing, which the sweep would flag if it ever changed silently).
    """

    PROJECT = {"tpl_recursive.d": SELF_REFERENTIAL}

    def test_members_of_a_self_referential_instance(self):
        doc = self.open_doc("tpl_recursive.d")
        items = doc.completion("n.")["items"]
        self.assertEqual(find_item(items, "value")["labelDetails"]["description"], "int")
        self.assertEqual(find_item(items, "next")["labelDetails"]["description"], "Node!int")


TWO_LEVELS = """module tpl_nested_two;

struct Rectf
{
    float x;
}

struct TD(T)
{
    T data;
}

struct Inner(T)
{
    TD!T data;
}

struct CTX(T)
{
    Inner!(TD!T) data;
}

void testme()
{
    CTX!Rectf other;

    other.data.data.da
}
"""


class DoublyNestedTemplateInstanceTests(DlsTestCase):
    """The substitution has to descend through both levels of `Inner!(TD!T)`.

    Each rebuild is itself triggered by "does this mapping bind one of the
    instance's recorded arguments?", and the argument of the nested instance is
    what the outer mapping binds -- so that check has to look *inside* an
    argument that is an instance, not only at a bare parameter.
    """

    PROJECT = {"tpl_nested_two.d": TWO_LEVELS}

    def test_innermost_member_is_instantiated(self):
        doc = self.open_doc("tpl_nested_two.d")
        items = doc.completion("other.data.data.da")["items"]
        self.assertEqual(find_item(items, "data")["labelDetails"]["description"], "TD!Rectf")


SUFFIXED_ARGUMENTS = """module tpl_suffixed_args;

struct HashMap(K, V)
{
    K key;
    V value;

    V get(K key)
    {
        return value;
    }
}

HashMap!(int, int*) data;

HashMap!(int, int[4]) rows;

void testme()
{
    auto it = data.get(0);
    auto row = rows.value;
    it.si
}
"""


class SuffixedTemplateArgumentTests(DlsTestCase):
    """An argument keeps its own suffixes: `HashMap!(int, int*)` binds `int*`.

    Only the argument's *name* used to be captured (`int` for `int*`), so a
    member declared `V value;` came out as `int` and a method declared
    `V get()`, called as `data.get(0)`, gave callers an `int`.
    """

    PROJECT = {"tpl_suffixed_args.d": SUFFIXED_ARGUMENTS}

    def described_as(self, doc, site, member):
        items = doc.completion(site)["items"]
        return find_item(items, member)["labelDetails"]["description"]

    def test_member_of_a_pointer_argument(self):
        doc = self.open_doc("tpl_suffixed_args.d")
        self.assertEqual(self.described_as(doc, "data.", "value"), "int*")

    def test_return_type_of_a_pointer_argument(self):
        """The method returns `V`, so the call's type is the pointer too."""
        doc = self.open_doc("tpl_suffixed_args.d")
        self.assertEqual(self.described_as(doc, "data.", "get"), "int*")

    def test_call_through_the_method_keeps_the_pointer(self):
        """`auto it = data.get(0);` -- the variable is an `int*`, not an `int`."""
        doc = self.open_doc("tpl_suffixed_args.d")
        hover = doc.hover("it")["contents"][0]["value"]
        self.assertIn("int* it", hover)

    def test_static_array_argument(self):
        """`int[4]` keeps its dimension through the argument record."""
        doc = self.open_doc("tpl_suffixed_args.d")
        self.assertEqual(self.described_as(doc, "rows.", "value"), "int[4]")
