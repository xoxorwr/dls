module dls.workspace_symbols;

import mem = rt.memz;
import rt.json;

import core.stdc.string;

import dls.main;
import dls.io;
import dls.dcd;

/**
 * Answers `workspace/symbol`. Scoped to the project's own import paths
 * ('g_import_paths', from dls.json) - see 'ModuleCache.getWorkspaceSymbols'
 * and 'dcd_workspace_symbols' for why: scanning the compiler's stdlib import
 * paths too would force-parse phobos/druntime into a cache that never
 * evicts anything.
 */
void lsp_workspace_symbol(int id, JsonNode* params_json) {
    auto allocator = arena.allocator();

    char* query = json_string_item(params_json, "query");

    if (query == null || strlen(query) == 0) {
        lsp_send_response(id, json.create_array());
        return;
    }

    auto results = dcd_workspace_symbols(cast(string) query[0 .. strlen(query)], g_import_paths, 100);

    auto root = json.create_array();

    string lastFile = null;
    char* lastUri = null;

    foreach(sym; results)
    {
        if (sym.file != lastFile)
        {
            lastFile = sym.file;

            char[] uriBuf = allocator.alloc!(char)(sym.file.length + 8);
            memcpy(uriBuf.ptr, "file://".ptr, 7);
            memcpy(uriBuf.ptr + 7, sym.file.ptr, sym.file.length);
            uriBuf[sym.file.length + 7] = '\0';
            lastUri = uriBuf.ptr;
        }

        Position p;
        p.line = sym.line;
        p.character = sym.character;

        auto item = json.create_object();
        json.add_string_to_object(item, "name", mem.dupe_add_sentinel(allocator, sym.name).ptr);
        json.add_number_to_object(item, "kind", kind_to_lsp(sym.kind));

        auto location = json.add_object_to_object(item, "location");
        json.add_string_to_object(location, "uri", lastUri);
        create_range(location, "range", p, p);

        json.add_item_to_array(root, item);
    }

    lsp_send_response(id, root);
}
