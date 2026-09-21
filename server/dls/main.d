module dls.main;

import rt.dbg;
import str = rt.str;
import args = rt.args;
import mem = rt.memz;
import fs = rt.filesystem;

struct C
{
    public import cjson;
}

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
import dls.definition;
import dls.hover;
import dls.semantic_tokens;

__gshared:

mem.ArenaAllocator arena;

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


extern(C) void* j_alloc(size_t sz) {
    return arena.alloc(sz).ptr;
}

extern(C) void j_free(void* ptr) {
}

extern(C) void main(int argc, char** argv) {

    LOG_FLAG.info = false;
    LOG_FLAG.warn = true;
    LOG_FLAG.erro = true;

    import rt.crash_handler;
    rt_register_crash_handler();

    arena = mem.ArenaAllocator.create(heap_allocator);
    // TODO: remove this
    //  - auto detect dmd/ldc
    //  - config for other folders

    C.cJSON_Hooks hooks;
    hooks.malloc_fn = &j_alloc;
    hooks.free_fn = &j_free;
    C.cJSON_InitHooks(&hooks);

    //test
    //{
    //    C.cJSON* request = C.cJSON_Parse(TEST_DIDOPEN.ptr);
    //    handle_request(request);
    //}
    //{
    //    C.cJSON* request = C.cJSON_Parse(TEST_DIDCHANGE.ptr);
    //    handle_request(request);
    //}
    //{
    //    C.cJSON* request = C.cJSON_Parse(TEST_COMPLETION.ptr);
    //    handle_request(request);
    //}
    //{
    //    return;
    //}

    while (true) {
        auto len = parse_header();
        auto request = parse_content(arena.allocator(), len);
        if (!request) {
            LERRO("unnable to parse request");
            break;
        }
        handle_request(request);
        arena.dispose();
    }
}

size_t parse_header() {
    import core.stdc.stdio : stdin, fgetc;
    import core.stdc.string : strncmp;
    import core.stdc.stdlib : atoi;

    size_t content_length = 0;
    char[1024] line;

    while (true) {
        int i = 0;
        // Read one full line
        while (i < line.length - 1) {
            int c = fgetc(stdin);
            if (c == EOF) return 0;
            line[i++] = cast(char)c;
            if (c == '\n') break;
        }
        line[i] = '\0';

        // Check for the empty line (\r\n or just \n)
        // This MUST be the exit condition of the loop
        if (line[0] == '\n' || (line[0] == '\r' && line[1] == '\n')) {
            if (content_length > 0) return content_length;
            continue; // Keep looking if we haven't found a length yet
        }

        // Extract Content-Length
        if (strncmp(line.ptr, "Content-Length:", 15) == 0) {
            char* p = line.ptr + 15;
            while (*p && (*p < '0' || *p > '9')) p++;
            content_length = atoi(p);
        }

        // We ignore "Content-Type" or other headers, but we MUST
        // let the loop continue to consume them.
    }
}

C.cJSON* parse_content(mem.Allocator alloc, size_t len) {
    if (len == 0) return null;

    // Allocate len + 1 to ensure space for a null terminator
    char[] buffer = alloc.alloc!(char)(len + 1);
    if (buffer.ptr == null) exit(1);

    // Read exactly 'len' bytes
    size_t read_elements = fread(buffer.ptr, 1, len, stdin);

    if (read_elements != len) {
        // If we didn't get enough bytes, the pipe is likely broken
        return null;
    }

    // CRITICAL: cJSON_Parse requires a null-terminated string
    buffer[len] = '\0';

    // Debug: Log the first few chars to ensure it's actually JSON
    // LINFO("JSON Start: {s}", buffer[0 .. (len > 20 ? 20 : len)]);

    return C.cJSON_Parse(buffer.ptr);
}

void handle_request(C.cJSON* request) {
    int id = -1;
    char* method;

    auto method_json = C.cJSON_GetObjectItem(request, "method");
    if (!C.cJSON_IsString(method_json)) {
        // A message without a method is a response to a request the server
        // sent (a file-watcher registration, say).  There is nothing to
        // dispatch here, and killing the process over it would cost the
        // editor every language feature until it restarts the server.
        LWARN("ignoring client response (no method)");
        return;
    }
    method = method_json.valuestring;

    auto id_json = C.cJSON_GetObjectItem(request, "id");
    if (C.cJSON_IsNumber(id_json)) {
        id = id_json.valueint;
    }

    auto params_json = C.cJSON_GetObjectItem(request, "params");

     LINFO("request id: {} -> method: {}", id, method);

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
    else
    {
        LWARN("request '{}' not handled", method);
        if (params_json)
        {
            char* output = C.cJSON_Print(params_json);
            LWARN("{}", output);
        }
    }
}


void lsp_initialize_params(int id, C.cJSON* params_json)
{
    char* output = C.cJSON_Print(params_json);
    LINFO("lsp_initialize_params:\n{}", output);
    dcd_init();
    auto rootPath_json = C.cJSON_GetObjectItem(params_json, "rootPath");
    auto rootURI_json = C.cJSON_GetObjectItem(params_json, "rootUri");

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
	        auto rootPath = C.cJSON_GetStringValue(rootPath_json);
	        auto L_r = strlen(rootPath);
	        if (L_r < g_root_path.length) {
	            mem.memcpy(g_root_path.ptr, rootPath, L_r);
	            g_root_path[L_r] = 0; // Null terminate
	        }
	    } else if (rootURI_json) {
	        auto rootPath = C.cJSON_GetStringValue(rootURI_json);
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
string[] default_import_paths() {
    version (linux)
        return [
            "/usr/include/dlang/dmd/",
            "/usr/include/dmd/druntime/import/",
            "/usr/include/dmd/phobos/",
        ];
    else version (Windows)
        return [
            "c:/D/dmd2/src/druntime/import/",
            "c:/D/dmd2/src/phobos/",
        ];
    else
        return null;
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
    // the previous file.
    g_checkers_count = 0;

    C.cJSON* importPaths_json = null;
    if (text is null)
    {
        LWARN("no dls.json at '{}': only the default import paths are registered", dlsJsonPath);
    }
    else
    {
        LWARN("applying dls.json: {}", dlsJsonPath);
        C.cJSON* root_json = C.cJSON_Parse(text.ptr);

        if (!root_json)
        {
            LWARN("{s}", text);
            LWARN("parse error near: {s}", C.cJSON_GetErrorPtr());
            LWARN("failed to parse dls.json");
        }
        else
        {
            importPaths_json = C.cJSON_GetObjectItem(root_json, "importPaths");
            if (!importPaths_json)
                LWARN("no importPaths in dls.json");

            auto check_json = C.cJSON_GetObjectItem(root_json, "check");
            if (check_json && C.cJSON_IsArray(check_json))
            {
                int c = C.cJSON_GetArraySize(check_json);
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

                    auto item = C.cJSON_GetArrayItem(check_json, i);
                    auto check = &g_checkers[g_checkers_count];
                    g_checkers_count++;

                    auto path_obj = C.cJSON_GetObjectItem(item, "path");
                    if (C.cJSON_IsString(path_obj))
                    {
                        const char* str = path_obj.valuestring;
                        size_t strLen = strlen(str);
                        if (strLen < check.path.length) {
                            mem.memcpy(check.path.ptr, str, strLen);
                            check.path[strLen] = 0;
                        }
                    }

                    auto cmd_obj = C.cJSON_GetObjectItem(item, "cmd");
                    if (C.cJSON_IsString(cmd_obj))
                    {
                        const char* str = cmd_obj.valuestring;
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
        }
    }

    // The file's import paths, made absolute against the workspace root.
    string[] projectPaths;
    if (importPaths_json)
    {
        int size = C.cJSON_GetArraySize(importPaths_json);
        LWARN("import paths: {}", size);

        projectPaths = arena.allocator().alloc!(string)(size + 1);
        size_t count = 0;
        for (int i = 0; i < size; i++)
        {
            auto item = C.cJSON_GetArrayItem(importPaths_json, i);
            auto str = C.cJSON_GetStringValue(item);
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

/// Reads '<root>/dls.json' into 'alloc' - the returned slice is
/// null-terminated (cJSON wants a C string) - or returns null when it is
/// absent.
char[] read_dls_json(const(char)[] path, mem.Allocator alloc) {
    fs.File file;
    if (!file.open(path))
        return null;

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

void lsp_sync_open(C.cJSON* params_json) {
    auto text_document_json = C.cJSON_GetObjectItem(params_json, "textDocument");

    auto uri_json = C.cJSON_GetObjectItem(text_document_json, "uri");
    char* uri = C.cJSON_GetStringValue(uri_json);

    auto text_json = C.cJSON_GetObjectItem(text_document_json, "text");
    char* text = C.cJSON_GetStringValue(text_json);

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
}
void lsp_sync_change(C.cJSON* params_json) {
    auto text_document_json = C.cJSON_GetObjectItem(params_json, "textDocument");

    auto uri_json = C.cJSON_GetObjectItem(text_document_json, "uri");
    char* uri = C.cJSON_GetStringValue(uri_json);

    auto content_changes_json = C.cJSON_GetObjectItem(params_json, "contentChanges");
    auto content_change_json = C.cJSON_GetArrayItem(content_changes_json, 0);
    auto text_json = C.cJSON_GetObjectItem(content_change_json, "text");
    char* text = C.cJSON_GetStringValue(text_json);

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

    lsp_lint(buffer);
}

void lsp_sync_close(C.cJSON* params_json) {
    auto text_document_json = C.cJSON_GetObjectItem(params_json, "textDocument");

    auto uri_json = C.cJSON_GetObjectItem(text_document_json, "uri");
    char* uri = C.cJSON_GetStringValue(uri_json);

    if (uri == null) {
        LWARN("didClose without a uri");
        return;
    }

    close_buffer(heap_allocator, uri);
    lsp_lint_clear(uri);
}

void lsp_did_save(C.cJSON* params_json) {
    auto text_document_json = C.cJSON_GetObjectItem(params_json, "textDocument");

    auto uri_json = C.cJSON_GetObjectItem(text_document_json, "uri");
    char* uri = C.cJSON_GetStringValue(uri_json);

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
        char* text = C.cJSON_GetStringValue(C.cJSON_GetObjectItem(params_json, "text"));
        if (text == null)
            text = C.cJSON_GetStringValue(C.cJSON_GetObjectItem(text_document_json, "text"));

        buffer = open_buffer(heap_allocator, uri, text);
        if (buffer.content == null)
        {
            LWARN("didSave: no content for '{}'", uri);
            return;
        }
    }

    dcd_on_save(uri, buffer.content);

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

/// 'text' as a null-terminated string in 'alloc' (cJSON takes C strings).
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
void lsp_did_change_watched_files(C.cJSON* params_json) {
    auto changes_json = C.cJSON_GetObjectItem(params_json, "changes");
    if (!C.cJSON_IsArray(changes_json)) {
        LWARN("didChangeWatchedFiles without a changes array");
        return;
    }

    int size = C.cJSON_GetArraySize(changes_json);
    for (int i = 0; i < size; i++) {
        auto change_json = C.cJSON_GetArrayItem(changes_json, i);
        auto uri_json = C.cJSON_GetObjectItem(change_json, "uri");
        auto type_json = C.cJSON_GetObjectItem(change_json, "type");

        if (!C.cJSON_IsString(uri_json)) {
            LWARN("didChangeWatchedFiles change without a uri");
            continue;
        }
        char* uri = C.cJSON_GetStringValue(uri_json);

        int type = C.cJSON_IsNumber(type_json) ? type_json.valueint : FILE_CHANGE_CHANGED;

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
bool reported_earlier(C.cJSON* changes_json, int index, const char* uri) {
    for (int i = 0; i < index; i++) {
        auto change_json = C.cJSON_GetArrayItem(changes_json, i);
        auto other = C.cJSON_GetStringValue(C.cJSON_GetObjectItem(change_json, "uri"));
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
        lsp_lint(buffer);
        return;
    }

    auto text = read_file_cstring(heap_allocator, uri);
    if (text == null) {
        LWARN("watched file '{}' can't be read", uri);
        return;
    }
    scope(exit) free_cstring(heap_allocator, text);

    LWARN("file changed outside the editor: {}", uri);
    dcd_on_save(uri, text);
}


DOCUMENT_LOCATION lsp_parse_document(C.cJSON* params_json) {
    DOCUMENT_LOCATION document;

    auto text_document_json = C.cJSON_GetObjectItem(params_json, "textDocument");
    auto uri_json = C.cJSON_GetObjectItem(text_document_json, "uri");
    document.uri = C.cJSON_GetStringValue(uri_json);
    if (document.uri == null) {
        LWARN("request without textDocument.uri");
        return DOCUMENT_LOCATION.init;
    }

    auto position_json = C.cJSON_GetObjectItem(params_json, "position");
    auto line_json = C.cJSON_GetObjectItem(position_json, "line");
    if (!C.cJSON_IsNumber(line_json)) {
        LWARN("request for '{}' without a valid position", document.uri);
        return DOCUMENT_LOCATION.init;
    }
    document.line = line_json.valueint;
    auto character_json = C.cJSON_GetObjectItem(position_json, "character");
    if (!C.cJSON_IsNumber(character_json)) {
        LWARN("request for '{}' without a valid position", document.uri);
        return DOCUMENT_LOCATION.init;
    }
    document.character = character_json.valueint;

    return document;
}

void lsp_send_response(int id, C.cJSON* result) {
    auto response = C.cJSON_CreateObject();
    C.cJSON_AddStringToObject(response, "jsonrpc", "2.0");
    C.cJSON_AddNumberToObject(response, "id", id);
    if (result != null)
        C.cJSON_AddItemToObject(response, "result", result);
    else
        C.cJSON_AddNullToObject(response, "result" );

    send_message(response);
}

/**
 * Sends a request to the client ('client/registerCapability').
 *
 * The reply is not tracked: 'handle_request' only logs a response, and
 * nothing in the server waits for one.  'id' must come from
 * 'g_next_request_id' so it can't collide with a client request id.
 */
void lsp_send_request(int id, const(char)* method, C.cJSON* params) {
    auto request = C.cJSON_CreateObject();
    C.cJSON_AddStringToObject(request, "jsonrpc", "2.0");
    C.cJSON_AddNumberToObject(request, "id", id);
    C.cJSON_AddStringToObject(request, "method", method);
    if (params != null)
        C.cJSON_AddItemToObject(request, "params", params);
    else
        C.cJSON_AddNullToObject(request, "params");

    send_message(request);
}

/// Frames 'message' and writes it to stdout.
void send_message(C.cJSON* message) {
    char* output = C.cJSON_PrintUnformatted(message);
    C.cJSON_Minify(output);
    auto len = strlen(output);

    char[] buffer = arena.allocator().alloc!(char)(len + 512);
    buffer[] = '\0';

    sprintf(buffer.ptr, "Content-Length: %u\r\n\r\n%s\0", cast(uint) len, output);
    fwrite(buffer.ptr, 1, strlen(buffer.ptr), stdout);
    fflush(stdout);

    LINFO("sent:\n{}", buffer);
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

void lsp_lint(BUFFER buffer) {
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

    auto params = C.cJSON_CreateObject();
    C.cJSON_AddStringToObject(params, "uri", buffer.uri);
    auto diagnostics = C.cJSON_AddArrayToObject(params, "diagnostics");

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

            auto diagnostic = C.cJSON_CreateObject();
            auto range = C.cJSON_AddObjectToObject(diagnostic, "range");

            auto start_position = C.cJSON_AddObjectToObject(range, "start");
            C.cJSON_AddNumberToObject(start_position, "line", lineNum);
            C.cJSON_AddNumberToObject(start_position, "character", colNum);

            auto end_position = C.cJSON_AddObjectToObject(range, "end");
            C.cJSON_AddNumberToObject(end_position, "line", lineNum);
            C.cJSON_AddNumberToObject(end_position, "character", colNum + 1);

            C.cJSON_AddNumberToObject(diagnostic, "severity", severity);
            C.cJSON_AddStringToObject(diagnostic, "message", p);
            C.cJSON_AddItemToArray(diagnostics, diagnostic);
        }
        pclose(pipe);
    } else {
        LWARN("check: command doesn't work '{}' for '{}'", cmd_to_run, buffer.uri);
    }

    lsp_send_notification("textDocument/publishDiagnostics", params);
}

void lsp_lint_clear(const char *uri) {
    auto params = C.cJSON_CreateObject();
    C.cJSON_AddStringToObject(params, "uri", uri);
    C.cJSON_AddArrayToObject(params, "diagnostics");
    lsp_send_notification("textDocument/publishDiagnostics", params);
}


void lsp_send_notification(const(char)* method, C.cJSON* params)
{
    auto notification = C.cJSON_CreateObject();
    C.cJSON_AddStringToObject(notification, "jsonrpc", "2.0");
    C.cJSON_AddStringToObject(notification, "method", method);
    if (params != null)
        C.cJSON_AddItemToObject(notification, "params", params);
    else
        C.cJSON_AddNullToObject(notification, "params" );

    send_message(notification);
}

// HELPERS


C.cJSON* create_range(C.cJSON* obj, const(char)* id, Position s, Position e)
{
    auto range = C.cJSON_AddObjectToObject(obj, id);
    auto start = C.cJSON_AddObjectToObject(range, "start");
    auto end = C.cJSON_AddObjectToObject(range, "end");
    C.cJSON_AddNumberToObject(start, "line", s.line);
    C.cJSON_AddNumberToObject(start, "character", s.character);
    C.cJSON_AddNumberToObject(end, "line", e.line);
    C.cJSON_AddNumberToObject(end, "character", e.character);
    return range;
}

bool get_range(C.cJSON* obj, Position* start, Position* end)
{
    auto range_json = C.cJSON_GetObjectItem(obj, "range");
    auto start_json = C.cJSON_GetObjectItem(range_json, "start");
    auto end_json = C.cJSON_GetObjectItem(range_json, "end");
    {
        auto line_json = C.cJSON_GetObjectItem(start_json, "line");
        auto char_json = C.cJSON_GetObjectItem(start_json, "character");
        start.line = line_json.valueint;
        start.character = char_json.valueint;
    }
    {
        auto line_json = C.cJSON_GetObjectItem(end_json, "line");
        auto char_json = C.cJSON_GetObjectItem(end_json, "character");
        end.line = line_json.valueint;
        end.character = char_json.valueint;
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

