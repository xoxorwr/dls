module dls.unused_diagnostics;

import rt.dbg;
import mem = rt.memz;
import rt.json;

import core.stdc.string;

import dls.main;
import dls.io;
import dls.dcd;

/**
 * Diagnostics for unused imports and unused parameters, from
 * `dcd_unused_symbols` (cached per buffer - see `document_unused_symbols`).
 *
 * Each carries a `code` ("unused-import"/"unused-parameter") and, for an
 * import, a `data` object the remove-import code action reads back to build
 * its edit - so `textDocument/codeAction` needs no analysis of its own, only
 * the diagnostics the client already has.
 */
void lint_unused_symbols(BUFFER buffer, JsonNode* diagnostics) {
    auto index = find_buffer_index(buffer.uri);
    if (index < 0)
        return; // closed between being scheduled and running - nothing to do

    auto text = cast(string) buffer.content[0 .. strlen(buffer.content)];
    foreach (u; document_unused_symbols(buffers[index])) {
        auto start = bytesToPosition(text, u.start);
        auto end = bytesToPosition(text, u.start + u.length);

        auto diagnostic = json.create_object();
        create_range(diagnostic, "range", start, end);
        json.add_number_to_object(diagnostic, "severity", 4); // Hint
        json.add_string_to_object(diagnostic, "source", "dls");
        auto tags = json.add_array_to_object(diagnostic, "tags");
        json.add_item_to_array(tags, json.create_number(1)); // Unnecessary

        if (u.kind == DUnusedKind.import_) {
            json.add_string_to_object(diagnostic, "code", "unused-import");
            json.add_string_to_object(diagnostic, "message",
                make_cstring(arena.allocator(), "unused import '" ~ u.name ~ "'"));
            auto data = json.add_object_to_object(diagnostic, "data");
            json.add_number_to_object(data, "removeStart", u.removeStart);
            json.add_number_to_object(data, "removeLength", u.removeLength);
            json.add_string_to_object(data, "name", make_cstring(arena.allocator(), u.name));
        } else {
            json.add_string_to_object(diagnostic, "code", "unused-parameter");
            json.add_string_to_object(diagnostic, "message",
                make_cstring(arena.allocator(), "unused parameter '" ~ u.name ~ "'"));
        }

        json.add_item_to_array(diagnostics, diagnostic);
    }
}

/// Whether the unused-symbol list cached in 'buffer' is the one a lint pass
/// gets now (mirrors 'semantic_tokens_current' in semantic_tokens.d).
bool unused_symbols_current(ref const BUFFER buffer) {
    return buffer.unused_symbols_valid
        && buffer.unused_symbols_modules == g_module_cache_generation;
}

/**
 * The unused imports/parameters of 'buffer', computed when its text or the
 * module cache changed since they last were.  The result belongs to the
 * buffer.
 *
 * 'dcd_unused_symbols' returns GC memory, but the buffer table (and what it
 * caches) is owned by 'heap_allocator' - a malloc-based allocator, not the
 * GC - so each entry is copied across rather than stored as DCD returned it
 * (matches how project-wide config strings are handled: copied into
 * 'heap_allocator' rather than kept as GC references inside malloc'd state).
 */
const(DUnusedSymbol)[] document_unused_symbols(ref BUFFER buffer) {
    if (unused_symbols_current(buffer))
        return buffer.unused_symbols;

    drop_unused_symbols(heap_allocator, buffer);
    auto found = dcd_unused_symbols(buffer.uri, buffer.content);
    auto copy = heap_allocator.alloc!DUnusedSymbol(found.length);
    if (copy.length == found.length) {
        foreach (i, ref s; found) {
            copy[i] = s;
            auto name = heap_allocator.alloc!char(s.name.length);
            if (name.length == s.name.length) {
                name[] = s.name[];
                copy[i].name = cast(string) name;
            } else {
                copy[i].name = null;
            }
        }
        buffer.unused_symbols = copy;
    } else {
        LERRO("out of memory caching {} unused symbols", found.length);
        buffer.unused_symbols = null;
    }
    buffer.unused_symbols_modules = g_module_cache_generation;
    buffer.unused_symbols_valid = true;
    return buffer.unused_symbols;
}
