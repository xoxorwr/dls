module dls.signature_help;

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

void lsp_send_empty_signature_help(int id) {
    auto obj = json.create_object();
    json.add_array_to_object(obj, "signatures");
    json.add_number_to_object(obj, "activeSignature", 0);
    json.add_number_to_object(obj, "activeParameter", 0);
    lsp_send_response(id, obj);
}

void lsp_signature_help(int id, JsonNode * params_json) {
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

    auto obj = json.create_object();
    auto signatures = json.add_array_to_object(obj, "signatures");

    // DCD usually returns multiple overloads
    for (int i = 0; i < dcdResponse.signatures.length; i++) {
        auto dcdSig = &dcdResponse.signatures[i];

        auto sigItem = json.create_object();

        // The 'label' is the full function signature string
        // e.g., "void myFunc(int a, string b)"
        json.add_string_to_object(sigItem, "label", mem.dupe_add_sentinel(allocator, dcdSig.label).ptr);

        // Add parameter information so the editor knows where to highlight
        auto parameters = json.add_array_to_object(sigItem, "parameters");
        for (int j = 0; j < dcdSig.parameters.length; j++) {
            auto dcdParam = &dcdSig.parameters[j];
            auto paramItem = json.create_object();

            // LSP's ParameterInformation.label is either a plain string -
            // which the client then has to find by searching the whole
            // signature label for that text - or an exact [start, end)
            // offset pair into it. A parameter name that also appears
            // elsewhere in the label (the return type, another parameter's
            // type, a single-letter template parameter like `T` in
            // `T get(T)(T data)`) makes that search ambiguous, so the
            // offsets - recorded while dcd rendered the signature line it
            // put in `label` - are used whenever they're available.
            if (dcdParam.labelStart >= 0 && dcdParam.labelEnd > dcdParam.labelStart) {
                auto label = json.add_array_to_object(paramItem, "label");
                json.add_item_to_array(label, json.create_number(dcdParam.labelStart));
                json.add_item_to_array(label, json.create_number(dcdParam.labelEnd));
            } else {
                json.add_string_to_object(paramItem, "label", mem.dupe_add_sentinel(allocator, dcdParam.label).ptr);
            }
            json.add_item_to_array(parameters, paramItem);
        }

        if (dcdSig.documentation.length > 0) {
            auto docObj = json.add_object_to_object(sigItem, "documentation");
            json.add_string_to_object(docObj, "kind", "markdown");
            json.add_string_to_object(docObj, "value", mem.dupe_add_sentinel(allocator, dcdSig.documentation).ptr);
        }

        json.add_item_to_array(signatures, sigItem);
    }

    // Determine which parameter is currently active (0-indexed)
    // DCD response often provides the 'activeParameter' based on comma counting
    json.add_number_to_object(obj, "activeSignature", 0);
    json.add_number_to_object(obj, "activeParameter", dcdResponse.activeParameter);

    lsp_send_response(id, obj);
}
