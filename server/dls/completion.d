module dls.complete;

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

JsonNode* empty_completion_result() {
    auto obj = json.create_object();
    json.add_bool_to_object(obj, "isIncomplete", false);
    json.add_array_to_object(obj, "items");
    return obj;
}

void lsp_completion(int id, JsonNode * params_json) {
    auto allocator = arena.allocator();
    auto document = lsp_parse_document(params_json);

    if (document.uri == null) {
        lsp_send_response(id, empty_completion_result());
        return;
    }

    auto buffer = get_buffer(document.uri);

    if (buffer.content == null) {
        lsp_send_response(id, empty_completion_result());
        return;
    }

    auto it = cast(string) buffer.content[0..strlen(buffer.content)];
    auto pos = positionToBytes(it, document.line, document.character);
    AutocompleteResponse dcdResponse;

    {
    	mixin BENCH!("DCD_COMPLETE");

    	dcdResponse = dcd_complete(document.uri, buffer.content, pos);
    }

    LWARN("completions: {}", dcdResponse.completions.length);

    mixin BENCH!("BUILD RESPONSE");

    auto obj = json.create_object();

    json.add_bool_to_object(obj, "isIncomplete", false);
    auto results = json.add_array_to_object(obj, "items");
    for (int i = 0; i < dcdResponse.completions.length; i++) {
        auto completion = &dcdResponse.completions[i];
        //LWARN("  identifier   :{}", completion.identifier);
        //LWARN("  kind         :{}", cast(char)completion.kind);
        //LWARN("  def          :{}", completion.definition);
        //LWARN("  path         :{}", completion.symbolFilePath);
        //LWARN("  doc          :{}", completion.documentation);
        //LWARN("  typeOf       :{}", completion.typeOf);


        string identifier = completion.identifier;
        char[] detail;
        char[] rtype;
        int lspKind = kind_to_lsp(completion.kind);

        string sortText;

        // kind


        // sort
        switch (completion.kind)
        {
        case 'P': // package name
        case 'M': // module name
        	sortText = "1_"; break;
        case 'v': // variable name
            sortText = "2_"; break;
        case 'm': // member variable
            sortText = "3_"; break;
        case 'f': // function
        case 'F': // UFCS function
            sortText = "4_"; break;
        case 'k': // keyword
        case 'e': // enum member
            sortText = "5_"; break;
        case 'c': // class name
        case 'i': // interface name
        case 's': // struct name
        case 'u': // union name
        case 'a': // array
        case 'A': // associative array
        case 'g': // enum name
        case 'l': // alias name
        case 't': // template name
        case 'T': // mixin template name
        case 'h': // template type parameter
        case 'p': // template variadic parameter
            sortText = "6_"; break;
        default:
            sortText = "9_"; break;
        }

        if (completion.kind == 'f')
        {
            LINFO("is fn");
            auto ok = split_alloc(allocator, completion.definition, " ");
            LINFO("> {}", ok.length);

            if (ok.length >= 2)
            {
                LINFO("{} -- {} -- {}", completion.definition, rtype, completion.typeOf);
                if(completion.typeOf.length == 0)
                {
                    rtype = cast(char[]) completion.typeOf[0 .. $];
                    detail = cast(char[]) completion.definition[identifier.length .. $];
                }
                else
                {
                    rtype = ok[0];
                    detail = cast(char[])completion.definition[rtype.length +1 + identifier.length .. $];
                }
            }
        }
        else if (completion.kind == 's' || completion.kind == 'c')
        {

        	//LWARN(">{} {}", identifier, completion.definition);
            int bracketI = mem.index_of(completion.definition, "{");
            int firstParenI = mem.index_of(completion.definition, "(");
            if (firstParenI > 0 && firstParenI < bracketI)
                detail = cast(char[]) completion.definition[firstParenI .. $];
        }
        else
        {
            int lastSpace = mem.last_index_of(completion.definition, " ");
            int firstParenI = -1;
            if (lastSpace > 0)
                firstParenI = mem.index_of(completion.definition[lastSpace .. $], "(");
            else
                firstParenI = mem.index_of(completion.definition, "(");

            LINFO("check: {} {}", lastSpace, firstParenI);
            if (firstParenI > 0)
                detail = cast(char[]) completion.definition[firstParenI .. $];
        }

        if (rtype.length == 0)
        {
            rtype = cast(char[]) completion.typeOf;
            if (completion.kind == 'k' || rtype.length == 0)
            {
                switch(completion.kind)
                {
                case 'c': rtype = cast(char[]) "class"; break;
                case 'i': rtype = cast(char[]) "interface"; break;
                case 's': rtype = cast(char[]) "struct"; break;
                case 'u': rtype = cast(char[]) "union"; break;
                case 'v': rtype = cast(char[]) "variable"; break;
                case 'm': rtype = cast(char[]) "member variable"; break;
                case 'k': rtype = cast(char[]) "keyword"; break;
                case 'f': rtype = cast(char[]) "function"; break;
                case 'g': rtype = cast(char[]) "enum"; break;
                case 'e': rtype = cast(char[]) "enum member"; break;
                case 'P': rtype = cast(char[]) "package"; break;
                case 'M': rtype = cast(char[]) "module"; break;
                case 'a': rtype = cast(char[]) "array"; break;
                case 'A': rtype = cast(char[]) "associative array"; break;
                case 'l': rtype = cast(char[]) "alias"; break;
                case 't': rtype = cast(char[]) "template"; break;
                case 'T': rtype = cast(char[]) "mixin template"; break;
                case 'h': rtype = cast(char[]) "T param"; break;
                default: break;
                }
            }
        }

        // HACK FOR SUBLIME TEXT
        // WHEN SEE . IN DETAIL, IT REFUSE TO PROCESS IT
        for(int c = 0; c < detail.length; c++)
        {
        	if (detail[c] == '.')
        	{
        		detail[c] = '_';
        	}
        }

        auto item = json.create_object();

        json.add_string_to_object(item, "label", mem.dupe_add_sentinel(allocator, completion.identifier).ptr);
        json.add_number_to_object(item, "kind", lspKind);
        json.add_string_to_object(item, "sortText", mem.dupe_add_sentinel(allocator, sortText).ptr);
        json.add_string_to_object(item, "filterText", mem.dupe_add_sentinel(allocator, completion.identifier).ptr);
        auto labelDetails = json.add_object_to_object(item, "labelDetails");

        json.add_string_to_object(labelDetails, "detail", detail.length == 0 ? "" :  mem.dupe_add_sentinel(allocator, detail).ptr);
        json.add_string_to_object(labelDetails, "description", rtype.length == 0 ? "" : mem.dupe_add_sentinel(allocator, rtype).ptr);

        json.add_item_to_array(results, item);

    }
    lsp_send_response(id, obj);
}
