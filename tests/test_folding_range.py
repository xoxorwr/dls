"""textDocument/foldingRange: where the server says a block can be folded.

The point of the capability is that folding follows D's braces instead of the
client's indentation heuristic: a label (``end:``) sits at column zero while
the statements around it are indented, so a client folding by indentation ends
the function block at the label rather than at the closing brace.
"""

from harness import DlsTestCase


REPRO = """module app;

void fun()
{ // this fold should reach the closing brace, not the label
    int a;
end:
    int b;
}
"""

NESTED = """module nested;

void outer()
{
    if (true)
    {
        int a;
    }
    int b;
}
"""

TEXT_ONLY = """module text_only;

string s = "{ not a block }";

// { neither this one
/* { nor this } */

void f()
{
    int a;
}
"""

COMMENTS = """module comments;

// one
// two
// three

/* a
   block
   comment */

void f()
{
    int a;
}
"""

INLINE = """module inline;

int compute(int x) { return x; }
"""

TRICKY_TEXT = """module tricky_text;

string token = q{ { not a block } };
string raw = r"{{}}";
string tick = `{ {`;
char brace = '{';

void f()
{
    int a;
}
"""

NESTED_COMMENT = """module nested_comment;

/+ outer
   /+ inner
      with a brace { +/
   still outer
+/

void f()
{
    int a;
}
"""

MIXED = """module mixed;

void allman()
{
    int a;
}

void knr() {
    int b;
}
"""

GAP = """module gap;

void f()

{
    int a;
}
"""


def pairs(ranges):
    """The (startLine, endLine) pairs of a folding range response."""
    return {(r["startLine"], r["endLine"]) for r in ranges}


def find(ranges, line):
    """The range whose start line is ``line`` (the outermost, if nested)."""
    starts = [r for r in ranges if r["startLine"] == line]
    return min(starts, key=lambda r: -r["endLine"]) if starts else None


class FoldingRangeTests(DlsTestCase):
    PROJECT = {
        "app.d": REPRO,
        "nested.d": NESTED,
        "text_only.d": TEXT_ONLY,
        "comments.d": COMMENTS,
        "inline.d": INLINE,
        "tricky_text.d": TRICKY_TEXT,
        "nested_comment.d": NESTED_COMMENT,
        "mixed.d": MIXED,
        "gap.d": GAP,
    }

    def open_ranges(self, relpath):
        doc = self.open_doc(relpath)
        return doc, doc.folding_range()

    def test_block_spans_the_whole_function_body(self):
        doc, ranges = self.open_ranges("app.d")
        header_line, _ = doc.position("void fun()")
        close_line, _ = doc.position("int b;\n}")
        label_line, _ = doc.position("end:")

        # Allman `{` alone on its line pulls up to the header, so the fold
        # reads `void fun() {...}` instead of `void fun()` + `{...}`.
        self.assertEqual(pairs(ranges), {(header_line, close_line)})
        # The bug this replaced: a fold that stops at the dedented label.
        self.assertNotIn((header_line, label_line), pairs(ranges))

    def test_nested_blocks_fold_separately(self):
        doc, ranges = self.open_ranges("nested.d")
        outer_header, _ = doc.position("void outer()")
        inner_header, _ = doc.position("if (true)")
        inner_close, _ = doc.position("int a;\n    }")
        outer_close, _ = doc.position("int b;\n}")

        self.assertEqual(pairs(ranges), {(outer_header, outer_close), (inner_header, inner_close)})

        outer = find(ranges, outer_header)
        inner = find(ranges, inner_header)
        self.assertLessEqual(outer["startLine"], inner["startLine"])
        self.assertLessEqual(inner["endLine"], outer["endLine"])

    def test_text_outside_code_does_not_fold(self):
        doc, ranges = self.open_ranges("text_only.d")
        header_line, _ = doc.position("void f()")
        close_line, _ = doc.position("int a;\n}")

        # The braces inside the string and the comments are text: only the
        # function's own block survives.
        self.assertEqual(pairs(ranges), {(header_line, close_line)})

    def test_comments_fold_with_a_comment_kind(self):
        doc, ranges = self.open_ranges("comments.d")

        block_line, _ = doc.position("// one")
        block_end, _ = doc.position("// three")
        block = find(ranges, block_line)
        self.assertIsNotNone(block)
        self.assertEqual(block["endLine"], block_end)
        self.assertEqual(block["kind"], "comment")

        comment_line, _ = doc.position("/* a")
        comment_end, _ = doc.position("comment */")
        block_comment = find(ranges, comment_line)
        self.assertIsNotNone(block_comment)
        self.assertEqual(block_comment["endLine"], comment_end)
        self.assertEqual(block_comment["kind"], "comment")

    def test_single_line_blocks_do_not_fold(self):
        _, ranges = self.open_ranges("inline.d")
        self.assertEqual(ranges, [])

    def test_token_strings_and_raw_strings_are_not_blocks(self):
        doc, ranges = self.open_ranges("tricky_text.d")
        header_line, _ = doc.position("void f()")
        close_line, _ = doc.position("int a;\n}")

        # `q{...}`, `r"..."`, backticks and a character literal each hide their
        # braces inside one token, so the function block is all there is.
        self.assertEqual(pairs(ranges), {(header_line, close_line)})

    def test_nested_comment_folds_as_one_comment(self):
        doc, ranges = self.open_ranges("nested_comment.d")
        start_line, _ = doc.position("/+ outer")
        end_line, _ = doc.position("still outer\n+/")
        header_line, _ = doc.position("void f()")
        close_line, _ = doc.position("int a;\n}")

        self.assertEqual(
            pairs(ranges), {(start_line, end_line), (header_line, close_line)}
        )
        comment = find(ranges, start_line)
        self.assertEqual(comment["kind"], "comment")

    def test_mixed_styles_both_start_on_the_header(self):
        doc, ranges = self.open_ranges("mixed.d")
        allman_header, _ = doc.position("void allman()")
        allman_close, _ = doc.position("int a;\n}")
        knr_header, _ = doc.position("void knr()")
        knr_close, _ = doc.position("int b;\n}")

        # Allman pulls up, K&R already starts on the header: both read
        # `void ...() {...}` when collapsed.
        self.assertEqual(
            pairs(ranges), {(allman_header, allman_close), (knr_header, knr_close)}
        )

    def test_blank_lines_between_header_and_brace(self):
        doc, ranges = self.open_ranges("gap.d")
        header_line, _ = doc.position("void f()")
        close_line, _ = doc.position("int a;\n}")

        self.assertEqual(pairs(ranges), {(header_line, close_line)})

    def test_ranges_are_ordered_and_nested(self):
        for relpath in (
            "app.d",
            "nested.d",
            "text_only.d",
            "comments.d",
            "tricky_text.d",
            "nested_comment.d",
            "mixed.d",
            "gap.d",
        ):
            doc, ranges = self.open_ranges(relpath)
            line_count = doc.text.count("\n")
            for index, range_ in enumerate(ranges):
                self.assertLess(range_["startLine"], range_["endLine"], msg=relpath)
                self.assertLessEqual(range_["endLine"], line_count, msg=relpath)
                if index:
                    previous = ranges[index - 1]
                    self.assertLessEqual(
                        (previous["startLine"], -previous["endLine"]),
                        (range_["startLine"], -range_["endLine"]),
                        msg=relpath,
                    )
