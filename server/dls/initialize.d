module dls.initialize;

import rt.dbg;
import c = cjson;

import core.stdc.stdio;
import core.stdc.stdlib;
import core.stdc.string;
import core.stdc.ctype;

import dls.main;




void lsp_initialize(int id, c.cJSON* params_json) {
    auto result = c.cJSON_CreateObject();

    //auto capabilities = c.cJSON_AddObjectToObject(result, "capabilities");
    //c.cJSON_AddNumberToObject(capabilities, "textDocumentSync", 1);
    //c.cJSON_AddBoolToObject(capabilities, "hoverProvider", 1);
    //c.cJSON_AddBoolToObject(capabilities, "definitionProvider", 1);
    //c.cJSON_AddBoolToObject(capabilities, "documentSymbolProvider", 1);

    //auto serverInfo = c.cJSON_AddObjectToObject(result, "serverInfo");
    //c.cJSON_AddStringToObject(serverInfo, "name", "dls");
    //c.cJSON_AddStringToObject(serverInfo, "version", "0.0.1");


    auto capabilities = result.add_object("capabilities")
            //.add_number("textDocumentSync", 1)
            .add_bool("hoverProvider", 1)
            .add_bool("definitionProvider", 1)
            .add_bool("documentSymbolProvider", 1);


    auto sync = c.cJSON_AddObjectToObject(capabilities, "textDocumentSync");
    c.cJSON_AddBoolToObject(sync, "openClose", 1);
    c.cJSON_AddNumberToObject(sync, "change", 1);
    auto saveOptions = c.cJSON_AddObjectToObject(sync, "save");
    c.cJSON_AddBoolToObject(saveOptions, "includeText", 1);

    //enable_semantice_tokens(capabilities);
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
void lsp_initialize_client_capabilities(c.cJSON* params_json) {
    auto clientCapabilities = c.cJSON_GetObjectItem(params_json, "capabilities");
    auto workspace_json = c.cJSON_GetObjectItem(clientCapabilities, "workspace");
    auto watched_json = c.cJSON_GetObjectItem(workspace_json, "didChangeWatchedFiles");
    auto dynamic_json = c.cJSON_GetObjectItem(watched_json, "dynamicRegistration");
    auto relative_json = c.cJSON_GetObjectItem(watched_json, "relativePatternSupport");

    g_client_supports_watchers = c.cJSON_IsTrue(dynamic_json) != 0;
    g_client_supports_relative_patterns = c.cJSON_IsTrue(relative_json) != 0;

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

    auto params = c.cJSON_CreateObject();
    auto registrations = c.cJSON_AddArrayToObject(params, "registrations");
    auto registration = c.cJSON_CreateObject();
    c.cJSON_AddStringToObject(registration, "id", WATCH_CONFIG_ID);
    c.cJSON_AddStringToObject(registration, "method", "workspace/didChangeWatchedFiles");

    auto registerOptions = c.cJSON_AddObjectToObject(registration, "registerOptions");
    auto watchers = c.cJSON_AddArrayToObject(registerOptions, "watchers");
    auto watcher = c.cJSON_CreateObject();
    add_watcher(watcher, strip_trailing_separator(g_root_path[0 .. strlen(g_root_path.ptr)]), "dls.json");
    c.cJSON_AddItemToArray(watchers, watcher);
    c.cJSON_AddItemToArray(registrations, registration);

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

    auto params = c.cJSON_CreateObject();
    auto registrations = c.cJSON_AddArrayToObject(params, "registrations");

    auto registration = c.cJSON_CreateObject();
    c.cJSON_AddStringToObject(registration, "id", WATCH_IMPORT_PATHS_ID);
    c.cJSON_AddStringToObject(registration, "method", "workspace/didChangeWatchedFiles");

    auto registerOptions = c.cJSON_AddObjectToObject(registration, "registerOptions");
    auto watchers = c.cJSON_AddArrayToObject(registerOptions, "watchers");
    foreach (importPath; g_import_paths)
    {
        auto watcher = c.cJSON_CreateObject();
        add_watcher(watcher, importPath, "**/*.d");
        c.cJSON_AddItemToArray(watchers, watcher);
    }

    c.cJSON_AddItemToArray(registrations, registration);

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
    auto params = c.cJSON_CreateObject();
    auto unregisterations = c.cJSON_AddArrayToObject(params, "unregisterations");
    auto unregistration = c.cJSON_CreateObject();
    c.cJSON_AddStringToObject(unregistration, "id", id);
    c.cJSON_AddStringToObject(unregistration, "method", "workspace/didChangeWatchedFiles");
    c.cJSON_AddItemToArray(unregisterations, unregistration);

    lsp_send_request(g_next_request_id++, "client/unregisterCapability", params);
}

/// Fills 'watcher' with the pattern for 'pattern' under 'base': a
/// RelativePattern when the client takes one (the only form that can anchor a
/// watcher outside the workspace), an absolute glob otherwise.
void add_watcher(c.cJSON* watcher, const(char)[] base, const(char)[] pattern) {
    if (g_client_supports_relative_patterns)
    {
        auto globPattern = c.cJSON_AddObjectToObject(watcher, "globPattern");
        c.cJSON_AddStringToObject(globPattern, "baseUri", make_directory_uri(arena.allocator(), base));
        c.cJSON_AddStringToObject(globPattern, "pattern", make_cstring(arena.allocator(), pattern));
    }
    else
    {
        c.cJSON_AddStringToObject(watcher, "globPattern",
            make_absolute_glob(arena.allocator(), base, pattern));
    }
}

void enable_completion(c.cJSON* capabilities)
{
    auto completion = c.cJSON_AddObjectToObject(capabilities, "completionProvider");
    c.cJSON_AddBoolToObject(completion, "resolveProvider", 0);

    const(char)*[6] tc = [ ".","=","/","*","+","-"];
    auto triggerCharacters = c.cJSON_CreateStringArray(tc.ptr, tc.length);
    c.cJSON_AddItemToObject(completion, "triggerCharacters", triggerCharacters);

    auto completionItem = c.cJSON_AddObjectToObject(completion, "completionItem");
    c.cJSON_AddBoolToObject(completionItem, "labelDetailsSupport", 1);
}

void enable_signature_help(c.cJSON* capabilities)
{
    // Initialize the signatureHelpProvider object
    auto signatureHelp = c.cJSON_AddObjectToObject(capabilities, "signatureHelpProvider");

    const(char)*[3] tc = ["(", "{", ","];
    auto triggerCharacters = c.cJSON_CreateStringArray(tc.ptr, tc.length);
    c.cJSON_AddItemToObject(signatureHelp, "triggerCharacters", triggerCharacters);

    const(char)*[1] rtc = [","];
    auto retriggerCharacters = c.cJSON_CreateStringArray(rtc.ptr, rtc.length);
    c.cJSON_AddItemToObject(signatureHelp, "retriggerCharacters", retriggerCharacters);
}

void enable_semantice_tokens(c.cJSON* capabilities) {
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

    auto semanticTokensProvider = c.cJSON_AddObjectToObject(capabilities, "semanticTokensProvider");
    c.cJSON_AddBoolToObject(semanticTokensProvider, "full", 1);
    c.cJSON_AddBoolToObject(semanticTokensProvider, "range", 0);

    auto legend = c.cJSON_AddObjectToObject(semanticTokensProvider, "legend");
    auto types = c.cJSON_CreateStringArray(tok_types.ptr, tok_types.length);
    auto mods = c.cJSON_CreateStringArray(tok_mods.ptr, tok_mods.length);
    c.cJSON_AddItemToObject(legend, "tokenTypes", types);
    c.cJSON_AddItemToObject(legend, "tokenModifiers", mods);
}

c.cJSON* add_object(c.cJSON* it, const(char)* name)
{
    return c.cJSON_AddObjectToObject(it, name);
}
c.cJSON* add_number(c.cJSON* it, const(char)* name, int value)
{
    c.cJSON_AddNumberToObject(it, name, value);
    return it;
}
c.cJSON* add_string(c.cJSON* it, const(char)* name, const(char)* value)
{
    c.cJSON_AddStringToObject(it, name, value);
    return it;
}
c.cJSON* add_bool(c.cJSON* it, const(char)* name, bool value)
{
    c.cJSON_AddBoolToObject(it, name, value);
    return it;
}
