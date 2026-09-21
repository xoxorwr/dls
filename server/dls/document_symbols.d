module dls.document_symbols;

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



void lsp_document_symbol(int id, JsonNode* params_json) {
    auto allocator = arena.allocator();
    auto text_document_json = json.get_object_item(params_json, "textDocument");
    char* uri = json_string_item(text_document_json, "uri");

    if (uri == null) {
        LWARN("documentSymbol without a uri");
        lsp_send_response(id, json.create_array());
        return;
    }
    auto buffer = get_buffer(uri);
    if (buffer.content == null) {
        lsp_send_response(id, json.create_array());
        return;
    }

    auto it = cast(string) buffer.content[0..strlen(buffer.content)];

    auto symbols = dcd_document_symbols(uri, buffer.content);

    auto root = json.create_array();

    void add_info(DSymbolInfo* info, JsonNode* array)
    {
        auto jsym = create_jsym(it, info, allocator);
        json.add_item_to_array(array, jsym);

        if (info.children.length > 0)
        {
            auto jchildren = json.add_array_to_object(jsym, "children");

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
    //        auto jchildren = json.add_array_to_object(jsym, "children");
    //        foreach(csym; sym.children)
    //        {
    //            auto jc = create_jsym(it, &csym, allocator);
    //            json.add_item_to_array(jchildren, jc);
    //        }
    //    }

    //    json.add_item_to_array(root, jsym);
    //}

    lsp_send_response(id, root);
}


JsonNode* create_jsym(string it, DSymbolInfo* sym, mem.Allocator allocator)
{
    auto item = json.create_object();
    json.add_string_to_object(item, "name", sym.name.length == 0 ? "<empty>".ptr : mem.dupe_add_sentinel(allocator, sym.name).ptr);

    int lspKind = kind_to_lsp(sym.kind);

    json.add_number_to_object(item, "kind", lspKind);

    auto s = bytesToPosition(it, sym.range[0]);
    auto e = bytesToPosition(it, sym.range[1]);
    {

        create_range(item, "range", s, e);
    }

    {
        auto range = json.add_object_to_object(item, "selectionRange");
        auto start = json.add_object_to_object(range, "start");
        auto end = json.add_object_to_object(range, "end");
        json.add_number_to_object(start, "line", s.line);
        json.add_number_to_object(start, "character", s.character);
        json.add_number_to_object(end, "line", e.line);
        json.add_number_to_object(end, "character", e.character);
        create_range(item, "selectionRange", s, e);
    }
    return item;
}
