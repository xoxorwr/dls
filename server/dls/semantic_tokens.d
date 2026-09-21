module dls.semantic_tokens;


import rt.dbg;
import mem = rt.memz;
import rt.json;
import rt.str;

import core.stdc.stdio;
import core.stdc.stdlib;
import core.stdc.string;
import core.stdc.ctype;

import dls.main;
import dls.io;
import dls.dcd;

void lsp_semantic_tokens(int id, JsonNode * params_json, bool full) {
    auto output = printJsonStr(params_json);
    LINFO("{} {}", full, output);

    return;

    auto allocator = arena.allocator();

    auto text_document_json = json.get_object_item(params_json, "textDocument");
    char* uri = json_string_item(text_document_json, "uri");

    Position start;
    Position end;

    if (!full)
        get_range(params_json, &start, &end);

    if (uri == null) {
        LERRO("doc not found");
        exit(1);
    }
    auto buffer = get_buffer(uri);
    auto it = cast(string) buffer.content[0..strlen(buffer.content)];

    if (full)
    {
        auto symbols = dcd_document_symbols_sem(uri, buffer.content);

        auto obj = json.create_object();
        auto root = json.add_array_to_object(obj, "data");
        int start_l = -1;
        int start_c = -1;

        void add_info(DSymbolInfo* info)
        {
            auto s = bytesToPosition(it, info.range[0]);
            auto e = bytesToPosition(it, info.range[1]);


            bool add = true;
            if (!full)
                add = false;

            if (add)
            {
                int type = 17;// kind_to_sem_lsp(info.kind);


                if (start_l == -1)
                {
                    start_l = cast(int)s.line;
                    start_c = cast(int)s.character;
                }
                else // relative
                {

                    start_l = cast(int)s.line - start_l;
                    if (start_l != 0)
                        start_c = cast(int) s.character;
                    else
                        start_c = cast(int)s.character - start_c;

                }

                LINFO("{} {} {}:{} -d-> {}:{}", info.name, info.range[0], s.line, s.character, start_l, start_c);


                json.add_item_to_array(root, json.create_number(start_l));
                json.add_item_to_array(root, json.create_number(start_c));

                json.add_item_to_array(root, json.create_number(info.name.length)); // length
                json.add_item_to_array(root, json.create_number(type)); // type
                json.add_item_to_array(root, json.create_number(1)); // mod
            }

            foreach(c; info.children)
            {
                add_info(&c);
            }
        }
        foreach(sym; symbols)
        {
            add_info(&sym);
        }

        LINFO("{}", printJsonStr(obj));
        lsp_send_response(id, obj);
    }

}

int kind_to_sem_lsp(ubyte k)
{
    switch(k)
    {
        case 'c': // class name
            return 2;
        case 'i': // interface name
            return 4;
        case 's': // struct name
        case 'u': // union name
            return 5;
        case 'a': // array
        case 'A': // associative array
        case 'v': // variable name
            return 8;
        case 'm': // member variable
            return 8;
        case 'e': // enum member
            return 8;
        case 'k': // keyword
            return 15;
        case 'f': // function
            return 12;
        case 'F': // UFCS function acts like a method
            return 12;
        case 'g': // enum name
            return 3;
        case 'P': // package name
        case 'M': // module name
            return 0;
        case 'l': // alias name
            return 8;
        case 't': // template name
        case 'T': // mixin template name
            return 12;
        case 'h': // template type parameter
        case 'p': // template variadic parameter
            return 1;
        default:
            return 8;
    }
}
