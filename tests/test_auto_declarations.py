"""``auto`` declarations: the breadcrumb path, pinned as the refactor's net.

``auto x = <expr>`` cannot be typed while the file is being read, so `first.d`
records *how to reach* the type -- breadcrumbs -- and `second.d` walks them
once the modules they mention are cached.  Those crumbs (marker strings like
`*ptr*` / `*arr*`, plus the parallel `suffixDimensions` list and the
`VariableContext` template tree) are what ``docs/breadcrumb-replacement.md``
replaces with a typed path.

Nothing else in the suite covered this: before these tests, a rewrite of the
crumbs would have been verified only by "the suite still passes", which says
nothing about `auto` at all.  Each shape below is a crumb kind the typed path
has to reproduce.

Fixtures use one completion site per file, and the library modules are separate
so the cross-module cases go through the deferred-resolution path.
"""

import unittest

from harness import DlsTestCase, labels


LIB_CALL = """module auto_lib_call;

struct Widget
{
    int size;
}

Widget make()
{
    return Widget();
}
"""

APP_CALL = """module auto_app_call;

import auto_lib_call;

void main()
{
    auto w = make();
    w.si
}
"""

ADDRESS_OF = """module auto_address;

struct State
{
    int size;
}

void main()
{
    State st;
    auto p = &st;
    p.si
}
"""

INDEXED_ELEMENT = """module auto_element;

struct Row
{
    int size;
}

void main()
{
    Row[4] rows;
    auto row = rows[0];
    row.si
}
"""

ADDRESS_OF_STATIC_ARRAY_ELEMENT = """module auto_array_address;

struct Data
{
    int size;
}

void main()
{
    Data[4][] rows;
    auto p = &rows[0][0];
    p.si
}
"""

AUTO_CHAIN = """module auto_chain;

struct State
{
    int size;
}

void main()
{
    State st;
    auto first = st;
    auto second = first;
    second.si
}
"""

LIB_STORAGE = """module auto_lib_storage;

struct Widget
{
    int size;
}

Widget global_widget;

Widget* widget()
{
    return &global_widget;
}
"""

APP_STORAGE = """module auto_app_storage;

import auto_lib_storage;

void main()
{
    auto w = widget();
    w.si
}
"""


class AutoDeclarationTests(DlsTestCase):
    PROJECT = {
        "auto_lib_call.d": LIB_CALL,
        "auto_app_call.d": APP_CALL,
        "auto_address.d": ADDRESS_OF,
        "auto_element.d": INDEXED_ELEMENT,
        "auto_array_address.d": ADDRESS_OF_STATIC_ARRAY_ELEMENT,
        "auto_chain.d": AUTO_CHAIN,
        "auto_lib_storage.d": LIB_STORAGE,
        "auto_app_storage.d": APP_STORAGE,
    }

    def test_auto_from_a_call_across_an_import(self):
        """`auto w = make();` where `make` comes from another module."""
        doc = self.open_doc("auto_app_call.d")
        self.assertIn("size", labels(doc.completion("w.si")["items"]))

    def test_auto_from_the_address_of_a_variable(self):
        """`auto p = &st;` -- the pointer crumb."""
        doc = self.open_doc("auto_address.d")
        self.assertIn("size", labels(doc.completion("p.si")["items"]))

    def test_auto_from_an_indexed_element(self):
        """`auto row = rows[0];` -- the index (step down) crumb."""
        doc = self.open_doc("auto_element.d")
        self.assertIn("size", labels(doc.completion("row.si")["items"]))

    def test_auto_from_the_address_of_a_static_array_element(self):
        """`auto p = &rows[0][0];` on `Data[4][] rows`.

        Three crumbs in one expression: step down into the dynamic array, step
        down into the static array (whose dimension has to survive), then take
        the address.  If any of them is lost `p` stops being a `Data*` and
        `size` is not offered, which is what makes this case worth pinning.

        Note `&rows[0]` is deliberately *not* asserted: that is a `Data[4]*`,
        and `row.size` does not exist in D (only the array's own properties
        do) -- completion offering just `sizeof` there is correct.
        """
        doc = self.open_doc("auto_array_address.d")
        self.assertIn("size", labels(doc.completion("p.si")["items"]))

    def test_auto_chain(self):
        """`auto second = first;` -- a crumb path through another `auto`."""
        doc = self.open_doc("auto_chain.d")
        self.assertIn("size", labels(doc.completion("second.si")["items"]))

    def test_auto_inside_the_imported_module(self):
        """`auto w = widget();` where `widget` is a library function.

        The function lives in a module the app only imports, so the app's
        `auto` is resolved on the deferred path -- after the import is cached.
        """
        doc = self.open_doc("auto_app_storage.d")
        self.assertIn("size", labels(doc.completion("w.si")["items"]))


AUTO_RETURN = """module auto_return;

struct Widget
{
    int size;
}

Widget global_widget;

auto widget()
{
    return global_widget;
}

auto widgetPointer()
{
    return &global_widget;
}

auto shortened() => global_widget;

void main()
{
    auto w = widget();
    auto p = widgetPointer();
    auto s = shortened();
    w.si
    p.si
    s.si
}
"""

IMPORTED_AUTO_LIB = """module imported_auto_lib;

struct Widget
{
    int size;
}

Widget global_widget;

auto make_widget()
{
    return global_widget;
}
"""

IMPORTED_AUTO_APP = """module imported_auto_app;

import imported_auto_lib;

void main()
{
    auto w = make_widget();
    w.si
}
"""


class AutoReturnTypeTests(DlsTestCase):
    """An `auto` function's return type is inferred from its `return`.

    `auto w() { return g; }` declares no type at all: the `return` expression
    is the only place it appears, so the function symbol gets an initializer
    lookup built from that expression -- the same path `auto x = <expr>`
    variables already use.

    The body is only in the request's own tree: the module cache parses
    modules with a parser that skips every function body (that is what keeps
    caching Phobos cheap), so `AutocompleteParser` has to keep the body of a
    function with no declared return type even when it lies before the cursor.
    """

    PROJECT = {
        "auto_return.d": AUTO_RETURN,
        "imported_auto_lib.d": IMPORTED_AUTO_LIB,
        "imported_auto_app.d": IMPORTED_AUTO_APP,
    }

    def test_auto_return_type_is_inferred(self):
        doc = self.open_doc("auto_return.d")
        self.assertIn("size", labels(doc.completion("w.si")["items"]))

    def test_auto_return_type_of_a_pointer(self):
        """`auto p = widgetPointer();` -- `return &g;` is a `Widget*`."""
        doc = self.open_doc("auto_return.d")
        self.assertIn("size", labels(doc.completion("p.si")["items"]))

    def test_shortened_auto_function(self):
        """`auto shortened() => global_widget;` -- no `return` statement."""
        doc = self.open_doc("auto_return.d")
        self.assertIn("size", labels(doc.completion("s.si")["items"]))

    @unittest.expectedFailure
    def test_auto_function_in_an_imported_module(self):
        """Known gap: a module that is only imported keeps no function body.

        The imported module is read by the caching parser, which skips every
        function body -- so its `auto` functions still resolve to nothing.
        """
        doc = self.open_doc("imported_auto_app.d")
        self.assertIn("size", labels(doc.completion("w.si")["items"]))
