module dls.semantic_tokens;


import rt.dbg;
import mem = rt.memz;
import cjson = cjson;
import rt.str;

import core.stdc.stdio;
import core.stdc.stdlib;
import core.stdc.string;
import core.stdc.ctype;

import dls.main;
import dls.io;
import dls.dcd;

void lsp_semantic_tokens(int id, cjson.cJSON * params_json, bool full) {
    char* output = cjson.cJSON_Print(params_json);
    LINFO("{} {}", full, output);

    return;

    auto allocator = arena.allocator();

    auto text_document_json = cjson.cJSON_GetObjectItem(params_json, "textDocument");
    auto uri_json = cjson.cJSON_GetObjectItem(text_document_json, "uri");
    char* uri = cjson.cJSON_GetStringValue(uri_json);

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

        auto obj = cjson.cJSON_CreateObject();
        auto root = cjson.cJSON_AddArrayToObject(obj, "data");
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


                cjson.cJSON_AddItemToArray(root, cjson.cJSON_CreateNumber(start_l));
                cjson.cJSON_AddItemToArray(root, cjson.cJSON_CreateNumber(start_c));

                cjson.cJSON_AddItemToArray(root, cjson.cJSON_CreateNumber(info.name.length)); // length
                cjson.cJSON_AddItemToArray(root, cjson.cJSON_CreateNumber(type)); // type
                cjson.cJSON_AddItemToArray(root, cjson.cJSON_CreateNumber(1)); // mod
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

        LINFO("{}", cjson.cJSON_Print(obj));
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