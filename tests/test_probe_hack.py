"""Temporary probe: which shape needs the injected ';'."""

import json

from harness import DlsTestCase, labels


PRELUDE = """module app;

enum Color { Red, Green }

struct State
{
    int aaa;
}

"""

MAIN = PRELUDE + """void main()
{
%s
}
"""

STRUCT = PRELUDE + """struct TTT
{
%s
}
"""


CASES = {
    # inside a function body, the last statement unterminated
    "local.d": (MAIN % "    int localOne;\n    localOn", "    localOn"),
    "local_init.d": (MAIN % "    int localOne;\n    int x = localOn", "    int x = localOn"),
    "dot.d": (MAIN % "    State st;\n    st.", "    st."),
    "dot_prefix.d": (MAIN % "    State st;\n    st.aa", "    st.aa"),
    "dot_in_call.d": (MAIN % "    State st;\n    foo(st.", "    foo(st."),
    "enum_shorthand.d": (MAIN % "    State st;\n    st.aaa = ", "    st.aaa = "),
    "struct_init.d": (MAIN % "    State st = { aa", "    State st = { aa"),
    # inside a struct body
    "member_type.d": (STRUCT % "    Sta", "    Sta"),
    "member_name.d": (STRUCT % "    State st;\n    State ot", "    State ot"),
    "member_dot.d": (STRUCT % "    State st;\n    st.", "    st."),
    # no closing brace at all
    "open_struct.d": (PRELUDE + "struct TTT\n{\n    State st\n    st.", "    st."),
}


class ProbeHack(DlsTestCase):
    PROJECT = {name: text for name, (text, _) in CASES.items()}

    def test_probe(self):
        for name, (_, needle) in sorted(CASES.items()):
            doc = self.open_doc(name)
            found = sorted(labels(doc.completion(needle)["items"]))
            print("CASE", name, json.dumps(found[:10]))
