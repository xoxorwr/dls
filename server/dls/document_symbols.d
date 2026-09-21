module dls.document_symbols;

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



void lsp_document_symbol(int id, cjson.cJSON* params_json) {
    auto allocator = arena.allocator();
    auto text_document_json = cjson.cJSON_GetObjectItem(params_json, "textDocument");
    auto uri_json = cjson.cJSON_GetObjectItem(text_document_json, "uri");
    char* uri = cjson.cJSON_GetStringValue(uri_json);

    if (uri == null) {
        LWARN("documentSymbol without a uri");
        lsp_send_response(id, cjson.cJSON_CreateArray());
        return;
    }
    auto buffer = get_buffer(uri);
    if (buffer.content == null) {
        lsp_send_response(id, cjson.cJSON_CreateArray());
        return;
    }

    auto it = cast(string) buffer.content[0..strlen(buffer.content)];

    auto symbols = dcd_document_symbols(uri, buffer.content);

    auto root = cjson.cJSON_CreateArray();

    void add_info(DSymbolInfo* info, cjson.cJSON* array)
    {
        auto jsym = create_jsym(it, info, allocator);
        cjson.cJSON_AddItemToArray(array, jsym);

        if (info.children.length > 0)
        {
            auto jchildren = cjson.cJSON_AddArrayToObject(jsym, "children");

            foreach(c; info.children)
            {
                add_info(&c, jchildren);
            }
        }
    }

    foreach(sym; symbols)
    {
        add_info(&sym, root);
    }
    //foreach(sym; symbols)
    //{
    //    auto jsym = create_jsym(it, &sym, allocator);

    //    if (sym.children.length > 0)
    //    {
    //        auto jchildren = cjson.cJSON_AddArrayToObject(jsym, "children");
    //        foreach(csym; sym.children)
    //        {
    //            auto jc = create_jsym(it, &csym, allocator);
    //            cjson.cJSON_AddItemToArray(jchildren, jc);
    //        }
    //    }

    //    cjson.cJSON_AddItemToArray(root, jsym);
    //}

    lsp_send_response(id, root);
}


cjson.cJSON* create_jsym(string it, DSymbolInfo* sym, mem.Allocator allocator)
{
    auto item = cjson.cJSON_CreateObject();
    cjson.cJSON_AddStringToObject(item, "name", sym.name.length == 0 ? "<empty>".ptr : mem.dupe_add_sentinel(allocator, sym.name).ptr);

    int lspKind = kind_to_lsp(sym.kind);

    cjson.cJSON_AddNumberToObject(item, "kind", lspKind);

    auto s = bytesToPosition(it, sym.range[0]);
    auto e = bytesToPosition(it, sym.range[1]);
    {

        create_range(item, "range", s, e);
    }

    {
        auto range = cjson.cJSON_AddObjectToObject(item, "selectionRange");
        auto start = cjson.cJSON_AddObjectToObject(range, "start");
        auto end = cjson.cJSON_AddObjectToObject(range, "end");
        cjson.cJSON_AddNumberToObject(start, "line", s.line);
        cjson.cJSON_AddNumberToObject(start, "character", s.character);
        cjson.cJSON_AddNumberToObject(end, "line", e.line);
        cjson.cJSON_AddNumberToObject(end, "character", e.character);
        create_range(item, "selectionRange", s, e);
    }
    return item;
}
