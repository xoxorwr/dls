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
 * indices, one per name (see `DSemanticTokenType` in dcd_templates'
 * `dll.d`); LSP wants five numbers per token, the position relative to the
 * previous token and the length in UTF-16 code units.
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
    auto index = find_buffer_index(uri);
    if (index < 0) {
        LWARN("semanticTokens for an unopened document: {}", uri);
        lsp_send_response(id, empty_semantic_tokens());
        return;
    }

    // Tokens that would have to be computed for a text a queued change has
    // already replaced: the client re-asks after a ContentModified and keeps
    // showing the tokens it has until then.
    if (!semantic_tokens_current(buffers[index]) && change_queued(uri)) {
        LINFO("semanticTokens for '{}' superseded by a queued change", uri);
        lsp_send_error(id, CONTENT_MODIFIED, "the document changed");
        return;
    }

    auto obj = json.create_object();
    json.add_raw_to_object(obj, "data",
        format_uint_array(arena.allocator(), document_semantic_tokens(buffers[index])));
    lsp_send_response(id, obj);
}

/// Whether the tokens cached in 'buffer' are the ones a request gets now.
bool semantic_tokens_current(ref const BUFFER buffer) {
    return buffer.semantic_tokens_valid
        && buffer.semantic_tokens_modules == g_module_cache_generation;
}

/**
 * The encoded tokens of 'buffer', computed when its text or the module cache
 * changed since they last were.  The result belongs to the buffer.
 */
const(uint)[] document_semantic_tokens(ref BUFFER buffer) {
    if (semantic_tokens_current(buffer))
        return buffer.semantic_tokens;

    drop_semantic_tokens(heap_allocator, buffer);
    auto text = buffer.content[0 .. strlen(buffer.content)];
    auto tokens = dcd_semantic_tokens(buffer.uri, buffer.content);
    buffer.semantic_tokens = encode_semantic_tokens(heap_allocator, text, tokens);
    buffer.semantic_tokens_modules = g_module_cache_generation;
    buffer.semantic_tokens_valid = true;
    return buffer.semantic_tokens;
}

/**
 * The LSP encoding of 'tokens': five numbers per token - line delta, start
 * delta, UTF-16 length, type, modifiers.
 *
 * The tokens arrive sorted by offset, so the text is walked once, carrying
 * the line and the UTF-16 column along; a token that is out of order or runs
 * past the text ends the stream rather than being sent as a broken delta.
 * Names never span a line, so no token has to be split.
 */
uint[] encode_semantic_tokens(mem.Allocator alloc, const(char)[] text, DSemanticToken[] tokens) {
    auto data = alloc.alloc!uint(tokens.length * 5);
    if (data.length != tokens.length * 5) {
        LERRO("out of memory encoding {} semantic tokens", tokens.length);
        return null;
    }

    size_t count;
    size_t offset;        // bytes of 'text' walked so far
    uint line;            // the line 'offset' is on
    uint character;       // the UTF-16 column of 'offset'
    uint previous_line;
    uint previous_character;

    foreach (token; tokens) {
        if (token.start < offset || token.start + token.length > text.length)
            break;

        for (; offset < token.start; offset++) {
            immutable c = text[offset];
            if (c == '\n') {
                line++;
                character = 0;
            } else {
                // A UTF-16 unit per UTF-8 lead byte, two for a 4-byte one
                // (what 'countUTF16Length' counts).
                if (cast(byte) c >= -0x40) character++;
                if (c >= 0xf0) character++;
            }
        }

        auto out_ = data[count * 5 .. count * 5 + 5];
        out_[0] = line - previous_line;
        out_[1] = line == previous_line ? character - previous_character : character;
        out_[2] = cast(uint) countUTF16Length(text[token.start .. token.start + token.length]);
        out_[3] = token.type;
        out_[4] = token.modifiers;
        count++;

        previous_line = line;
        previous_character = character;
    }

    if (count == tokens.length)
        return data;

    // The result may be freed later, which takes the length it was allocated
    // with: a stream cut short gets its own, exact allocation.
    auto kept = alloc.alloc!uint(count * 5);
    if (kept.length == count * 5)
        kept[] = data[0 .. count * 5];
    alloc.free(data);
    return kept.length == count * 5 ? kept : null;
}

/// '[1,2,3]' as a null-terminated string - a JSON array written in one go
/// instead of a node per number.
char* format_uint_array(mem.Allocator alloc, const(uint)[] values) {
    // Ten digits and a comma per value, the brackets and the terminator.
    auto buffer = alloc.alloc!char(values.length * 11 + 3);
    if (buffer.length != values.length * 11 + 3) {
        LERRO("out of memory formatting {} numbers", values.length);
        return cast(char*) "[]".ptr;
    }

    size_t at;
    buffer[at++] = '[';
    foreach (i, uint value; values) {
        if (i > 0)
            buffer[at++] = ',';
        char[10] digits;
        size_t n;
        do {
            digits[n++] = cast(char) ('0' + value % 10);
            value /= 10;
        } while (value != 0);
        while (n > 0)
            buffer[at++] = digits[--n];
    }
    buffer[at++] = ']';
    buffer[at] = 0;
    return buffer.ptr;
}
