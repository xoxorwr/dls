module dls.signature_help;

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

void lsp_send_empty_signature_help(int id) {
    auto obj = cjson.cJSON_CreateObject();
    cjson.cJSON_AddArrayToObject(obj, "signatures");
    cjson.cJSON_AddNumberToObject(obj, "activeSignature", 0);
    cjson.cJSON_AddNumberToObject(obj, "activeParameter", 0);
    lsp_send_response(id, obj);
}

void lsp_signature_help(int id, cjson.cJSON * params_json) {
    auto allocator = arena.allocator();
    auto document = lsp_parse_document(params_json);

    if (document.uri == null) {
        lsp_send_empty_signature_help(id);
        return;
    }

    auto buffer = get_buffer(document.uri);

    if (buffer.content == null) {
        lsp_send_empty_signature_help(id);
        return;
    }

    auto it = cast(string) buffer.content[0..strlen(buffer.content)];
    auto pos = positionToBytes(it, document.line, document.character);

    // Call DCD to get the call tips/signatures at the current position
    auto dcdResponse = dcd_get_signature(document.uri, buffer.content, pos);

    auto obj = cjson.cJSON_CreateObject();
    auto signatures = cjson.cJSON_AddArrayToObject(obj, "signatures");

    // DCD usually returns multiple overloads
    for (int i = 0; i < dcdResponse.signatures.length; i++) {
        auto dcdSig = &dcdResponse.signatures[i];

        auto sigItem = cjson.cJSON_CreateObject();

        // The 'label' is the full function signature string
        // e.g., "void myFunc(int a, string b)"
        cjson.cJSON_AddStringToObject(sigItem, "label", mem.dupe_add_sentinel(allocator, dcdSig.label).ptr);

        // Add parameter information so the editor knows where to highlight
        auto parameters = cjson.cJSON_AddArrayToObject(sigItem, "parameters");
        for (int j = 0; j < dcdSig.parameters.length; j++) {
            auto paramItem = cjson.cJSON_CreateObject();
            // In LSP, this label can be the exact substring within the main label
            cjson.cJSON_AddStringToObject(paramItem, "label", mem.dupe_add_sentinel(allocator, dcdSig.parameters[j].label).ptr);
            cjson.cJSON_AddItemToArray(parameters, paramItem);
        }

        if (dcdSig.documentation.length > 0) {
            auto docObj = cjson.cJSON_AddObjectToObject(sigItem, "documentation");
            cjson.cJSON_AddStringToObject(docObj, "kind", "markdown");
            cjson.cJSON_AddStringToObject(docObj, "value", mem.dupe_add_sentinel(allocator, dcdSig.documentation).ptr);
        }

        cjson.cJSON_AddItemToArray(signatures, sigItem);
    }

    // Determine which parameter is currently active (0-indexed)
    // DCD response often provides the 'activeParameter' based on comma counting
    cjson.cJSON_AddNumberToObject(obj, "activeSignature", 0);
    cjson.cJSON_AddNumberToObject(obj, "activeParameter", dcdResponse.activeParameter);

    lsp_send_response(id, obj);
}
