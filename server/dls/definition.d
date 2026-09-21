module dls.definition;


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

void lsp_definition(int id, JsonNode * params_json) {
    //auto output = printJsonStr(params_json);
    //LINFO("{}", output);

    auto allocator = arena.allocator();

    auto doc = lsp_parse_document(params_json);

    if (doc.uri == null) {
        lsp_send_response(id, json.create_array());
        return;
    }

    auto buffer = get_buffer(doc.uri);
    if (buffer.content == null) {
        lsp_send_response(id, json.create_array());
        return;
    }

    auto it = cast(string) buffer.content[0..strlen(buffer.content)];
    auto pos = positionToBytes(it, doc.line, doc.character);

    auto locations = dcd_definition(doc.uri, buffer.content, pos);
    auto root = json.create_array();

    foreach(loc; locations)
    {
        auto item = json.create_object();

        Position p;

        // same file
        if (loc.path == "stdin")
        {
            json.add_string_to_object(item, "uri", doc.uri);
            p = bytesToPosition(it, loc.position);
        }
        // builtin stuff
        else if (loc.path == null || loc.path.length == 0)
        {
            continue;
        }
        // other file
        else
        {
            auto rawPath = mem.dupe_add_sentinel(allocator, loc.path);

            // Check if this path matches the current file
            bool isSameFile = false;
            if (strlen(doc.uri) > 7 && core.stdc.string.strcmp(doc.uri + 7, rawPath.ptr) == 0)
                isSameFile = true;

            if (isSameFile)
            {
                json.add_string_to_object(item, "uri", doc.uri);
                p = bytesToPosition(it, loc.position);
            }
            else
            {
                // Create file:// URI
                char[] uriBuf = allocator.alloc!(char)(loc.path.length + 8);
                memcpy(uriBuf.ptr, "file://".ptr, 7);
                memcpy(uriBuf.ptr + 7, loc.path.ptr, loc.path.length);
                uriBuf[loc.path.length + 7] = '\0';
                json.add_string_to_object(item, "uri", uriBuf.ptr);

                // Try to find if we have an open buffer for this file
                BUFFER bufferp;
                if (has_buffer(uriBuf.ptr))
                {
                    bufferp = get_buffer(uriBuf.ptr);
                }
                else
                {
                    bufferp = get_or_open_buffer(heap_allocator, rawPath.ptr);
                }

                if (bufferp.content == null) 
                {
                    LERRO("buffer empty at: {}", rawPath.ptr);
                    continue;
                }

                string itp = cast(string) bufferp.content[0 .. strlen(bufferp.content)];
                p = bytesToPosition(itp, loc.position);
            }
        }

        create_range(item, "range", p, p);

        json.add_item_to_array(root, item);
    }

    lsp_send_response(id, root);
}
