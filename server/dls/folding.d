module dls.folding;


import rt.dbg;
import rt.json;

import dls.main;
import dls.io;
import dls.dcd;


/**
 * The `textDocument/foldingRange` handler.
 *
 * Without the capability the client has no idea where a block begins and
 * ends, so a brace-folding editor falls back to indentation: it starts a
 * region at the line holding `{` and ends it at the first line indented no
 * further.  A label (`end:`) sits at column zero - the statements around it do
 * not - so the function's fold stops there instead of at the closing brace.
 *
 * The ranges themselves come from DCD (`dcd_folding_ranges`): the server only
 * turns them into the protocol's objects.
 */
void lsp_folding_range(int id, JsonNode* params_json) {
    auto text_document_json = json.get_object_item(params_json, "textDocument");
    char* uri = json_string_item(text_document_json, "uri");
    if (uri == null) {
        LWARN("foldingRange without a uri");
        lsp_send_response(id, json.create_array());
        return;
    }

    auto buffer = get_buffer(uri);
    if (buffer.content == null) {
        LWARN("foldingRange for an unopened document: {}", uri);
        lsp_send_response(id, json.create_array());
        return;
    }

    auto ranges = dcd_folding_ranges(uri, buffer.content);

    auto array = json.create_array();
    foreach (range; ranges) {
        auto item = json.create_object();
        json.add_number_to_object(item, "startLine", cast(double) range.startLine);
        json.add_number_to_object(item, "endLine", cast(double) range.endLine);
        if (range.kind !is null)
            json.add_string_to_object(item, "kind", range.kind);
        json.add_item_to_array(array, item);
    }

    LWARN("folding ranges: {}", ranges.length);
    lsp_send_response(id, array);
}
