module dls.code_action;

import rt.dbg;
import rt.json;

import core.stdc.stdio;
import core.stdc.string;

import dls.main;
import dls.io;
import dls.dcd : DUnusedKind;
import dls.unused_diagnostics : document_unused_symbols;

/**
 * The `textDocument/codeAction` handler: quickfixes to remove an unused
 * import, plus - when the file has more than one - a bulk "remove all
 * unused imports" alongside them in the same lightbulb.
 *
 * The per-diagnostic fixes need no analysis of their own - `lint_unused_symbols`
 * (unused_diagnostics.d) already put everything a fix needs on the
 * diagnostic itself, in `data` (`removeStart`/`removeLength`/`name`), and the
 * client hands those diagnostics straight back in `context.diagnostics`. A
 * diagnostic with any other `code` (unused parameters included) gets nothing
 * offered.
 *
 * The bulk fix is not built from `context.diagnostics` though: a client
 * typically only sends the diagnostics that overlap the requested range (the
 * cursor line, usually), not every unused import in the file. It reads the
 * buffer's full cached list (`document_unused_symbols`) instead, so "remove
 * all" means all, regardless of where the lightbulb was opened from.
 */
void lsp_code_action(int id, JsonNode* params_json) {
    auto text_document_json = json.get_object_item(params_json, "textDocument");
    char* uri = json_string_item(text_document_json, "uri");
    if (uri == null) {
        LWARN("codeAction without a uri");
        lsp_send_response(id, json.create_array());
        return;
    }

    auto buffer = get_buffer(uri);
    if (buffer.content == null) {
        LWARN("codeAction for an unopened document: {}", uri);
        lsp_send_response(id, json.create_array());
        return;
    }
    auto text = cast(string) buffer.content[0 .. strlen(buffer.content)];

    auto context_json = json.get_object_item(params_json, "context");
    auto diagnostics_json = json.get_object_item(context_json, "diagnostics");

    auto actions = json.create_array();
    int size = json_is_array(diagnostics_json) ? json.get_array_size(diagnostics_json) : 0;
    for (int i = 0; i < size; i++) {
        auto diagnostic = json.get_array_item(diagnostics_json, i);
        char* code = json_string_item(diagnostic, "code");
        if (code == null || strcmp(code, "unused-import") != 0)
            continue;

        auto data = json.get_object_item(diagnostic, "data");
        auto remove_start_json = json.get_object_item(data, "removeStart");
        auto remove_length_json = json.get_object_item(data, "removeLength");
        if (!json_is_number(remove_start_json) || !json_is_number(remove_length_json))
            continue;
        size_t remove_start = cast(size_t) json.get_integer(remove_start_json);
        size_t remove_length = cast(size_t) json.get_integer(remove_length_json);
        if (remove_start + remove_length > text.length)
            continue; // the file moved on since this diagnostic was computed

        char* name = json_string_item(data, "name");

        auto action = json.create_object();
        char[128] title;
        int title_len = name != null
            ? snprintf(title.ptr, title.length, "Remove unused import '%s'", name)
            : snprintf(title.ptr, title.length, "Remove unused import");
        json.add_string_to_object(action, "title",
            title_len > 0 && cast(size_t) title_len < title.length ? title.ptr : cast(char*) "Remove unused import".ptr);
        json.add_string_to_object(action, "kind", "quickfix");

        auto edit = json.add_object_to_object(action, "edit");
        auto changes = json.add_object_to_object(edit, "changes");
        auto text_edits = json.add_array_to_object(changes, uri);
        auto text_edit = json.create_object();
        create_range(text_edit, "range",
            bytesToPosition(text, remove_start), bytesToPosition(text, remove_start + remove_length));
        json.add_string_to_object(text_edit, "newText", "");
        json.add_item_to_array(text_edits, text_edit);

        json.add_item_to_array(actions, action);
    }

    add_remove_all_unused_imports_action(actions, uri, text);

    lsp_send_response(id, actions);
}

/**
 * One byte range a "remove unused import" fix deletes.
 */
private struct RemovalRange {
    size_t start;
    size_t end;
}

/**
 * Appends a "Remove all unused imports" action to 'actions' when the file
 * has two or more, covering every one of them in a single edit.
 *
 * Two items in the same selective-import list (`import mod : a, b;`, both
 * unused) each carry a `removeStart`/`removeLength` computed as if it alone
 * were being removed, which - to also take the separating comma - makes
 * neighbouring items' ranges overlap.  That is fine one fix at a time (the
 * diagnostics are recomputed before the next one runs), but a single
 * WorkspaceEdit cannot contain overlapping TextEdits, so this sorts every
 * range and merges the ones that overlap (or touch) before emitting one
 * edit per merged range - always deleting exactly the union, so a shared
 * comma is removed once, not twice.
 */
private void add_remove_all_unused_imports_action(JsonNode* actions, const char* uri, string text) {
    import std.algorithm : sort, max;

    auto index = find_buffer_index(uri);
    if (index < 0)
        return;

    RemovalRange[] ranges;
    int count = 0;
    foreach (u; document_unused_symbols(buffers[index])) {
        if (u.kind != DUnusedKind.import_)
            continue;
        if (u.removeStart + u.removeLength > text.length)
            continue; // the file moved on since this was computed
        ranges ~= RemovalRange(u.removeStart, u.removeStart + u.removeLength);
        count++;
    }
    if (count < 2)
        return; // nothing to bulk - the single fix above already covers it

    ranges.sort!((a, b) => a.start < b.start);

    RemovalRange[] merged;
    foreach (r; ranges) {
        if (merged.length > 0 && r.start <= merged[$ - 1].end)
            merged[$ - 1].end = max(merged[$ - 1].end, r.end);
        else
            merged ~= r;
    }

    // A run reaching the last binding in its list (nothing but whitespace
    // between its end and the declaration's ';') needs to also take the
    // comma that used to separate it from whatever precedes it - the same
    // thing a lone last-item removal already does via its own
    // 'precedingComma' (dll.d's listItemRemoval), but that logic only ever
    // looked at one item at a time. Merging a removed run's raw ranges
    // together does not reproduce it: the run's start is wherever its
    // *first* item's own range began, which - unless that item happens to
    // be the last binding too - never reached backward past its own
    // separator, e.g. `keepFunc, aFunc, bFunc;` with aFunc and bFunc both
    // unused merges to remove "aFunc, bFunc" and would otherwise leave a
    // dangling "keepFunc, ;", which does not compile.
    foreach (ref r; merged) {
        size_t end = r.end;
        while (end < text.length && (text[end] == ' ' || text[end] == '\t'))
            end++;
        if (end >= text.length || text[end] != ';')
            continue;

        size_t start = r.start;
        while (start > 0 && (text[start - 1] == ' ' || text[start - 1] == '\t'))
            start--;
        if (start > 0 && text[start - 1] == ',')
            r.start = start - 1;
    }

    auto action = json.create_object();
    char[64] title;
    int title_len = snprintf(title.ptr, title.length, "Remove all unused imports (%d)", count);
    json.add_string_to_object(action, "title",
        title_len > 0 && cast(size_t) title_len < title.length
            ? title.ptr : cast(char*) "Remove all unused imports".ptr);
    json.add_string_to_object(action, "kind", "quickfix");

    auto edit = json.add_object_to_object(action, "edit");
    auto changes = json.add_object_to_object(edit, "changes");
    auto text_edits = json.add_array_to_object(changes, uri);
    foreach (r; merged) {
        auto text_edit = json.create_object();
        create_range(text_edit, "range", bytesToPosition(text, r.start), bytesToPosition(text, r.end));
        json.add_string_to_object(text_edit, "newText", "");
        json.add_item_to_array(text_edits, text_edit);
    }

    json.add_item_to_array(actions, action);
}
