module dls.code_action;

import rt.dbg;
import rt.json;

import core.stdc.stdio;
import core.stdc.string;

import dls.main;
import dls.io;

/**
 * The `textDocument/codeAction` handler: quickfixes to remove an unused
 * import.
 *
 * Nothing is re-analysed here - `lint_unused_symbols` (unused_diagnostics.d)
 * already put everything a fix needs on the diagnostic itself, in `data`
 * (`removeStart`/`removeLength`/`name`), and the client hands those
 * diagnostics straight back in `context.diagnostics`.  A diagnostic with any
 * other `code` (unused parameters included) gets nothing offered.
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

    lsp_send_response(id, actions);
}
