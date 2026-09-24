module dls.main;

import rt.dbg;
import str = rt.str;
import args = rt.args;
import mem = rt.memz;
import fs = rt.filesystem;
import rt.json;
import time = rt.time;

import core.stdc.stdio;
import core.stdc.stdlib;
import core.stdc.string;
import core.stdc.ctype;

import dls.io;
import dls.dcd;
import dls.initialize;
import dls.completion;
import dls.signature_help;
import dls.document_symbols;
import dls.workspace_symbols;
import dls.references;
import dls.definition;
import dls.hover;
import dls.semantic_tokens;
import dls.folding;
import dls.unused_diagnostics;
import dls.code_action;
import dls.transport;

__gshared:

mem.ArenaAllocator arena;

/// Nodes come from 'arena', so one 'dispose' per request reclaims them.
Json json;

/**
 * Allocator for data that outlives a request frame (document buffers, cached
 * paths, ...).  Held in a variable and passed down instead of using
 * 'mem.c_allocator' at each call site so the backing allocator can be swapped
 * in one place - e.g. for a tracking allocator while hunting memory leaks.
 * Request-scoped data belongs in 'arena' instead.
 */
mem.Allocator heap_allocator = mem.c_allocator;

char[] dbg;

struct Checker
{
	char[256] path = 0;
	char[4096] cmd = 0;
}
Checker[32] g_checkers;
int g_checkers_count;

char[256] g_root_path = 0;

/// Ids for the requests the server sends to the client.  They live in their
/// own space: a response carrying one of these is a client reply, not a
/// request to dispatch.
int g_next_request_id = 1;

/// Whether the client can handle a 'workspace/didChangeWatchedFiles'
/// registration (from its ClientCapabilities, see 'initialize.d').  The
/// registration itself is sent when the client reports 'initialized'.
bool g_client_supports_watchers = false;

/// Whether the client takes a RelativePattern ('baseUri' + 'pattern') as a
/// watcher's globPattern, which is what anchors a watcher at an import path
/// instead of at the workspace root.
bool g_client_supports_relative_patterns = false;

/// Whether the client takes a 'workspace/semanticTokens/refresh' request
/// (from its ClientCapabilities, see 'initialize.d').
bool g_client_supports_semantic_tokens_refresh = false;

/**
 * Bumped whenever DCD's module cache takes a text it did not hold before.
 *
 * A name in one document is classified through the modules it imports, so
 * results computed from a document's text alone (its cached semantic tokens)
 * are only good for the generation they were computed against.
 */
uint g_module_cache_generation = 1;

/**
 * Records that DCD's module cache changed.  With 'notify_client', also asks
 * the client to request the semantic tokens of its open documents again: the
 * text a client shows has not changed, so nothing else would make it ask.
 */
void module_cache_changed(bool notify_client) {
    g_module_cache_generation++;
    if (notify_client && g_client_supports_semantic_tokens_refresh)
        lsp_send_request(g_next_request_id++, "workspace/semanticTokens/refresh", null);
}

/// How long a 'didChange' waits with nothing further arriving before its
/// document is linted ('dls.json's "debounceMs", read in 'apply_dls_json' -
/// the VS Code extension already writes this key, matching its own
/// "Diagnostics idle delay" setting).  A save or an external write is not a
/// per-keystroke event and is linted immediately regardless of this.
int g_debounce_ms = 500;

/// Whether the built-in unused-import/unused-parameter check runs at all
/// ('dls.json's "unusedDiagnostics", default on).
bool g_unused_diagnostics_enabled = true;

/**
 * The project's import paths (absolute, without a trailing separator), as
 * registered with DCD.  They outlive the initialize request because the file
 * watcher is registered once per path and every incoming change is checked
 * against them: a module outside them is not something a completion can read,
 * so re-parsing it would only add latency.
 *
 * The compiler's default import paths are deliberately not here - watching
 * '/usr/include/dlang' would be pure noise.
 */
string[] g_import_paths;

extern(C) void main(int argc, char** argv) {

    LOG_FLAG.info = false;
    LOG_FLAG.warn = true;
    LOG_FLAG.erro = true;

    version (Windows) {
        // The protocol is a byte stream, but the C runtime opens the standard
        // streams in text mode, where every '\n' that is written becomes
        // "\r\n" and every "\r\n" that is read becomes '\n'.  The framing
        // already spells its own "\r\n", so a text-mode stdout puts
        // "Content-Length: N\r\r\n\r\r\n" on the wire - a client that looks
        // for the end of the header never finds it inside that, and stops
        // reading responses (the initialize response is the only one some of
        // them get through).  Reading would be thrown off the same way by a
        // payload that carries a raw '\r', and the length in the header counts
        // bytes, so both ends are set to binary.
        import core.stdc.stdio : _setmode, _O_BINARY;
        _setmode(0, _O_BINARY); // stdin
        _setmode(1, _O_BINARY); // stdout
    }

    import rt.crash_handler;
    rt_register_crash_handler();

    arena = mem.ArenaAllocator.create(heap_allocator);
    // Wraps the arena itself, so this survives each request's 'dispose'.
    json = Json.create(arena.allocator());
    // TODO: remove this
    //  - auto detect dmd/ldc
    //  - config for other folders

    //test
    //{
    //    auto request = json.parse(TEST_DIDOPEN);
    //    handle_request(request);
    //}
    //{
    //    auto request = json.parse(TEST_DIDCHANGE);
    //    handle_request(request);
    //}
    //{
    //    auto request = json.parse(TEST_COMPLETION);
    //    handle_request(request);
    //}
    //{
    //    return;
    //}

    transport_init(heap_allocator);
    while (true) {
        // Block until the client sends something, or - if a document's
        // debounce window is running - until that elapses instead, so the
        // deferred lint pass runs without a second thread.
        int timeout_ms = -1;
        auto due = soonest_lint_due();
        if (due >= 0) {
            auto now = time.get_time();
            timeout_ms = due > now ? cast(int)(due - now) : 0;
        }

        bool timed_out;
        auto message = next_message(arena.allocator(), timeout_ms, timed_out);
        if (timed_out) {
            run_due_lints();
            arena.dispose();
            continue;
        }
        if (message is null)
            break; // real EOF: the client is gone
        auto request = json.parse(message);
        if (!request) {
            LERRO("unnable to parse request");
            break;
        }
        handle_request(request);
        arena.dispose();
    }
}

/// The earliest 'lint_due_at_ms' among buffers with a pending debounce, or
/// -1 when none are pending (the main loop then waits for the client alone).
long soonest_lint_due() {
    long earliest = -1;
    foreach (i; 0 .. first_empty_buf) {
        if (!buffers[i].lint_pending) continue;
        if (earliest < 0 || buffers[i].lint_due_at_ms < earliest)
            earliest = buffers[i].lint_due_at_ms;
    }
    return earliest;
}

/// Runs the diagnostics dispatcher for every buffer whose debounce window has
/// elapsed.  'lsp_lint' clears each buffer's own 'lint_pending' as it runs,
/// so a buffer not yet due is left untouched and the main loop comes back for
/// it once its own deadline arrives.
void run_due_lints() {
    auto now = time.get_time();
    foreach (i; 0 .. first_empty_buf) {
        if (buffers[i].lint_pending && buffers[i].lint_due_at_ms <= now)
            lsp_lint(buffers[i]);
    }
}

void handle_request(JsonNode* request) {
    int id = -1;
    char* method;

    auto method_json = json.get_object_item(request, "method");
    if (!json_is_string(method_json)) {
        // A message without a method is a response to a request the server
        // sent (a file-watcher registration, say).  There is nothing to
        // dispatch here, and killing the process over it would cost the
        // editor every language feature until it restarts the server.
        LWARN("ignoring client response (no method)");
        return;
    }
    method = json.get_string(method_json);

    auto id_json = json.get_object_item(request, "id");
    if (json_is_number(id_json))
        id = json.get_integer(id_json);

    auto params_json = json.get_object_item(request, "params");

     LINFO("request id: {} -> method: {}", id, method);

    // A request the client has already given up on is not worth computing;
    // the lifecycle requests are always answered.
    if (id >= 0 && strcmp(method, "initialize") != 0 && strcmp(method, "shutdown") != 0
        && cancel_queued(id)) {
        LINFO("request {} was cancelled before it was handled", id);
        lsp_send_error(id, REQUEST_CANCELLED, "cancelled");
        return;
    }

    // RPC
    if (strcmp(method, "initialize") == 0) {
        lsp_initialize(id, params_json);
        lsp_initialize_params(id, params_json);
    } else if (strcmp(method, "initialized") == 0) {
        // The client is ready: ask it to report files that change outside the
        // editor (generated, formatted, written by another tool).
        register_file_watcher();
    } else if (strcmp(method, "shutdown") == 0) {
        lsp_shutdown(id);
    } else if (strcmp(method, "exit") == 0) {
        lsp_exit();
    } else if (strcmp(method, "textDocument/didOpen") == 0) {
        lsp_sync_open(params_json);
    } else if (strcmp(method, "textDocument/didChange") == 0) {
        lsp_sync_change(params_json);
    } else if (strcmp(method, "textDocument/didClose") == 0) {
        lsp_sync_close(params_json);
    }
    else if(strcmp(method, "textDocument/documentSymbol") == 0) {
      lsp_document_symbol(id, params_json);
    }
    else if(strcmp(method, "workspace/symbol") == 0) {
      lsp_workspace_symbol(id, params_json);
    }
    else if(strcmp(method, "textDocument/references") == 0) {
      lsp_references(id, params_json);
    }
    //else if(strcmp(method, "textDocument/definition") == 0) {
    //  lsp_goto_definition(id, params_json);
    //}
    else if (strcmp(method, "textDocument/completion") == 0) {
    	mixin BENCH!("lsp_completion");
        lsp_completion(id, params_json);
    }
    else if (strcmp(method, "textDocument/definition") == 0) {
        lsp_definition(id, params_json);
    }
    else if (strcmp(method, "textDocument/signatureHelp") == 0) {
        lsp_signature_help(id, params_json);
    }
    else if (strcmp(method, "textDocument/hover") == 0) {
        lsp_hover(id, params_json);
    }
    else if (strcmp(method, "textDocument/didSave") == 0) {
        lsp_did_save(params_json);
    }
    else if (strcmp(method, "workspace/didChangeWatchedFiles") == 0) {
        lsp_did_change_watched_files(params_json);
    }
    else if (strcmp(method, "textDocument/semanticTokens/full") == 0) {
        lsp_semantic_tokens(id, params_json, true);
    }
    else if (strcmp(method, "textDocument/semanticTokens/range") == 0) {
        lsp_semantic_tokens(id, params_json, false);
    }
    else if (strcmp(method, "textDocument/foldingRange") == 0) {
        lsp_folding_range(id, params_json);
    }
    else if (strcmp(method, "textDocument/codeAction") == 0) {
        lsp_code_action(id, params_json);
    }
    else if (strcmp(method, "$/cancelRequest") == 0) {
        // The request it names was answered already: the ones still queued
        // are looked for before they run ('cancel_queued').
    }
    else if (id < 0 && strncmp(method, "$/", 2) == 0) {
        // Notifications under '$/' are optional for a server to understand.
        LINFO("ignoring '{}'", method);
    }
    else
    {
        LWARN("request '{}' not handled", method);
        if (params_json)
            LWARN("{}", printJsonStr(params_json));
    }
}


/// JSON-RPC and LSP error codes the server answers with.
enum REQUEST_CANCELLED = -32800;
enum CONTENT_MODIFIED = -32801;

/// 'haystack' contains 'needle'.
bool contains(const(char)[] haystack, const(char)[] needle) {
    if (needle.length > haystack.length)
        return false;
    foreach (i; 0 .. haystack.length - needle.length + 1)
        if (haystack[i .. i + needle.length] == needle)
            return true;
    return false;
}

/**
 * Whether the client has already sent a '$/cancelRequest' for 'id' that is
 * still waiting behind the message being handled.
 *
 * Only the messages that spell the method are parsed, so looking is cheap
 * next to a queued 'didChange' carrying a whole file.
 */
bool cancel_queued(int id) {
    return queued_messages((const(char)[] body_) {
        if (!contains(body_, "$/cancelRequest"))
            return false;
        auto message = json.parse(body_);
        if (message == null || strcmp(json_string_item(message, "method"), "$/cancelRequest") != 0)
            return false;
        auto params_json = json.get_object_item(message, "params");
        return json_int(json.get_object_item(params_json, "id"), -1) == id;
    });
}

/**
 * Whether a message waiting behind the one being handled replaces the text of
 * 'uri' ('didChange') or closes it: an answer computed now would be about a
 * text the client has already moved past.
 */
bool change_queued(const(char)* uri) {
    return queued_messages((const(char)[] body_) {
        if (!contains(body_, "textDocument/didChange") && !contains(body_, "textDocument/didClose"))
            return false;
        auto message = json.parse(body_);
        if (message == null)
            return false;
        auto method = json_string_item(message, "method");
        if (method == null || (strcmp(method, "textDocument/didChange") != 0
                && strcmp(method, "textDocument/didClose") != 0))
            return false;
        auto text_document_json = json.get_object_item(
            json.get_object_item(message, "params"), "textDocument");
        auto other = json_string_item(text_document_json, "uri");
        return other != null && strcmp(other, uri) == 0;
    });
}

void lsp_initialize_params(int id, JsonNode* params_json)
{
    LINFO("lsp_initialize_params:\n{}", printJsonStr(params_json));
    dcd_init();
    auto rootPath_json = json.get_object_item(params_json, "rootPath");
    auto rootURI_json = json.get_object_item(params_json, "rootUri");

    bool foundRoot = false;


    if (!rootPath_json)
    {
        LWARN("no rootPath");
    }
    else {
        foundRoot = true;
    }

    if (!rootURI_json)
    {
        LWARN("no rootUri");
    }
    else {
        foundRoot = true;
    }

    if (!foundRoot) {
    	LWARN("no root!!");
    	return;
    }

	if (rootPath_json) {
	        auto rootPath = json_string(rootPath_json);
	        if (rootPath == null) {
	            LWARN("rootPath is not a string");
	            return;
	        }
	        auto L_r = strlen(rootPath);
	        if (L_r < g_root_path.length) {
	            mem.memcpy(g_root_path.ptr, rootPath, L_r);
	            g_root_path[L_r] = 0; // Null terminate
	        }
	    } else if (rootURI_json) {
	        auto rootPath = json_string(rootURI_json);
	        if (rootPath == null) {
	            LWARN("rootUri is not a string");
	            return;
	        }
	        auto L_r = strlen(rootPath);
	        // Strip "file://" (7 chars) and ensure it fits
	        if (L_r > 7 && (L_r - 7) < g_root_path.length) {
	            mem.memcpy(g_root_path.ptr, rootPath + 7, L_r - 7);
	            g_root_path[L_r - 7] = 0; // Null terminate
	        }
	    }



    LWARN("root path: {}", g_root_path);
    apply_dls_json();

    LWARN("lsp_initialize_params finish");
}

/// The compiler's own import paths: always registered, whatever dls.json says.
///
/// Auto-detected (inspired by serve-d):
///   1. the `-I` paths from the dmd.conf/sc.ini next to the compiler executable
///      (`%@P%` expands to that directory), or /etc/dmd.conf;
///   2. otherwise, walk up from the executable for a source tree (release:
///      `<root>/src/{druntime/import,phobos}`; dev: `<root>/druntime/import`;
///      LDC: `<root>/import`);
///   3. otherwise, the common system install locations.
/// A candidate only counts if it really provides `object.d`: e.g. a file named
/// `import` (ImageMagick ships `/usr/bin/import`) must not shadow the stdlib.
string[] default_import_paths()
{
    string[] found;
    auto exe = compiler_executable();
    if (exe.length)
    {
        auto dir = dir_name(exe);
        version (Windows)
            immutable conf_name = "sc.ini";
        else
            immutable conf_name = "dmd.conf";
        if (dir.length)
        {
            auto mark = found.length;
            foreach (c; dmd_conf_imports(dir ~ "/" ~ conf_name, dir))
                add_import_dir(found, c);
            // Distro packages put it in /etc instead of next to the binary.
            if (found.length == mark)
                foreach (c; dmd_conf_imports("/etc/dmd.conf", dir))
                    add_import_dir(found, c);
            if (found.length != mark && !has_object_file(found[mark .. $]))
                found.length = mark;

            if (!found.length)
            {
                auto root = dir;
                foreach (_; 0 .. 8)
                {
                    if (!root.length || root == "/" || root == ".")
                        break;
                    mark = found.length;
                    // dmd layout first; if it resolves, this is the toolchain.
                    add_import_dir(found, root ~ "/src/druntime/import");
                    add_import_dir(found, root ~ "/src/phobos");
                    add_import_dir(found, root ~ "/druntime/import");
                    add_import_dir(found, root ~ "/druntime/src");
                    add_import_dir(found, root ~ "/phobos"); // dev tree: sibling
                    if (found.length != mark && has_object_file(found[mark .. $]))
                        break;
                    // ldc layout (druntime + phobos in one `import` dir).
                    add_import_dir(found, root ~ "/import");
                    if (found.length != mark && has_object_file(found[mark .. $]))
                        break;
                    // Not a stdlib (e.g. a file named `import`): undo and keep up.
                    found.length = mark;
                    root = parent_dir(root);
                }
            }
        }
    }
    if (!found.length)
        foreach (c; system_import_paths())
            add_import_dir(found, c);
    return found;
}

/// The D compiler to look next to: $DMD/$DC first (setup-dlang and the dlang
/// installers export them), then the usual names on $PATH.
private string compiler_executable()
{
    foreach (name; ["DMD", "DC"])
    {
        auto value = getenv(name.ptr);
        if (value != null && value[0] != 0)
            return cast(string) value[0 .. strlen(value)].idup;
    }
    foreach (name; ["dmd", "ldmd2", "ldc2"])
        if (auto found = find_on_path(name))
            return found;
    return null;
}

/// The first file named 'name' found on $PATH, or null.
private string find_on_path(const(char)[] name)
{
    auto path = getenv("PATH");
    if (path == null)
        return null;
    auto list = path[0 .. strlen(path)];
    version (Windows)
        immutable separator = ';';
    else
        immutable separator = ':';

    size_t start = 0;
    while (start <= list.length)
    {
        size_t end = start;
        while (end < list.length && list[end] != separator)
            end++;
        auto dir = list[start .. end];
        if (dir.length)
        {
            auto candidate = dir ~ '/' ~ name;
            if (path_exists(candidate))
                return candidate.idup;
            version (Windows)
            {
                auto exe = candidate ~ ".exe";
                if (path_exists(exe))
                    return exe.idup;
            }
        }
        if (end >= list.length)
            break;
        start = end + 1;
    }
    return null;
}

/// The `-I` import paths from a dmd.conf/sc.ini, preferring [Environment64].
private string[] dmd_conf_imports(const(char)[] conf_path, const(char)[] compiler_dir)
{
    auto conf_z = conf_path.dup ~ '\0';
    auto file = fopen(conf_z.ptr, "rb");
    if (file == null)
        return null;

    char[4096] line;
    string any_flags, env64_flags;
    bool in64 = false;
    while (fgets(line.ptr, cast(int) line.length, file) != null)
    {
        auto text = str.strip(line[0 .. strlen(line.ptr)]);
        if (text == "[Environment64]")
        {
            in64 = true;
            continue;
        }
        if (text.length && text[0] == '[')
        {
            in64 = false;
            continue;
        }
        if (text.length > 7 && text[0 .. 7] == "DFLAGS=")
        {
            if (!any_flags.length)
                any_flags = text[7 .. $].idup;
            if (in64)
                env64_flags = text[7 .. $].idup;
        }
    }
    fclose(file);

    auto flags = env64_flags.length ? env64_flags : any_flags;
    if (!flags.length)
        return null;

    string[] out_;
    size_t i = 0;
    while (i < flags.length)
    {
        while (i < flags.length && (flags[i] == ' ' || flags[i] == '\t'))
            i++;
        size_t start = i;
        while (i < flags.length && flags[i] != ' ' && flags[i] != '\t')
            i++;
        auto token = flags[start .. i];
        if (token.length <= 2 || token[0] != '-' || token[1] != 'I')
            continue;
        auto p = token[2 .. $];
        if (p.length >= 2 && (p[0] == '"' || p[0] == '\'') && p[$ - 1] == p[0])
            p = p[1 .. $ - 1];
        auto expanded = expand_compiler_dir(p, compiler_dir);
        if (expanded.length)
            out_ ~= expanded;
    }
    return out_;
}

/// `%@P%` -> the compiler executable's directory (dmd's own expansion).
private string expand_compiler_dir(const(char)[] path, const(char)[] compiler_dir)
{
    enum marker = "%@P%";
    char[] out_;
    size_t i = 0;
    while (i < path.length)
    {
        if (i + marker.length <= path.length && path[i .. i + marker.length] == marker)
        {
            out_ ~= compiler_dir.dup;
            i += marker.length;
        }
        else
        {
            out_ ~= path[i];
            i++;
        }
    }
    return out_.idup;
}

/// Whether any candidate directory actually contains the core `object.d`.
private bool has_object_file(const(string)[] dirs)
{
    foreach (d; dirs)
        if (path_exists(d ~ "/object.d"))
            return true;
    return false;
}

/// Adds 'dir' if it is an existing directory that is not in 'found' yet.
private void add_import_dir(ref string[] found, const(char)[] dir)
{
    if (!dir.length || !path_exists(dir))
        return;
    foreach (existing; found)
        if (existing == dir)
            return;
    found ~= dir.idup;
}

/// Whether 'path' exists (directories included - `fopen` would not do here).
private bool path_exists(const(char)[] path)
{
    if (!path.length)
        return false;
    auto path_z = path.dup ~ '\0';
    version (Windows)
    {
        import core.sys.windows.windows : GetFileAttributesA, INVALID_FILE_ATTRIBUTES;
        return GetFileAttributesA(path_z.ptr) != INVALID_FILE_ATTRIBUTES;
    }
    else
    {
        import core.sys.posix.unistd : access, F_OK;
        return access(path_z.ptr, F_OK) == 0;
    }
}

/// 'path' without its last component, or null when there is none.
private string dir_name(const(char)[] path)
{
    size_t end = path.length;
    while (end > 0 && path[end - 1] != '/' && path[end - 1] != '\\')
        end--;
    return end == 0 ? null : path[0 .. end - 1].idup;
}

/// The directory holding 'path'.
private string parent_dir(const(char)[] path)
{
    auto trimmed = path;
    while (trimmed.length && (trimmed[$ - 1] == '/' || trimmed[$ - 1] == '\\'))
        trimmed = trimmed[0 .. $ - 1];
    size_t end = trimmed.length;
    while (end > 0 && trimmed[end - 1] != '/' && trimmed[end - 1] != '\\')
        end--;
    return end == 0 ? null : trimmed[0 .. end - 1].idup;
}

/// The usual locations a distro or installer drops the stdlib in.
private string[] system_import_paths()
{
    version (Windows)
        return [
            "c:/D/dmd2/src/druntime/import",
            "c:/D/dmd2/src/phobos",
        ];
    else version (OSX)
        return [
            "/Library/D/dmd/src/druntime/import",
            "/Library/D/dmd/src/phobos",
            "/usr/local/include/dmd/druntime/import",
            "/usr/local/include/dmd/phobos",
        ];
    else
        return [
            "/usr/include/dlang/dmd",
            "/usr/include/dmd/druntime/import",
            "/usr/include/dmd/phobos",
            "/usr/local/include/dmd/druntime/import",
            "/usr/local/include/dmd/phobos",
        ];
}

/**
 * Reads '<root>/dls.json' and applies it: the checker commands and the
 * project import paths (with DCD, and with the list the file watcher is
 * anchored to).
 *
 * dls.json is the server's only configuration channel - no
 * initializationOptions, no command line switch - and it is re-applied
 * whenever the client reports that the file changed.  That is what makes
 * editing the configuration, or creating it where there was none, take effect
 * without restarting the server.
 *
 * The text that was applied is remembered, and a report carrying it again is
 * ignored: one save reaches the server several times (a file watcher fires
 * once per write, and a rename-based save twice), and re-applying is not free
 * - the checkers run again over every open document, and a changed import path
 * list rebuilds DCD's cache.
 */
ConfigReload apply_dls_json() {
    auto dlsJsonPath = make_dls_json_path(arena.allocator());
    auto text = read_dls_json(dlsJsonPath, arena.allocator());

    if (g_dls_json_applied && same_config(text, g_dls_json_text))
    {
        // A save is reported once per write, and twice for a rename-based
        // save.  Staying quiet here is what keeps one save from looking like
        // a configuration loop in the client's log.
        LINFO("dls.json is unchanged, ignoring the repeated report");
        return ConfigReload(false, false);
    }
    remember_config(text);

    // Commands are replaced wholesale: a reload must not keep entries from
    // the previous file.  The debounce/unused-diagnostics switches reset to
    // their defaults the same way, so a key removed from dls.json goes back
    // to the default rather than sticking at whatever was last read.
    g_checkers_count = 0;
    g_debounce_ms = 500;
    g_unused_diagnostics_enabled = true;

    JsonNode* importPaths_json = null;
    if (text is null)
    {
        LWARN("no dls.json at '{}': only the default import paths are registered", dlsJsonPath);
    }
    else
    {
        LWARN("applying dls.json: {}", dlsJsonPath);
        auto root_json = json.parse(text);

        if (!root_json)
        {
            LWARN("{s}", text);
            LWARN("parse error near: {}", get_error_ptr());
            LWARN("failed to parse dls.json");
        }
        else
        {
            importPaths_json = json.get_object_item(root_json, "importPaths");
            if (!importPaths_json)
                LWARN("no importPaths in dls.json");

            auto check_json = json.get_object_item(root_json, "check");
            if (json_is_array(check_json))
            {
                int c = json.get_array_size(check_json);
                LWARN("init: has {} checks", c);
                for (int i = 0; i < c; i++)
                {
                    // A dls.json with more entries than the table holds
                    // would write past it.
                    if (g_checkers_count >= g_checkers.length)
                    {
                        LWARN("init: more than {} checks, ignoring the rest", g_checkers.length);
                        break;
                    }

                    auto item = json.get_array_item(check_json, i);
                    auto check = &g_checkers[g_checkers_count];
                    g_checkers_count++;

                    auto path_obj = json.get_object_item(item, "path");
                    if (json_is_string(path_obj))
                    {
                        const char* str = json.get_string(path_obj);
                        size_t strLen = strlen(str);
                        if (strLen < check.path.length) {
                            mem.memcpy(check.path.ptr, str, strLen);
                            check.path[strLen] = 0;
                        }
                    }

                    auto cmd_obj = json.get_object_item(item, "cmd");
                    if (json_is_string(cmd_obj))
                    {
                        const char* str = json.get_string(cmd_obj);
                        size_t strLen = strlen(str);
                        if (strLen < check.cmd.length) {
                            mem.memcpy(check.cmd.ptr, str, strLen);
                            check.cmd[strLen] = 0;
                        }
                    }
                }
            }
            else
            {
                LWARN("init: dls.json has no check");
            }

            auto debounce_json = json.get_object_item(root_json, "debounceMs");
            if (json_is_number(debounce_json))
                g_debounce_ms = json.get_integer(debounce_json);

            auto unused_json = json.get_object_item(root_json, "unusedDiagnostics");
            if (unused_json !is null)
                g_unused_diagnostics_enabled = json_is_true(unused_json) != 0;
        }
    }

    // The file's import paths, made absolute against the workspace root.
    string[] projectPaths;
    if (importPaths_json)
    {
        int size = json.get_array_size(importPaths_json);
        LWARN("import paths: {}", size);

        projectPaths = arena.allocator().alloc!(string)(size + 1);
        size_t count = 0;
        for (int i = 0; i < size; i++)
        {
            auto item = json.get_array_item(importPaths_json, i);
            auto str = json_string(item);
            if (str == null)
                continue;
            auto L_it = strlen(str);

            // An empty entry is not a path; a one-character one ('a', '/') is.
            // (The old guard here was 'L_it > 1', which dropped 'a' - and it
            // indexed str[1] to spot a drive letter, so it had to.)
            if (L_it == 0)
                continue;

            if (str[0] == '/' || (L_it > 1 && str[1] == ':'))
            {
                projectPaths[count] = cast(string) str[0 .. L_it];
            }
            else
            {
                // Relative to the workspace root.
                auto path = fs.make_path( g_root_path, cast(string) str[0 .. L_it] );
                auto pathBuffer = mem.dupe(arena.allocator(), path);
                projectPaths[count] = cast(string) pathBuffer[0 .. strlen(pathBuffer.ptr)];
            }

            LWARN("adding import: {}", projectPaths[count]);
            count++;
        }
        projectPaths = projectPaths[0 .. count];
    }

    auto paths = keep_import_paths(projectPaths);
    bool pathsChanged = !same_import_paths(paths, g_import_paths);
    free_import_paths(g_import_paths);
    g_import_paths = paths;

    if (pathsChanged)
    {
        // The part DCD cannot absorb in place: an entry that left the file
        // would keep resolving, and DCD's own 'removeImportPaths' disposes the
        // tree without re-pointing the importers that hold symbols from it
        // ('updateTypes' is what normally does that).
        LWARN("project import paths changed, rebuilding DCD's cache");
        dcd_clear();
    }

    // 'addImportPaths' drops what is already registered, so this is safe to
    // repeat - which is why the defaults do not need their own branch.
    dcd_add_imports(default_import_paths());
    if (paths.length > 0)
        dcd_add_imports(paths);

    if (pathsChanged)
        recache_open_documents();

    LWARN("configuration applied: {} project import path(s)", paths.length);
    return ConfigReload(true, pathsChanged);
}

/// What an 'apply_dls_json' call ended up doing.
struct ConfigReload
{
    /// The file differed from the text applied before (or was not there yet):
    /// a repeated report of one save leaves this false, and then nothing is
    /// re-run for it.
    bool applied;
    /// DCD's import path list had to be rebuilt, which also means the watchers
    /// anchored at those paths move.
    bool pathsChanged;
}

/// The text of the configuration that is in effect, in the long-lived
/// allocator: it is what tells a repeated report of one save apart.
__gshared bool g_dls_json_applied;
__gshared char[] g_dls_json_text;

/// Reads '<root>/dls.json' into 'alloc' - the returned slice is null
/// terminated - or returns null when it is absent.
char[] read_dls_json(const(char)[] path, mem.Allocator alloc) {
    fs.File file;
    if (!file.open(path))
        return null;
    // The handle has to go back before this function returns: on Windows an
    // open handle is a lock, and this one would keep the editor from saving
    // the very file the server is reading its configuration from.
    scope(exit) file.close();

    auto size = file.size();
    auto buffer = alloc.alloc!char(size + 1);
    if (buffer.length != size + 1) {
        LERRO("out of memory reading '{}'", path);
        return null;
    }
    buffer[size] = 0;
    file.read(buffer.ptr, size);
    return buffer[0 .. size];
}

/// Byte-wise comparison, with "no file" distinct from "empty file".
bool same_config(const(char)[] a, const(char)[] b) {
    if (a is null || b is null)
        return (a is null) == (b is null);
    if (a.length != b.length)
        return false;
    return a.length == 0 || memcmp(a.ptr, b.ptr, a.length) == 0;
}

/// Remembers the configuration that is now in effect.
void remember_config(const(char)[] text) {
    if (g_dls_json_text.length > 0)
        heap_allocator.free(g_dls_json_text);
    g_dls_json_text = null;
    g_dls_json_applied = true;

    if (text is null || text.length == 0)
        return;

    auto copy = heap_allocator.alloc!char(text.length);
    if (copy.length != text.length) {
        LERRO("out of memory remembering dls.json");
        return;
    }
    memcpy(copy.ptr, text.ptr, text.length);
    g_dls_json_text = copy;
}

/// Hands every open document back to DCD.  A cache reset must not lose the
/// text an editor has not saved yet: the buffer is what the user sees.
void recache_open_documents() {
    foreach (i; 0 .. first_empty_buf) {
        if (buffers[i].content == null) continue;
        dcd_on_open(buffers[i].uri, buffers[i].content);
    }
    // With nothing open (the configuration applied at startup) there is
    // nothing on screen to refresh.
    module_cache_changed(first_empty_buf > 0);
}

/// Re-runs the configured checkers on every open document: 'check' may have
/// just changed, and diagnostics from a command that no longer applies are
/// worse than none.
void relint_open_documents() {
    foreach (i; 0 .. first_empty_buf) {
        if (buffers[i].content == null) continue;
        lsp_lint(buffers[i]);
    }
}


void lsp_shutdown(int id) {
    LERRO("lsp_shutdown");
    lsp_send_response(id, null);
    //exit(0);
}

void lsp_exit() {
    LERRO("lsp_exit");
    exit(0);
}

void lsp_sync_open(JsonNode* params_json) {
    auto text_document_json = json.get_object_item(params_json, "textDocument");

    char* uri = json_string_item(text_document_json, "uri");
    char* text = json_string_item(text_document_json, "text");

    if (uri == null) {
        LWARN("didOpen without a uri");
        return;
    }

    // text == null: fall back to reading the file from disk.
    BUFFER buffer = open_buffer(heap_allocator, uri, text);
    if (buffer.content == null) {
        LWARN("didOpen: no content for '{}'", uri);
        return;
    }

    lsp_lint(buffer);

    LWARN("lsp_sync_open: {}", uri);
    dcd_on_open(uri, buffer.content);
    // Usually the text on disk, which the modules importing this one already
    // resolved against: no reason to have the client ask again.
    module_cache_changed(false);
}
void lsp_sync_change(JsonNode* params_json) {
    auto text_document_json = json.get_object_item(params_json, "textDocument");

    char* uri = json_string_item(text_document_json, "uri");

    auto content_changes_json = json.get_object_item(params_json, "contentChanges");
    auto content_change_json = json.get_array_item(content_changes_json, 0);
    char* text = json_string_item(content_change_json, "text");

    if (uri == null) {
        LWARN("didChange without a uri");
        return;
    }
    if (text == null) {
        LWARN("didChange for '{}' without contentChanges[0].text", uri);
        return;
    }

    BUFFER buffer = update_buffer(heap_allocator, uri, text);
    if (buffer.content == null) {
        LWARN("didChange: no content stored for '{}'", uri);
        return;
    }

    // Debounced, not run here: a keystroke is the one lint trigger frequent
    // enough that running the dispatcher inline would block every other
    // request behind it.  'schedule_lint' pushes the deadline out on every
    // call, so a burst of changes only lints once, after the last one.
    schedule_lint(uri, time.get_time() + g_debounce_ms);
}

void lsp_sync_close(JsonNode* params_json) {
    auto text_document_json = json.get_object_item(params_json, "textDocument");

    char* uri = json_string_item(text_document_json, "uri");

    if (uri == null) {
        LWARN("didClose without a uri");
        return;
    }

    close_buffer(heap_allocator, uri);
    lsp_lint_clear(uri);
}

void lsp_did_save(JsonNode* params_json) {
    auto text_document_json = json.get_object_item(params_json, "textDocument");

    char* uri = json_string_item(text_document_json, "uri");

    if (uri == null) {
        LWARN("didSave without a uri");
        return;
    }

    auto buffer = get_buffer(uri);

    if (buffer.content == null)
    {
        // The document isn't open (saved after a close, or never opened in
        // this session).  Prefer the text the client sent - the capabilities
        // ask for it via save.includeText - and fall back to the file itself.
        char* text = json_string_item(params_json, "text");
        if (text == null)
            text = json_string_item(text_document_json, "text");

        buffer = open_buffer(heap_allocator, uri, text);
        if (buffer.content == null)
        {
            LWARN("didSave: no content for '{}'", uri);
            return;
        }
    }

    // Asked before DCD takes the text: a save of the text DCD already holds
    // changes nothing any other document resolves through.
    immutable unchanged = dcd_content_unchanged(uri, buffer.content) != 0;
    dcd_on_save(uri, buffer.content);
    if (!unchanged)
        module_cache_changed(true);

    lsp_lint(buffer);
}

/**
 * Copies the project's import paths into the long-lived allocator, ready to
 * be registered with DCD and watched.
 *
 * 'paths' belong to the request's arena, so they cannot outlive the frame
 * that read dls.json.  A path nested inside another one is dropped: both
 * watchers would report the same file, and a project root is usually listed
 * right next to the directories inside it.
 */
string[] keep_import_paths(string[] paths) {
    auto kept = heap_allocator.alloc!(string)(paths.length);
    if (kept.length != paths.length) {
        LERRO("out of memory keeping {} import paths", paths.length);
        return null;
    }

    size_t count = 0;
    foreach (i, path; paths) {
        auto normalized = strip_trailing_separator(path);
        if (normalized.length == 0) continue;

        // Keep the shortest path, whatever the order in the config: a root
        // listed next to a directory inside it (or repeated) must not produce
        // a second watcher for the same file.
        bool redundant = false;
        foreach (existing; kept[0 .. count]) {
            if (existing == normalized || is_under(normalized, existing)) {
                redundant = true;
                break;
            }
        }
        foreach (j, other; paths) {
            if (redundant || i == j) continue;
            auto otherNormalized = strip_trailing_separator(other);
            if (otherNormalized.length == 0 || otherNormalized.length >= normalized.length)
                continue;
            if (is_under(normalized, otherNormalized)) {
                redundant = true;
                break;
            }
        }
        if (redundant) continue;

        auto buffer = heap_allocator.alloc!char(normalized.length + 1);
        if (buffer.length != normalized.length + 1) continue;
        memcpy(buffer.ptr, normalized.ptr, normalized.length);
        buffer[normalized.length] = 0;
        kept[count++] = cast(string) buffer[0 .. normalized.length];
    }

    return kept[0 .. count];
}

/// Frees a list previously returned by 'keep_import_paths': each path's own
/// buffer, then the array that held them. Called before 'g_import_paths' is
/// replaced - every reload otherwise abandons the whole previous list.
void free_import_paths(string[] paths) {
    foreach (path; paths)
        if (path.length > 0)
            heap_allocator.free(cast(char[]) path);
    if (paths.length > 0)
        heap_allocator.free(paths);
}

/// True when both lists name the same directories in the same order, which is
/// what decides whether DCD's cache has to be rebuilt.
bool same_import_paths(string[] a, string[] b) {
    if (a.length != b.length) return false;
    foreach (i; 0 .. a.length)
        if (a[i] != b[i]) return false;
    return true;
}

/// 'path' without its trailing separators ('/usr/x/' and '/usr/x' name the
/// same import path).
const(char)[] strip_trailing_separator(const(char)[] path) {
    auto end = path.length;
    while (end > 1 && (path[end - 1] == '/' || path[end - 1] == '\\'))
        end--;
    return path[0 .. end];
}

/// True when 'path' lies inside the directory 'root' (both absolute; a
/// trailing separator is not expected on 'root').
bool is_under(const(char)[] path, const(char)[] root) {
    if (root.length == 0 || path.length <= root.length)
        return false;
    if (root.length == 1 && root[0] == '/')
        return path[0] == '/';
    if (path[0 .. root.length] != root)
        return false;
    return path[root.length] == '/' || path[root.length] == '\\';
}

/// True when 'uri' is a file under one of the project's import paths.
bool is_in_import_path(const char* uri) {
    if (uri == null) return false;

    auto path = uri[0 .. strlen(uri)];
    if (path.length > 7 && path[0 .. 7] == "file://")
        path = path[7 .. $];

    foreach (importPath; g_import_paths) {
        if (is_under(path, importPath)) return true;
    }
    return false;
}

/// '<root>/dls.json' in 'alloc'.
const(char)[] make_dls_json_path(mem.Allocator alloc) {
    enum name = "dls.json";
    auto root = strip_trailing_separator(g_root_path[0 .. strlen(g_root_path.ptr)]);
    auto buffer = alloc.alloc!char(root.length + 1 + name.length + 1);
    if (buffer.length != root.length + 1 + name.length + 1) return null;
    memcpy(buffer.ptr, root.ptr, root.length);
    buffer[root.length] = '/';
    memcpy(buffer.ptr + root.length + 1, name.ptr, name.length);
    buffer[root.length + 1 + name.length] = 0;
    return buffer[0 .. root.length + 1 + name.length];
}

/// 'text' as a null-terminated string in 'alloc'.
char* make_cstring(mem.Allocator alloc, const(char)[] text) {
    auto buffer = alloc.alloc!char(text.length + 1);
    if (buffer.length != text.length + 1) return null;
    memcpy(buffer.ptr, text.ptr, text.length);
    buffer[text.length] = 0;
    return buffer.ptr;
}

/// True when 'uri' is the '<root>/dls.json' this server reads - the file the
/// client is asked to watch so a configuration change can be applied without
/// restarting the server.
bool is_dls_json(const char* uri) {
    if (uri == null || g_root_path[0] == 0) return false;

    auto path = uri[0 .. strlen(uri)];
    if (path.length > 7 && path[0 .. 7] == "file://")
        path = path[7 .. $];

    auto root = strip_trailing_separator(g_root_path[0 .. strlen(g_root_path.ptr)]);
    enum name = "/dls.json";
    if (path.length != root.length + name.length) return false;
    return path[0 .. root.length] == root && path[root.length .. $] == name;
}

/**
 * 'file://<import path>/' - the base a watcher's RelativePattern hangs off.
 * The arena is enough: the registration is sent from the same frame.
 */
char* make_directory_uri(mem.Allocator alloc, const(char)[] path) {
    enum prefix = "file://";
    auto buffer = alloc.alloc!char(prefix.length + path.length + 2);
    if (buffer.length != prefix.length + path.length + 2) return null;
    memcpy(buffer.ptr, prefix.ptr, prefix.length);
    memcpy(buffer.ptr + prefix.length, path.ptr, path.length);
    buffer[prefix.length + path.length] = '/';
    buffer[prefix.length + path.length + 1] = 0;
    return buffer.ptr;
}

/// '<base>/<pattern>' - the watcher a client without RelativePattern support
/// gets.  The LSP PathMatcher works on the whole path, so this stays anchored
/// at 'base'.
char* make_absolute_glob(mem.Allocator alloc, const(char)[] base, const(char)[] pattern) {
    auto buffer = alloc.alloc!char(base.length + 1 + pattern.length + 1);
    if (buffer.length != base.length + 1 + pattern.length + 1) return null;
    memcpy(buffer.ptr, base.ptr, base.length);
    buffer[base.length] = '/';
    memcpy(buffer.ptr + base.length + 1, pattern.ptr, pattern.length);
    buffer[base.length + 1 + pattern.length] = 0;
    return buffer.ptr;
}

/// 'workspace/didChangeWatchedFiles' FileChangeType values.
enum FILE_CHANGE_CREATED = 1;
enum FILE_CHANGE_CHANGED = 2;
enum FILE_CHANGE_DELETED = 3;

/*
{
    "changes": [
        { "uri": "file:///dev/kshared/gen/packets.d", "type": 2 }
    ]
}
*/
/**
 * Reports files that were written by something other than the editor: a code
 * generator, a formatter, git, another program.
 *
 * The client only sends this after 'register_file_watcher' (initialize.d) has
 * asked it to watch D sources.  A change is reconciled exactly like a save -
 * DCD re-parses the module and re-points the modules that import it - because
 * nothing else tells the cache that a file on disk moved on: a lookup hands
 * back the cached symbol without ever comparing modification times.
 */
void lsp_did_change_watched_files(JsonNode* params_json) {
    auto changes_json = json.get_object_item(params_json, "changes");
    if (!json_is_array(changes_json)) {
        LWARN("didChangeWatchedFiles without a changes array");
        return;
    }

    int size = json.get_array_size(changes_json);
    for (int i = 0; i < size; i++) {
        auto change_json = json.get_array_item(changes_json, i);
        auto uri_json = json.get_object_item(change_json, "uri");
        auto type_json = json.get_object_item(change_json, "type");

        if (!json_is_string(uri_json)) {
            LWARN("didChangeWatchedFiles change without a uri");
            continue;
        }
        char* uri = json.get_string(uri_json);

        int type = json_int(type_json, FILE_CHANGE_CHANGED);

        // Two watchers can cover the same file when a path is nested in
        // another one, and a client is free to report a write twice.
        if (reported_earlier(changes_json, i, uri))
            continue;

        // The configuration is watched as well, and a change to it (or a file
        // that just appeared) is applied here - it is never a module.  This
        // has to come before the 'deleted' branch: a removed dls.json means
        // the project import paths are gone.
        if (is_dls_json(uri)) {
            auto reload = apply_dls_json();
            if (reload.pathsChanged)
                refresh_import_path_watchers();
            if (reload.applied)
                relint_open_documents();
            continue;
        }

        if (type == FILE_CHANGE_DELETED) {
            // DCD can only clear its whole cache, and re-caching a path that
            // no longer exists would throw out of 'cacheModule' (a missing
            // file is opened unconditionally once it needs a re-parse) and
            // take the server down.  The deleted module's symbols survive
            // until that path is cached again or the server restarts.
            LWARN("watched file '{}' was deleted, keeping it cached", uri);
            continue;
        }

        if (!has_buffer(uri) && !is_in_import_path(uri)) {
            // Nothing a completion can read lives here: a workspace root is
            // full of D sources the project does not import, and re-parsing
            // them would only add latency to the next request.
            LINFO("watched file outside the import paths, ignoring: {}", uri);
            continue;
        }

        reconcile_document(uri);
    }
}

/// True when a change before 'index' in the same notification names 'uri'.
bool reported_earlier(JsonNode* changes_json, int index, const char* uri) {
    for (int i = 0; i < index; i++) {
        auto change_json = json.get_array_item(changes_json, i);
        auto other = json_string_item(change_json, "uri");
        if (other != null && strcmp(other, uri) == 0)
            return true;
    }
    return false;
}

/**
 * Re-caches 'uri' with the text that is authoritative for it and re-points
 * the modules that import it ('dcd_on_save' is that reconciliation point for
 * an external write just as much as for a save).
 *
 * An open document stays authoritative: the editor owns its text, so a write
 * on disk must not replace unsaved edits.  A client that reloads a file it
 * considers clean sends its own 'didChange' for the new text.
 */
void reconcile_document(const char* uri) {
    if (has_buffer(uri)) {
        auto buffer = get_buffer(uri);

        // DCD already holds exactly this text: the editor's own save reached it
        // as a 'didSave', and this event is that same write seen a second time.
        // Handing it over again would re-notify every dependent (and re-run the
        // checker below) for a file that did not change.
        if (dcd_content_unchanged(uri, buffer.content))
            return;

        dcd_on_save(uri, buffer.content);
        module_cache_changed(true);
        lsp_lint(buffer);
        return;
    }

    auto text = read_file_cstring(heap_allocator, uri);
    if (text == null) {
        LWARN("watched file '{}' can't be read", uri);
        return;
    }
    scope(exit) free_cstring(heap_allocator, text);

    if (dcd_content_unchanged(uri, text))
        return;

    LWARN("file changed outside the editor: {}", uri);
    dcd_on_save(uri, text);
    module_cache_changed(true);
}


DOCUMENT_LOCATION lsp_parse_document(JsonNode* params_json) {
    DOCUMENT_LOCATION document;

    auto text_document_json = json.get_object_item(params_json, "textDocument");
    document.uri = json_string_item(text_document_json, "uri");
    if (document.uri == null) {
        LWARN("request without textDocument.uri");
        return DOCUMENT_LOCATION.init;
    }

    auto position_json = json.get_object_item(params_json, "position");
    auto line_json = json.get_object_item(position_json, "line");
    if (!json_is_number(line_json)) {
        LWARN("request for '{}' without a valid position", document.uri);
        return DOCUMENT_LOCATION.init;
    }
    document.line = json.get_integer(line_json);
    auto character_json = json.get_object_item(position_json, "character");
    if (!json_is_number(character_json)) {
        LWARN("request for '{}' without a valid position", document.uri);
        return DOCUMENT_LOCATION.init;
    }
    document.character = json.get_integer(character_json);

    return document;
}

void lsp_send_response(int id, JsonNode* result) {
    auto response = json.create_object();
    json.add_string_to_object(response, "jsonrpc", "2.0");
    json.add_number_to_object(response, "id", id);
    if (result != null)
        json.add_item_to_object(response, "result", result);
    else
        json.add_null_to_object(response, "result");

    send_message(response);
}

/// Answers request 'id' with a JSON-RPC error instead of a result.
void lsp_send_error(int id, int code, const(char)* message) {
    auto response = json.create_object();
    json.add_string_to_object(response, "jsonrpc", "2.0");
    json.add_number_to_object(response, "id", id);
    auto error = json.add_object_to_object(response, "error");
    json.add_number_to_object(error, "code", code);
    json.add_string_to_object(error, "message", message);

    send_message(response);
}

/**
 * Sends a request to the client ('client/registerCapability',
 * 'workspace/semanticTokens/refresh').
 *
 * The reply is not tracked: 'handle_request' only logs a response, and
 * nothing in the server waits for one.  'id' must come from
 * 'g_next_request_id' so it can't collide with a client request id.
 */
void lsp_send_request(int id, const(char)* method, JsonNode* params) {
    auto request = json.create_object();
    json.add_string_to_object(request, "jsonrpc", "2.0");
    json.add_number_to_object(request, "id", id);
    json.add_string_to_object(request, "method", method);
    // JSON-RPC wants 'params' to be an array or an object when it is there,
    // so a request without any (a refresh) leaves it out.
    if (params != null)
        json.add_item_to_object(request, "params", params);

    send_message(request);
}

/// Frames 'message' and writes it to stdout.
void send_message(JsonNode* message) {
    auto output = printJsonStr(message);
    char[64] header;
    auto headerLen = snprintf(header.ptr, header.length, "Content-Length: %u\r\n\r\n",
        cast(uint) output.length);
    if (headerLen < 0 || cast(size_t) headerLen >= header.length)
        LERRO("cannot frame a response of {} bytes", output.length);

    fwrite(header.ptr, 1, headerLen, stdout);
    fwrite(output.ptr, 1, output.length, stdout);
    fflush(stdout);

    LINFO("sent:\n{}", output);
}


	import core.stdc.stdio : FILE, fopen, fwrite, fclose, remove, fgets, snprintf;
	import core.stdc.string : strlen, strchr, strncmp;

	// popen/pclose are POSIX/Windows specifics, not strict ANSI C, so we declare them explicitly.
	version(Windows) {
	    extern(C) FILE* _popen(const char* command, const char* mode);
	    extern(C) int _pclose(FILE* stream);
	    alias popen = _popen;
	    alias pclose = _pclose;
	} else {
	    extern(C) FILE* popen(const char* command, const char* mode);
	    extern(C) int pclose(FILE* stream);
	}

/**
 * Diagnostics for 'buffer', from every source that is enabled, all in one
 * `publishDiagnostics` (LSP replaces a URI's whole diagnostic set per
 * notification, so the sources can't be sent separately).  Each source owns
 * its own severity/tags/code - nothing is hardcoded here - so a future
 * source with a different shape (say, an error-level check) is one more call
 * below, not a change to this function.
 *
 * Called both eagerly (open/save/external write/config reload) and from the
 * debounce timer (`run_due_lints`, main.d's loop); either way it is this
 * buffer's own pending deadline that gets satisfied.
 */
void lsp_lint(BUFFER buffer) {
    clear_lint_pending(buffer.uri);

    auto params = json.create_object();
    json.add_string_to_object(params, "uri", buffer.uri);
    auto diagnostics = json.add_array_to_object(params, "diagnostics");

    lint_external_checkers(buffer, diagnostics);
    if (g_unused_diagnostics_enabled)
        lint_unused_symbols(buffer, diagnostics);

    lsp_send_notification("textDocument/publishDiagnostics", params);
}

/**
 * Diagnostics from the external command configured in dls.json's "check"
 * list (the path whose prefix matches 'buffer' picks the command).  Its
 * stdout is parsed line by line for a "file.d:LINE:COL: Severity: message" /
 * "file.d(LINE,COL): ..." shape; a line without one is skipped.
 */
void lint_external_checkers(BUFFER buffer, JsonNode* diagnostics) {
    char* cmd_to_run = null;

    // 1. Strip "file://" prefix from URI (7 chars)
    char* buffer_path = buffer.uri;
    if (strncmp(buffer_path, "file://", 7) == 0) {
        buffer_path += 7;
    }

	// 2. Find matching checker
    for (int i = 0; i < g_checkers_count; i++) {
        char[512] full_check_path;

        // Construct the directory path to check against
        // We ensure there's a clear separation between root and the sub-path
        snprintf(full_check_path.ptr, full_check_path.sizeof, "%s/%s",
                 g_root_path.ptr, g_checkers[i].path.ptr);

        // LOGGING: Useful to see why the match fails
         LINFO("Comparing buffer '{}' with checker path '{}'", buffer_path, full_check_path.ptr);

        // Check if the buffer path contains the checker directory path
        if (strstr(buffer_path, full_check_path.ptr) != null) {
            cmd_to_run = g_checkers[i].cmd.ptr;
            break;
        }
    }

    // If no checker matches this path, we have nothing to do
    if (!cmd_to_run) {
        LWARN("check: no commands for '{}' (resolved path: '{}')", buffer.uri, buffer_path);
        return;
    }

    // 3. Execute the specific command found
    FILE* pipe = popen(cmd_to_run, "r");

    if (pipe) {
        char[1024] lineBuf;

        while (fgets(lineBuf.ptr, lineBuf.sizeof, pipe) != null) {
            char* p = lineBuf.ptr;

            // Handle both file.d:1278: and file.d(1278): formats
            char* ext = strstr(p, ".d:");
            if (!ext) ext = strstr(p, ".d(");
            if (!ext) continue;

            p = ext + 2; // Point to ':' or '('
            p++;         // Skip the delimiter

            // Parse line number
            int lineNum = 0;
            while (*p >= '0' && *p <= '9') {
                lineNum = lineNum * 10 + (*p - '0');
                p++;
            }

            // Parse optional column number
            int colNum = 0;
            if (*p == ',' || *p == ':') {
                p++;
                while (*p >= '0' && *p <= '9') {
                    colNum = colNum * 10 + (*p - '0');
                    p++;
                }
            }

            while (*p == ')' || *p == ':' || *p == ' ') p++;

            // Determine severity
            int severity = 1;
            if (strncmp(p, "Error:", 6) == 0) {
                severity = 1;
                p += 6;
            } else if (strncmp(p, "Warning:", 8) == 0) {
                severity = 2;
                p += 8;
            } else if (strncmp(p, "Deprecation:", 12) == 0) {
                severity = 3;
                p += 12;
            } else {
                severity = 4;
            }

            while (*p == ' ') p++;

            size_t len = strlen(p);
            while (len > 0 && (p[len - 1] == '\n' || p[len - 1] == '\r')) {
                p[len - 1] = '\0';
                len--;
            }

            if (lineNum > 0) lineNum--;
            if (colNum > 0) colNum--;

            auto diagnostic = json.create_object();
            auto range = json.add_object_to_object(diagnostic, "range");

            auto start_position = json.add_object_to_object(range, "start");
            json.add_number_to_object(start_position, "line", lineNum);
            json.add_number_to_object(start_position, "character", colNum);

            auto end_position = json.add_object_to_object(range, "end");
            json.add_number_to_object(end_position, "line", lineNum);
            json.add_number_to_object(end_position, "character", colNum + 1);

            json.add_number_to_object(diagnostic, "severity", severity);
            json.add_string_to_object(diagnostic, "message", p);
            json.add_item_to_array(diagnostics, diagnostic);
        }
        pclose(pipe);
    } else {
        LWARN("check: command doesn't work '{}' for '{}'", cmd_to_run, buffer.uri);
    }
}

void lsp_lint_clear(const char *uri) {
    auto params = json.create_object();
    json.add_string_to_object(params, "uri", uri);
    json.add_array_to_object(params, "diagnostics");
    lsp_send_notification("textDocument/publishDiagnostics", params);
}


void lsp_send_notification(const(char)* method, JsonNode* params)
{
    auto notification = json.create_object();
    json.add_string_to_object(notification, "jsonrpc", "2.0");
    json.add_string_to_object(notification, "method", method);
    if (params != null)
        json.add_item_to_object(notification, "params", params);
    else
        json.add_null_to_object(notification, "params");

    send_message(notification);
}

// HELPERS

/// rt.json's predicates assert the node is there; a request may omit anything.
bool json_is_string(JsonNode* node) { return node !is null && json.is_string(node); }
bool json_is_number(JsonNode* node) { return node !is null && json.is_number(node); }
bool json_is_array(JsonNode* node) { return node !is null && json.is_array(node); }
bool json_is_true(JsonNode* node) { return node !is null && json.is_true(node); }

char* json_string(JsonNode* node) {
    return json_is_string(node) ? json.get_string(node) : null;
}

int json_int(JsonNode* node, int fallback) {
    return json_is_number(node) ? json.get_integer(node) : fallback;
}

char* json_string_item(JsonNode* object, const(char)* name) {
    return json_string(json.get_object_item(object, name));
}


JsonNode* create_range(JsonNode* obj, const(char)* id, Position s, Position e)
{
    auto range = json.add_object_to_object(obj, id);
    auto start = json.add_object_to_object(range, "start");
    auto end = json.add_object_to_object(range, "end");
    json.add_number_to_object(start, "line", s.line);
    json.add_number_to_object(start, "character", s.character);
    json.add_number_to_object(end, "line", e.line);
    json.add_number_to_object(end, "character", e.character);
    return range;
}

bool get_range(JsonNode* obj, Position* start, Position* end)
{
    auto range_json = json.get_object_item(obj, "range");
    auto start_json = json.get_object_item(range_json, "start");
    auto end_json = json.get_object_item(range_json, "end");
    {
        start.line = json_int(json.get_object_item(start_json, "line"), 0);
        start.character = json_int(json.get_object_item(start_json, "character"), 0);
    }
    {
        end.line = json_int(json.get_object_item(end_json, "line"), 0);
        end.character = json_int(json.get_object_item(end_json, "character"), 0);
    }
    return true;
}


int kind_to_lsp(ubyte k)
{
    switch(k)
    {
        case 'c': // class name
            return KClass;
        case 'i': // interface name
            return KInterface;
        case 's': // struct name
        case 'u': // union name
            return KStruct;
        case 'a': // array
        case 'A': // associative array
        case 'v': // variable name
            return KVariable;
        case 'm': // member variable
            return KField;
        case 'e': // enum member
            return KEnumMember;
        case 'k': // keyword
            return KKeyword;
        case 'f': // function
            return KFunction;
        case 'F': // UFCS function acts like a method
            return KMethod;
        case 'g': // enum name
            return KEnum;
        case 'P': // package name
        case 'M': // module name
            return KModule;
        case 'l': // alias name
            return KReference;
        case 't': // template name
        case 'T': // mixin template name
            return KProperty;
        case 'h': // template type parameter
        case 'p': // template variadic parameter
            return KTypeParameter;
        default:
            return KText;
    }
}

enum KText = 1;
enum KMethod = 2;
enum KFunction = 3;
enum KConstructor = 4;
enum KField = 5;
enum KVariable = 6;
enum KClass = 7;
enum KInterface = 8;
enum KModule = 9;
enum KProperty = 10;
enum KUnit = 11;
enum KValue = 12;
enum KEnum = 13;
enum KKeyword = 14;
enum KSnippet = 15;
enum KColor = 16;
enum KFile = 17;
enum KReference = 18;
enum KFolder = 19;
enum KEnumMember = 20;
enum KConstant = 21;
enum KStruct = 22;
enum KEvent = 23;
enum KOperator = 24;
enum KTypeParameter = 25;
