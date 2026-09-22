module dls.semantic_tokens;


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

JsonNode* empty_semantic_tokens() {
    auto obj = json.create_object();
    json.add_array_to_object(obj, "data");
    return obj;
}

/**
 * The `textDocument/semanticTokens` handlers.
 *
 * Only the whole document is advertised (`"range": false` in the legend), so
 * a range request answers with no tokens instead of leaving the client
 * waiting.
 *
 * The tokens come from DCD as byte ranges plus the legend's type and modifier
 * indices; LSP wants five numbers per token, the position relative to the
 * previous token and the length in UTF-16 code units, and it wants no token to
 * cross a line - so a block comment is split at its line ends here.
 */
void lsp_semantic_tokens(int id, JsonNode * params_json, bool full) {
    if (!full) {
        lsp_send_response(id, empty_semantic_tokens());
        return;
    }

    auto text_document_json = json.get_object_item(params_json, "textDocument");
    char* uri = json_string_item(text_document_json, "uri");
    if (uri == null) {
        LWARN("semanticTokens without a uri");
        lsp_send_response(id, empty_semantic_tokens());
        return;
    }
    auto buffer = get_buffer(uri);
    if (buffer.content == null) {
        LWARN("semanticTokens for an unopened document: {}", uri);
        lsp_send_response(id, empty_semantic_tokens());
        return;
    }

    auto it = cast(string) buffer.content[0..strlen(buffer.content)];
    auto tokens = dcd_semantic_tokens(uri, buffer.content);

    auto obj = json.create_object();
    auto data = json.add_array_to_object(obj, "data");

    size_t previous_line;
    size_t previous_character;
    bool has_previous;

    foreach (token; tokens) {
        immutable start = token.start;
        immutable end = token.start + token.length;
        if (end > it.length)
            continue;

        for (size_t part = start; part < end; ) {
            size_t line_end = part;
            while (line_end < end && it[line_end] != '\n')
                line_end++;

            auto position = bytesToPosition(it, part);
            int delta_line = cast(int) position.line - cast(int) previous_line;
            int delta_character = delta_line == 0
                ? cast(int) position.character - cast(int) previous_character
                : cast(int) position.character;

            // LSP wants the tokens in order; DCD hands them over that way, and
            // anything else is dropped rather than sent as a broken delta.
            if (has_previous && (delta_line < 0 || (delta_line == 0 && delta_character < 0)))
                break;

            if (line_end > part) {
                json.add_item_to_array(data, json.create_number(delta_line));
                json.add_item_to_array(data, json.create_number(delta_character));
                json.add_item_to_array(data, json.create_number(
                    countUTF16Length(it[part .. line_end])));
                json.add_item_to_array(data, json.create_number(token.type));
                json.add_item_to_array(data, json.create_number(token.modifiers));

                previous_line = position.line;
                previous_character = position.character;
                has_previous = true;
            }

            part = line_end < end ? line_end + 1 : line_end;
        }
    }

    LWARN("semantic tokens: {}", tokens.length);
    lsp_send_response(id, obj);
}
