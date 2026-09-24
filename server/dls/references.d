module dls.references;

import mem = rt.memz;
import rt.json;

import core.stdc.string;

import dls.main;
import dls.io;
import dls.dcd;

/**
 * Answers `textDocument/references`. Scoped to the project's own import
 * paths ('g_import_paths', from dls.json), same as `workspace/symbol` -
 * see 'ModuleCache.getWorkspaceSymbols' and 'dcd_find_references' for why:
 * every candidate file has to be parsed to check what its matching-named
 * identifiers resolve to, and that eager scan must not reach into the
 * compiler's own stdlib import paths.
 */
void lsp_references(int id, JsonNode* params_json) {
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

    auto context_json = json.get_object_item(params_json, "context");
    auto include_decl_json = json.get_object_item(context_json, "includeDeclaration");
    int includeDeclaration = json.is_true(include_decl_json) ? 1 : 0;

    auto results = dcd_find_references(doc.uri, buffer.content, pos, g_import_paths, includeDeclaration);

    auto root = json.create_array();

    foreach(loc; results)
    {
        auto rawPath = mem.dupe_add_sentinel(allocator, loc.file);

        Position p, e;

        bool isSameFile = strlen(doc.uri) > 7
            && core.stdc.string.strcmp(doc.uri + 7, rawPath.ptr) == 0;

        if (isSameFile)
        {
            p = bytesToPosition(it, loc.location);
            e = bytesToPosition(it, loc.location + loc.length);

            auto item = json.create_object();
            json.add_string_to_object(item, "uri", doc.uri);
            create_range(item, "range", p, e);
            json.add_item_to_array(root, item);
            continue;
        }

        char[] uriBuf = allocator.alloc!(char)(loc.file.length + 8);
        memcpy(uriBuf.ptr, "file://".ptr, 7);
        memcpy(uriBuf.ptr + 7, loc.file.ptr, loc.file.length);
        uriBuf[loc.file.length + 7] = '\0';

        BUFFER bufferp;
        if (has_buffer(uriBuf.ptr))
            bufferp = get_buffer(uriBuf.ptr);
        else
            bufferp = get_or_open_buffer(heap_allocator, rawPath.ptr);

        if (bufferp.content == null) continue;

        auto itp = cast(string) bufferp.content[0 .. strlen(bufferp.content)];
        p = bytesToPosition(itp, loc.location);
        e = bytesToPosition(itp, loc.location + loc.length);

        auto item = json.create_object();
        json.add_string_to_object(item, "uri", uriBuf.ptr);
        create_range(item, "range", p, e);
        json.add_item_to_array(root, item);
    }

    lsp_send_response(id, root);
}
