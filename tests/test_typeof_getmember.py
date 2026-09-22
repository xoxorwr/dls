"""`typeof` aliases and `__traits(getMember, T, name)` resolve.

``alias T = typeof(foo)`` used to leave `T` without a type: the declared-type
walker in ``second.d`` returned `unmodelled` for `TypeofExpression`, so the
alias pointed at nothing and every use of `T` failed.  Likewise
``alias M = __traits(getMember, T, name)`` was unmodelled, and the member name
arriving through a manifest constant (`enum name = "bar"`) had no folding at
all (a bare identifier even parses as a *type*, not an expression).

Three cooperating changes, each deliberately narrow:

* `resolveDeclaredType` handles `typeof(expr)` (evaluate the expression with
  the initializer walker, take its type) and `__traits(getMember, Base, name)`
  for a literal or a single-literal manifest constant recorded by the first
  pass (`DSymbol.constantValue`).
* A `typeof` that runs before its operand resolves leaves the alias unset
  instead of freezing it at the operand; `secondPass` retries suspicious
  aliases (bounded fixpoint) once the siblings resolved.
* Anything else (other traits, non-constant names) stays unmodelled, exactly
  as before.
"""

import unittest

from harness import DlsTestCase, find_item


CHAIN = """module TraitsGetMember;

struct Foo(T)
{
    alias bar = T;
}

Foo!int foo;

enum name = "bar";

alias T = typeof(foo);
alias M = __traits(getMember, T, name);

M value;

extern(C) void main()
{
    value.
}
"""

LITERAL = """module TraitsGetMemberLit;

struct Foo(T)
{
    alias bar = T;
}

Foo!int foo;

alias T = typeof(foo);
alias M = __traits(getMember, T, "bar");

M value;

extern(C) void main()
{
    value.
}
"""

TYPEOF_ALONE = """module TypeofAlone;

struct Foo(T)
{
    T field;
}

Foo!int foo;

alias T = typeof(foo);

void testme()
{
    T x;
    x.field
}
"""

UNKNOWN_MEMBER = """module TraitsUnknown;

struct Foo(T)
{
    alias bar = T;
}

Foo!int foo;

alias M = __traits(getMember, Foo!int, "nope");

M value;

extern(C) void main()
{
    value.
}
"""


class TypeofGetMemberChainTests(DlsTestCase):
    PROJECT = {"app.d": CHAIN}

    def test_value_has_int_members(self):
        """`M value; value.` -- through typeof, getMember and the enum."""
        doc = self.open_doc("app.d")
        items = doc.completion("value.")["items"]
        self.assertTrue(items)
        self.assertEqual(find_item(items, "sizeof")["label"], "sizeof")

    def test_value_is_int_not_the_aggregate(self):
        """`value` must be `int`, not `Foo!int`: no `bar` member on `value.`."""
        doc = self.open_doc("app.d")
        items = doc.completion("value.")["items"]
        labels = [item["label"] for item in items]
        self.assertNotIn("bar", labels)
        self.assertNotIn("field", labels)

    def test_typeof_alias_points_at_the_instance(self):
        doc = self.open_doc("app.d")
        hover = doc.hover("alias T")["contents"][0]["value"]
        self.assertIn("Foo!int", hover)

    def test_getmember_alias_resolves_to_int(self):
        """Hovering through the chain ends at `int`, not the next alias."""
        doc = self.open_doc("app.d")
        hover = doc.hover("alias M")["contents"][0]["value"]
        self.assertIn("int", hover)

    def test_definition_of_value_reaches_its_declaration(self):
        doc = self.open_doc("app.d")
        locations = doc.definition("value.", offset=-1)
        self.assertTrue(locations)


class TypeofGetMemberLiteralTests(DlsTestCase):
    PROJECT = {"app.d": LITERAL}

    def test_literal_member_name(self):
        """`getMember(T, "bar")` -- no constant involved."""
        doc = self.open_doc("app.d")
        items = doc.completion("value.")["items"]
        self.assertTrue(items)
        self.assertEqual(find_item(items, "sizeof")["label"], "sizeof")


class TypeofAloneTests(DlsTestCase):
    PROJECT = {"app.d": TYPEOF_ALONE}

    def test_typeof_alias_usable_as_a_type(self):
        """`T x; x.field` -- `T` is `Foo!int`, so the field is `int`."""
        doc = self.open_doc("app.d")
        items = doc.completion("x.field")["items"]
        self.assertEqual(
            find_item(items, "field")["labelDetails"]["description"], "int"
        )


SCOPE_PREFIX = """module TraitsScopePrefix;

struct Foo(T)
{
    alias bar = T;
}

Foo!int foo;

enum name = "bar";

alias T = typeof(foo);
alias M = __traits(getMember, T, name);

M value;

extern(C) void main()
{
    va
}
"""


class ScopePrefixTests(DlsTestCase):
    PROJECT = {"app.d": SCOPE_PREFIX}

    def test_scope_completion_shows_int_not_the_alias(self):
        """Typing `va` offers `value` typed `int`, not `M`."""
        doc = self.open_doc("app.d")
        item = find_item(doc.completion("va", occurrence=1)["items"], "value")
        self.assertEqual(item["labelDetails"]["description"], "int")


class UnknownMemberTests(DlsTestCase):
    PROJECT = {"app.d": UNKNOWN_MEMBER}

    def test_unknown_member_stays_unresolved(self):
        """A missing member resolves to nothing but must not break the file."""
        doc = self.open_doc("app.d")
        items = doc.completion("value.")["items"]
        self.assertEqual(items, [])
        # The server is still alive for the rest of the suite.
        symbols = doc.document_symbols()
        self.assertTrue(symbols)


if __name__ == "__main__":
    unittest.main()
