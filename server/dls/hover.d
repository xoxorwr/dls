module dls.hover;


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

void lsp_hover(int id, JsonNode * params_json) {
    //auto output = printJsonStr(params_json);
    //LINFO("{}", output);

    auto allocator = arena.allocator();

    auto doc = lsp_parse_document(params_json);

    if (doc.uri == null) {
        auto empty = json.create_object();
        json.add_array_to_object(empty, "contents");
        lsp_send_response(id, empty);
        return;
    }

    auto buffer = get_buffer(doc.uri);
    if (buffer.content == null) {
        auto empty = json.create_object();
        json.add_array_to_object(empty, "contents");
        lsp_send_response(id, empty);
        return;
    }

    auto it = cast(string) buffer.content[0..strlen(buffer.content)];
    auto pos = positionToBytes(it, doc.line, doc.character);

    auto defs = dcd_hover(doc.uri, buffer.content, pos);


    auto obj = json.create_object();
    auto contents = json.add_array_to_object(obj, "contents");

    LWARN("hover: {}", defs.length);

    foreach(def; defs)
    {
        if (def.length == 0)
        {
            auto item = json.create_object();
            json.add_string_to_object(item, "value", "<empty>");
            json.add_string_to_object(item, "language", "d");

            json.add_item_to_array(contents, item);
        }
        else
        {
            auto value = mem.dupe_add_sentinel(allocator, def);
            auto item = json.create_object();
            json.add_string_to_object(item, "value", value.ptr);
            json.add_string_to_object(item, "language", "d");

            json.add_item_to_array(contents, item);
        }

    }

    lsp_send_response(id, obj);
}
