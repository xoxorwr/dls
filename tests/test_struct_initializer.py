"""Completion inside a struct initializer literal.

Both literal forms D accepts are covered: the positional one
(``Foo foo = { 1, 2 }``) and the designated one (``Foo foo = { valuea: 1 }``).
In either form a cursor sitting where a field name is expected lists the
struct's fields - at the start of the initializer and after each element.  The
second position used to come back empty: ``getCalltipHint`` (``complete.d``)
read the trailing ``,`` as a function call's argument list, so ``complete``
dispatched to ``calltipCompletion`` and never reached ``dotCompletion``'s
struct-members path.
"""

from harness import KIND_FIELD, DlsTestCase


FIELDS = """struct Foo
{
    int valuea;
    long valueb;
}
"""


def initializer(module, body):
    """One module whose ``main`` holds a single struct literal and nothing else.

    ``body`` is the text between ``{`` and ``}`` of the initializer, written so
    that the cursor lands on the last line of it (see ``Doc.position``).
    """
    return f"""module {module};

{FIELDS}
void main()
{{
    Foo foo = {{
{body}    }};
}}
"""


EMPTY = initializer("struct_init_empty", "        \n")
AFTER_POSITIONAL = initializer("struct_init_positional", "        1,\n        \n")
AFTER_DESIGNATED = initializer("struct_init_designated", "        valuea: 1,\n        \n")


class StructInitializerCompletionTests(DlsTestCase):
    PROJECT = {
        "empty.d": EMPTY,
        "after_positional.d": AFTER_POSITIONAL,
        "after_designated.d": AFTER_DESIGNATED,
    }

    def _fields(self, relpath, needle):
        """The field items offered at the cursor that ends ``needle``."""
        items = self.open_doc(relpath).completion(needle)["items"]
        return {item["label"]: item for item in items if item["kind"] == KIND_FIELD}

    def test_an_empty_initializer_lists_every_field(self):
        fields = self._fields("empty.d", "Foo foo = {\n        ")
        self.assertEqual(sorted(fields), ["valuea", "valueb"])
        self.assertEqual(fields["valueb"]["labelDetails"]["description"], "long")

    def test_a_positional_initializer_lists_fields_after_the_first_value(self):
        fields = self._fields("after_positional.d", "Foo foo = {\n        1,\n        ")
        self.assertIn("valueb", fields, "the second field is what goes here")
        self.assertTrue(set(fields) <= {"valuea", "valueb"}, "only Foo's fields")

    def test_a_designated_initializer_lists_fields_after_the_first_one(self):
        fields = self._fields(
            "after_designated.d", "Foo foo = {\n        valuea: 1,\n        "
        )
        self.assertIn("valueb", fields, "the field that is still unset is what goes here")
        self.assertTrue(set(fields) <= {"valuea", "valueb"}, "only Foo's fields")
