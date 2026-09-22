module dls.initialize;

import rt.dbg;
import rt.json;

import core.stdc.stdio;
import core.stdc.stdlib;
import core.stdc.string;
import core.stdc.ctype;

import dls.main;




void lsp_initialize(int id, JsonNode* params_json) {
    auto result = json.create_object();

    //auto capabilities = json.add_object_to_object(result, "capabilities");
    //json.add_number_to_object(capabilities, "textDocumentSync", 1);
    //json.add_bool_to_object(capabilities, "hoverProvider", 1);
    //json.add_bool_to_object(capabilities, "definitionProvider", 1);
    //json.add_bool_to_object(capabilities, "documentSymbolProvider", 1);

    //auto serverInfo = json.add_object_to_object(result, "serverInfo");
    //json.add_string_to_object(serverInfo, "name", "dls");
    //json.add_string_to_object(serverInfo, "version", "0.0.1");


    auto capabilities = result.add_object("capabilities")
            //.add_number("textDocumentSync", 1)
            .add_bool("hoverProvider", 1)
            .add_bool("definitionProvider", 1)
            .add_bool("documentSymbolProvider", 1);


    auto sync = json.add_object_to_object(capabilities, "textDocumentSync");
    json.add_bool_to_object(sync, "openClose", 1);
    json.add_number_to_object(sync, "change", 1);
    auto saveOptions = json.add_object_to_object(sync, "save");
    json.add_bool_to_object(saveOptions, "includeText", 1);

    enable_semantic_tokens(capabilities);
    enable_completion(capabilities);
    enable_signature_help(capabilities);

    auto serverInfo = result.add_object("serverInfo")
            .add_string("name", "dls")
            .add_string("version", "0.0.1");

    lsp_send_response(id, result);

    lsp_initialize_client_capabilities(params_json);
}

/**
 * Remembers whether the client can register file watchers for the server.
 *
 * The capability is read from the initialize *params* ('capabilities' is the
 * client's ClientCapabilities there; the server's own capabilities use the
 * same name in the initialize *result*, which is what makes this easy to get
 * backwards).  The registration itself is sent from the 'initialized'
 * handler, once the client is ready for server requests.
 */
void lsp_initialize_client_capabilities(JsonNode* params_json) {
    auto clientCapabilities = json.get_object_item(params_json, "capabilities");
    auto workspace_json = json.get_object_item(clientCapabilities, "workspace");
    auto watched_json = json.get_object_item(workspace_json, "didChangeWatchedFiles");
    auto dynamic_json = json.get_object_item(watched_json, "dynamicRegistration");
    auto relative_json = json.get_object_item(watched_json, "relativePatternSupport");

    g_client_supports_watchers = json_is_true(dynamic_json) != 0;
    g_client_supports_relative_patterns = json_is_true(relative_json) != 0;

    if (!g_client_supports_watchers)
        LWARN("client can't register file watchers: modules changed outside the editor are only picked up on save");
}

/// Registration ids the file watchers are registered and unregistered under.
enum WATCH_CONFIG_ID = "dls-watch-config";
enum WATCH_IMPORT_PATHS_ID = "dls-watch-import-paths";

/// Whether the import path registration is currently in place: a workspace
/// with no import paths never registers one, and unregistering something the
/// client was never asked for is a protocol error.
bool g_import_path_watchers_registered = false;

/**
 * Asks the client to report files this server cares about through
 * 'workspace/didChangeWatchedFiles': a generator writing a module, an edit
 * made in another program, and changes to the configuration itself (see
 * 'apply_dls_json').  Two registrations, because they have different
 * lifetimes: the configuration file never moves, while the import paths are
 * re-registered whenever it changes them.
 */
void register_file_watcher() {
    if (!g_client_supports_watchers)
        return;

    register_config_watcher();
    register_import_path_watchers();
}

/// The configuration file at the workspace root, watched so that editing it -
/// or creating it where there was none - takes effect without a restart.
void register_config_watcher() {
    if (g_root_path[0] == 0)
        return;

    auto params = json.create_object();
    auto registrations = json.add_array_to_object(params, "registrations");
    auto registration = json.create_object();
    json.add_string_to_object(registration, "id", WATCH_CONFIG_ID);
    json.add_string_to_object(registration, "method", "workspace/didChangeWatchedFiles");

    auto registerOptions = json.add_object_to_object(registration, "registerOptions");
    auto watchers = json.add_array_to_object(registerOptions, "watchers");
    auto watcher = json.create_object();
    add_watcher(watcher, strip_trailing_separator(g_root_path[0 .. strlen(g_root_path.ptr)]), "dls.json");
    json.add_item_to_array(watchers, watcher);
    json.add_item_to_array(registrations, registration);

    LWARN("watching dls.json for configuration changes");
    lsp_send_request(g_next_request_id++, "client/registerCapability", params);
}

/**
 * D sources under the project's import paths.
 *
 * One watcher per import path, never the workspace root: a workspace is full
 * of D sources the project does not import (other roots of a multi-root
 * workspace, build directories), and every one of them would be a pointless
 * event.  An import path outside the workspace is only expressible as a
 * RelativePattern, so clients that don't support one get an absolute glob -
 * and nothing at all for the paths such a pattern cannot reach.
 */
void register_import_path_watchers() {
    if (!g_client_supports_watchers)
        return;

    // Nothing to anchor a watcher to, and nothing a completion could read;
    // the configuration watcher still runs, so a dls.json that shows up later
    // is picked up.
    if (g_import_paths.length == 0)
        return;

    auto params = json.create_object();
    auto registrations = json.add_array_to_object(params, "registrations");

    auto registration = json.create_object();
    json.add_string_to_object(registration, "id", WATCH_IMPORT_PATHS_ID);
    json.add_string_to_object(registration, "method", "workspace/didChangeWatchedFiles");

    auto registerOptions = json.add_object_to_object(registration, "registerOptions");
    auto watchers = json.add_array_to_object(registerOptions, "watchers");
    foreach (importPath; g_import_paths)
    {
        auto watcher = json.create_object();
        add_watcher(watcher, importPath, "**/*.d");
        json.add_item_to_array(watchers, watcher);
    }

    json.add_item_to_array(registrations, registration);

    LWARN("watching {} import path(s) for D sources", g_import_paths.length);
    lsp_send_request(g_next_request_id++, "client/registerCapability", params);
    g_import_path_watchers_registered = true;
}

/**
 * Replaces the import path watchers after a configuration change (the client
 * keeps a registration's watchers alive until it is unregistered, so
 * registering again with the same id would leave the old ones running).
 */
void refresh_import_path_watchers() {
    if (!g_client_supports_watchers)
        return;

    if (g_import_path_watchers_registered)
        unregister_watcher(WATCH_IMPORT_PATHS_ID);
    g_import_path_watchers_registered = false;
    register_import_path_watchers();
}

void unregister_watcher(const(char)* id) {
    auto params = json.create_object();
    auto unregisterations = json.add_array_to_object(params, "unregisterations");
    auto unregistration = json.create_object();
    json.add_string_to_object(unregistration, "id", id);
    json.add_string_to_object(unregistration, "method", "workspace/didChangeWatchedFiles");
    json.add_item_to_array(unregisterations, unregistration);

    lsp_send_request(g_next_request_id++, "client/unregisterCapability", params);
}

/// Fills 'watcher' with the pattern for 'pattern' under 'base': a
/// RelativePattern when the client takes one (the only form that can anchor a
/// watcher outside the workspace), an absolute glob otherwise.
void add_watcher(JsonNode* watcher, const(char)[] base, const(char)[] pattern) {
    if (g_client_supports_relative_patterns)
    {
        auto globPattern = json.add_object_to_object(watcher, "globPattern");
        json.add_string_to_object(globPattern, "baseUri", make_directory_uri(arena.allocator(), base));
        json.add_string_to_object(globPattern, "pattern", make_cstring(arena.allocator(), pattern));
    }
    else
    {
        json.add_string_to_object(watcher, "globPattern",
            make_absolute_glob(arena.allocator(), base, pattern));
    }
}

void enable_completion(JsonNode* capabilities)
{
    auto completion = json.add_object_to_object(capabilities, "completionProvider");
    json.add_bool_to_object(completion, "resolveProvider", 0);

    const(char)*[6] tc = [ ".","=","/","*","+","-"];
    auto triggerCharacters = json.create_string_array(tc.ptr, tc.length);
    json.add_item_to_object(completion, "triggerCharacters", triggerCharacters);

    auto completionItem = json.add_object_to_object(completion, "completionItem");
    json.add_bool_to_object(completionItem, "labelDetailsSupport", 1);
}

void enable_signature_help(JsonNode* capabilities)
{
    // Initialize the signatureHelpProvider object
    auto signatureHelp = json.add_object_to_object(capabilities, "signatureHelpProvider");

    const(char)*[3] tc = ["(", "{", ","];
    auto triggerCharacters = json.create_string_array(tc.ptr, tc.length);
    json.add_item_to_object(signatureHelp, "triggerCharacters", triggerCharacters);

    const(char)*[1] rtc = [","];
    auto retriggerCharacters = json.create_string_array(rtc.ptr, rtc.length);
    json.add_item_to_object(signatureHelp, "retriggerCharacters", retriggerCharacters);
}

/**
 * Advertises the semantic token legend.
 *
 * The token type and modifier positions are what `DSemanticTokenType` and
 * `DSemanticTokenModifier` in `dcd_templates/src/dcd/server/dll.d` index into,
 * so the two lists have to stay in step.
 */
void enable_semantic_tokens(JsonNode* capabilities) {
    const(char*)[27] tok_types = [
        "namespace",       // 0
        "type",            // 1
        "class",           // 2
        "enum",            // 3
        "interface",       // 4
        "struct",          // 5
        "typeParameter",   // 6
        "parameter",       // 7
        "variable",        // 8
        "property",        // 9
        "enumMember",      // 10
        "event",           // 11
        "function",        // 12
        "method",          // 13
        "macro",           // 14
        "keyword",         // 15
        "modifier",        // 16
        "comment",         // 17
        "string",          // 18
        "number",          // 19
        "regexp",          // 20
        "operator",        // 21
        "decorator",       // 22
        /// non standard token type
        "errorTag",
        /// non standard token type
        "builtin",
        /// non standard token type
        "label",
        /// non standard token type
        "keywordLiteral",
    ];
    const(char*)[12] tok_mods = [
        "declaration",
        "definition",
        "readonly",
        "static",
        "deprecated",
        "abstract",
        "async",
        "modification",
        "documentation",
        "defaultLibrary",
        // non standard token modifiers
        "generic",
        "_",
    ];

    auto semanticTokensProvider = json.add_object_to_object(capabilities, "semanticTokensProvider");
    json.add_bool_to_object(semanticTokensProvider, "full", 1);
    json.add_bool_to_object(semanticTokensProvider, "range", 0);

    auto legend = json.add_object_to_object(semanticTokensProvider, "legend");
    auto types = json.create_string_array(tok_types.ptr, tok_types.length);
    auto mods = json.create_string_array(tok_mods.ptr, tok_mods.length);
    json.add_item_to_object(legend, "tokenTypes", types);
    json.add_item_to_object(legend, "tokenModifiers", mods);
}

JsonNode* add_object(JsonNode* it, const(char)* name)
{
    return json.add_object_to_object(it, name);
}
JsonNode* add_number(JsonNode* it, const(char)* name, int value)
{
    json.add_number_to_object(it, name, value);
    return it;
}
JsonNode* add_string(JsonNode* it, const(char)* name, const(char)* value)
{
    json.add_string_to_object(it, name, value);
    return it;
}
JsonNode* add_bool(JsonNode* it, const(char)* name, bool value)
{
    json.add_bool_to_object(it, name, value);
    return it;
}
