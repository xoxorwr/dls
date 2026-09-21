"""Completion through ``import`` children of a symbol.

``alias x this;``, a base class/interface and ``mixin Foo;`` are all recorded
the same way: an ``import`` child on the declaring symbol whose *type* is what
the member lookup should continue through.  For a template (``Maybe(T)``) that
type can be spelled with the template's own parameter, so instantiating the
symbol has to instantiate the child as well -- an instance that copied the
flattened members instead lost everything an import reached through the
parameter, and an import child pointing at a *generic* template could shift
the template arguments onto the wrong parameter (the parameters of every
imported template used to be collected alongside the symbol's own).

Each fixture keeps one trailing-dot expression per function: the parser
recovers from an unterminated dotted expression by swallowing the statement
that follows it, which is unrelated to what these tests are about.  Partial
identifiers (``ctx.target.na``) are safe anywhere.
"""

import os

from harness import DlsTestCase, find_item, labels


# -- alias this ---------------------------------------------------------

ALIAS_THIS_DIRECT = """module alias_this_direct;

struct User
{
    string name;
}

struct Maybe(T)
{
    T value;
    bool hasValue;

    alias value this;
}

void main()
{
    Maybe!User m;
    m.na
}
"""

ALIAS_THIS_NESTED = """module alias_this_nested;

struct User
{
    string name;
}

struct Maybe(T)
{
    T value;
    bool hasValue;

    alias value this;
}

struct Context(T)
{
    Maybe!T target;
}

void main()
{
    Context!User ctx;
    ctx.target.na
}
"""

ALIAS_THIS_APP = """module alias_this_app;

import alias_this_leaf;

void main()
{
    Context!User ctx;
    ctx.target.na
}
"""

ALIAS_THIS_LEAF = """module alias_this_leaf;

struct User
{
    string name;
}

struct Maybe(T)
{
    T value;
    bool hasValue;

    alias value this;
}

struct Context(T)
{
    Maybe!T target;
}
"""

ALIAS_THIS_CHAIN = """module alias_this_chain;

struct User
{
    string name;
}

struct Inner(T)
{
    T value;
    alias value this;
}

struct Outer(T)
{
    Inner!T value;
    alias value this;
}

void main()
{
    Outer!User o;
    o.na
}
"""

ALIAS_THIS_POINTER = """module alias_this_pointer;

struct User
{
    string name;
}

struct Pointer(T)
{
    T* ptr;
    alias ptr this;
}

void main()
{
    Pointer!User p;
    p.na
}
"""

ALIAS_THIS_SLICE = """module alias_this_slice;

struct Slice(T)
{
    T[] items;
    alias items this;
}

void main()
{
    Slice!int xs;
    xs.le
}
"""

ALIAS_THIS_CLASS = """module alias_this_class;

struct User
{
    string name;
}

class Holder(T)
{
    T value;
    alias value this;
}

void main()
{
    Holder!User h;
    h.na
}
"""

ALIAS_THIS_CONCRETE_MEMBER = """module alias_this_concrete;

struct User
{
    string name;
}

struct Maybe(T)
{
    T value;
    User other;
    alias other this;
}

void main()
{
    Maybe!int m;
    m.na
}
"""

ALIAS_THIS_SELF_REFERENTIAL = """module alias_this_recursive;

struct User
{
    string name;
}

struct Node(T)
{
    T value;
    Node!T next;
    alias next this;
}

void main()
{
    Node!User n;
    n.
}
"""


class AliasThisImportTests(DlsTestCase):
    """``alias value this;`` where ``value`` is typed by a parameter."""

    PROJECT = {
        "alias_this_direct.d": ALIAS_THIS_DIRECT,
        "alias_this_nested.d": ALIAS_THIS_NESTED,
        "alias_this_app.d": ALIAS_THIS_APP,
        "alias_this_leaf.d": ALIAS_THIS_LEAF,
        "alias_this_chain.d": ALIAS_THIS_CHAIN,
        "alias_this_pointer.d": ALIAS_THIS_POINTER,
        "alias_this_slice.d": ALIAS_THIS_SLICE,
        "alias_this_class.d": ALIAS_THIS_CLASS,
        "alias_this_concrete.d": ALIAS_THIS_CONCRETE_MEMBER,
        "alias_this_recursive.d": ALIAS_THIS_SELF_REFERENTIAL,
    }

    def test_member_typed_by_the_parameter(self):
        doc = self.open_doc("alias_this_direct.d")
        self.assertEqual(labels(doc.completion("m.na")["items"]), ["name"])

    def test_instance_nested_in_another_instance(self):
        """The reported shape: `Context!User` holds `Maybe!T`."""
        doc = self.open_doc("alias_this_nested.d")
        self.assertEqual(labels(doc.completion("ctx.target.na")["items"]), ["name"])

    def test_templates_from_an_imported_module(self):
        doc = self.open_doc("alias_this_app.d")
        self.assertEqual(labels(doc.completion("ctx.target.na")["items"]), ["name"])

    def test_alias_this_chain_across_two_instances(self):
        doc = self.open_doc("alias_this_chain.d")
        self.assertEqual(labels(doc.completion("o.na")["items"]), ["name"])

    def test_pointer_member(self):
        doc = self.open_doc("alias_this_pointer.d")
        self.assertEqual(labels(doc.completion("p.na")["items"]), ["name"])

    def test_slice_member(self):
        doc = self.open_doc("alias_this_slice.d")
        self.assertEqual(labels(doc.completion("xs.le")["items"]), ["length"])

    def test_class_template(self):
        doc = self.open_doc("alias_this_class.d")
        self.assertEqual(labels(doc.completion("h.na")["items"]), ["name"])

    def test_concrete_member_type_still_resolves(self):
        doc = self.open_doc("alias_this_concrete.d")
        self.assertEqual(labels(doc.completion("m.na")["items"]), ["name"])

    def test_self_referential_alias_this_does_not_loop(self):
        """`alias next this;` with `next` of the enclosing instance's type.

        Rebuilding the instance walks the member and the import child, both of
        which reach the instance again; the resolver's in-progress mark is what
        stops that, and the completion still has to answer.
        """
        doc = self.open_doc("alias_this_recursive.d")
        items = doc.completion("n.")["items"]
        self.assertEqual(find_item(items, "value")["labelDetails"]["description"], "User")
        self.assertEqual(find_item(items, "next")["labelDetails"]["description"], "Node!User")
        self.assertIsNone(self.client.process.poll(), "server died instantiating Node!User")


# -- base classes and interfaces ----------------------------------------

BASE_CLASS_ARGUMENT = """module base_argument;

class Base(T)
{
    T baseField;
}

class Derived(T) : Base!T
{
}

void main()
{
    Derived!int d;
    d.base
}
"""

BASE_CLASS_RENAMED_ARGUMENT = """module base_renamed;

class Base(T)
{
    T baseField;
}

class Derived(U) : Base!U
{
}

void main()
{
    Derived!int d;
    d.base
}
"""

BASE_CLASS_TWO_LEVELS = """module base_two_levels;

class Base(T)
{
    T baseField;
}

class Mid(T) : Base!T
{
    T midField;
}

class Leaf(T) : Mid!T
{
    T leafField;
}

void main()
{
    Leaf!int l;
    l.
}
"""

INTERFACE_ARGUMENT = """module interface_argument;

interface Store(T)
{
    void put(T value);
}

class Impl(T) : Store!T
{
    void put(T value) {}
}

void main()
{
    Impl!int i;
    i.pu
}
"""


class InheritanceImportTests(DlsTestCase):
    """A base class is an import child too, and its arguments are written."""

    PROJECT = {
        "base_argument.d": BASE_CLASS_ARGUMENT,
        "base_renamed.d": BASE_CLASS_RENAMED_ARGUMENT,
        "base_two_levels.d": BASE_CLASS_TWO_LEVELS,
        "interface_argument.d": INTERFACE_ARGUMENT,
    }

    def described_as(self, doc, site, member):
        items = doc.completion(site)["items"]
        return find_item(items, member)["labelDetails"]["description"]

    def test_base_member_follows_the_argument(self):
        doc = self.open_doc("base_argument.d")
        self.assertEqual(self.described_as(doc, "d.base", "baseField"), "int")

    def test_base_argument_is_matched_by_position_not_name(self):
        """`Derived(U) : Base!U` -- the base's parameter is spelled `T`."""
        doc = self.open_doc("base_renamed.d")
        self.assertEqual(self.described_as(doc, "d.base", "baseField"), "int")

    def test_members_of_every_level(self):
        doc = self.open_doc("base_two_levels.d")
        items = doc.completion("l.")["items"]
        for member in ("baseField", "midField", "leafField"):
            self.assertEqual(find_item(items, member)["labelDetails"]["description"], "int")

    def test_interface_method(self):
        doc = self.open_doc("interface_argument.d")
        self.assertEqual(labels(doc.completion("i.pu")["items"]), ["put"])


# -- mixin templates ----------------------------------------------------

MIXIN_TEMPLATE_ARGUMENT = """module mixin_argument;

mixin template Extra(T)
{
    T extra;
}

struct Box(T)
{
    mixin Extra!T;
    T value;
}

void main()
{
    Box!int b;
    b.ex
}
"""

MIXIN_TEMPLATE_RENAMED_ARGUMENT = """module mixin_renamed;

mixin template Extra(T)
{
    T extra;
}

struct Box(U)
{
    mixin Extra!U;
    U value;
}

void main()
{
    Box!int b;
    b.ex
}
"""

MIXIN_TEMPLATE_CONCRETE_ARGUMENT = """module mixin_concrete;

mixin template Extra(T)
{
    T extra;
}

struct Box(T)
{
    mixin Extra!int;
    T value;
}

void main()
{
    Box!string b;
    b.ex
}
"""

PARAMETERS_DO_NOT_SHIFT = """module parameters_do_not_shift;

mixin template Extra(U)
{
    U extra;
}

class Base(T)
{
    T baseField;
}

class Combo(T) : Base!T
{
    mixin Extra!T;
}

void main()
{
    Combo!int c;
    c.
}
"""

EVERY_KIND_OF_IMPORT = """module every_kind;

struct User
{
    string name;
}

mixin template Extra(T)
{
    T extra;
}

class Base
{
    int baseField;
}

class Combo(T) : Base
{
    mixin Extra!T;
    T value;
    alias value this;
}

void main()
{
    Combo!User c;
    c.
}
"""


class MixinTemplateImportTests(DlsTestCase):
    """``mixin Extra!T;``, and the parameters of one template next to another."""

    PROJECT = {
        "mixin_argument.d": MIXIN_TEMPLATE_ARGUMENT,
        "mixin_renamed.d": MIXIN_TEMPLATE_RENAMED_ARGUMENT,
        "mixin_concrete.d": MIXIN_TEMPLATE_CONCRETE_ARGUMENT,
        "parameters_do_not_shift.d": PARAMETERS_DO_NOT_SHIFT,
        "every_kind.d": EVERY_KIND_OF_IMPORT,
    }

    def described_as(self, doc, site, member):
        items = doc.completion(site)["items"]
        return find_item(items, member)["labelDetails"]["description"]

    def test_mixin_member_follows_the_argument(self):
        doc = self.open_doc("mixin_argument.d")
        self.assertEqual(self.described_as(doc, "b.ex", "extra"), "int")

    def test_mixin_argument_is_matched_by_position_not_name(self):
        doc = self.open_doc("mixin_renamed.d")
        self.assertEqual(self.described_as(doc, "b.ex", "extra"), "int")

    def test_mixin_with_its_own_concrete_argument(self):
        """`mixin Extra!int;` in `Box!string` -- `int`, not the host's `T`."""
        doc = self.open_doc("mixin_concrete.d")
        self.assertEqual(self.described_as(doc, "b.ex", "extra"), "int")

    def test_another_templates_parameters_do_not_shift_the_arguments(self):
        """`mixin Extra!T;` must not consume `Combo!int`'s argument.

        The mixin template's `U` used to be collected as if it were a
        parameter of `Combo`, so `int` bound to `U` and `baseField` kept
        reporting `T`.
        """
        doc = self.open_doc("parameters_do_not_shift.d")
        self.assertEqual(self.described_as(doc, "c.", "baseField"), "int")
        self.assertEqual(self.described_as(doc, "c.", "extra"), "int")

    def test_base_mixin_and_alias_this_together(self):
        doc = self.open_doc("every_kind.d")
        items = doc.completion("c.")["items"]
        # The aliased-to type's member, the base class's field and the mixin
        # template's field all come from import children of `Combo`.
        self.assertEqual(find_item(items, "name")["labelDetails"]["description"], "string")
        self.assertEqual(find_item(items, "baseField")["labelDetails"]["description"], "int")
        # `Combo!User` passes `User` on to `mixin Extra!T`.
        self.assertEqual(find_item(items, "extra")["labelDetails"]["description"], "User")


# -- the module cache still owns the instances --------------------------

RECACHE_LEAF = """module recache_leaf;

struct User
{
    string name;
}

struct Maybe(T)
{
    T value;
    alias value this;
}

struct Context(T)
{
    Maybe!T target;
}
"""

RECACHE_LEAF_WITH_AGE = """module recache_leaf;

struct User
{
    string name;
    int age;
}

struct Maybe(T)
{
    T value;
    alias value this;
}

struct Context(T)
{
    Maybe!T target;
}
"""


def recache_app(module: str, member: str) -> str:
    return f"""module {module};

import recache_leaf;

void main()
{{
    Context!User ctx;
    ctx.target.{member}
}}
"""


class ImportChildRecacheTests(DlsTestCase):
    """Instance imports are rebuilt in the cache, not shared with the source.

    An instance owns the import children it copies but shares the types they
    point at, so re-caching the module that declared the template disposes the
    old instances.  A save that changes the aliased-to type has to be visible
    afterwards -- and the server has to still be alive.
    """

    PROJECT = {
        "recache_leaf.d": RECACHE_LEAF,
        "recache_name.d": recache_app("recache_name", "na"),
        "recache_age.d": recache_app("recache_age", "ag"),
    }

    def save(self, doc, text: str) -> None:
        with open(os.path.join(self.root, doc.relpath), "w", encoding="utf-8") as handle:
            handle.write(text)
        doc.change(text)
        self.client.did_save(doc.uri)

    def test_a_save_that_changes_the_aliased_type_is_picked_up(self):
        leaf = self.open_doc("recache_leaf.d")
        name_doc = self.open_doc("recache_name.d")
        age_doc = self.open_doc("recache_age.d")

        self.assertEqual(labels(name_doc.completion("ctx.target.na")["items"]), ["name"])
        self.assertEqual(labels(age_doc.completion("ctx.target.ag")["items"]), [])

        self.save(leaf, RECACHE_LEAF_WITH_AGE)

        self.assertEqual(labels(age_doc.completion("ctx.target.ag")["items"]), ["age"])
        self.assertEqual(labels(name_doc.completion("ctx.target.na")["items"]), ["name"])
        self.assertIsNone(self.client.process.poll(), "server died on re-caching")
