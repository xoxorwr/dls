module dls.dcd;

// public import dcd.server.dll;

extern(C) void dcd_init();
extern(C) void dcd_add_imports(string[] importPaths);
/// Drops every cached module and every registered import path: the caller has
/// to re-register the paths it still wants (see 'apply_dls_json').
extern(C) void dcd_clear();

extern(C) void dcd_on_open(const(char)* filename, const(char)* content);

extern(C) void dcd_on_save(const(char)* filename, const(char)* content);
/**
 * Non-zero when DCD's cache already holds exactly 'content' for 'filename'.
 * A save reaches the server twice - 'didSave' plus the watched file event for
 * the same write - and this is what tells the second report apart.
 */
extern(C) int dcd_content_unchanged(const(char)* filename, const(char)* content);
extern(C) AutocompleteResponse dcd_complete(const(char)* filename, const(char)* content, int position);


extern(C) SignatureHelpResponse dcd_get_signature(const(char)* filename, const(char)* content, int position);
struct SignatureHelpResponse {
    // Array of SignatureInformation objects
    SignatureInformation[] signatures; 

    // The active signature. If omitted or value lies outside the 
    // range of `signatures` it defaults to zero.
    int activeSignature; // (Optional)

    // The active parameter of the active signature. 
    int activeParameter; // (Optional)
}
struct SignatureInformation {
    // The label of this signature. Will be shown in the UI.
    string label; 

    // The human-readable doc-comment of this signature.
    // Can be a string or MarkupContent (Markdown).
    string documentation; // (Optional)

    // The parameters of this signature.
    ParameterInformation[] parameters; // (Optional)

    // The index of the active parameter. 
    // If provided, this overrides the top-level activeParameter.
    int activeParameter; // (Optional)
}
struct ParameterInformation {
    // The label of this parameter information.
    // Can be a string (the parameter name) or a [start, end] uint offset.
    string label; 

    // The human-readable doc-comment of this parameter.
    string documentation; // (Optional)
}


extern(C) Diagnostic[] dcd_diagnostic(const(char)* buffer);
struct Diagnostic
{
    DiagnosticSeverity severity;
    string message;
    size_t[2] range;
    size_t line;
    size_t column;
    bool use_range;
}

enum DiagnosticSeverity {
    Error = 1,
    Warning = 2,
    Information = 3,
    Hint = 4,
}

struct AutocompleteResponse {
    static struct Completion {
        /**
         * The name of the symbol for a completion, for calltips just the function name.
         */
        string identifier;
        /**
         * The kind of the item. Will be char.init for calltips.
         */
        ubyte kind;
        /**
         * Definition for a symbol for a completion including attributes or the arguments for calltips.
         */
        string definition;
        /**
         * The path to the file that contains the symbol.
         */
        string symbolFilePath;
        /**
         * The byte offset at which the symbol is located or symbol location for symbol searches.
         */
        size_t symbolLocation;
        /**
         * Documentation associated with this symbol.
         */
        string documentation;
        // when changing the behavior here, update README.md
        /**
         * For variables, fields, globals, constants: resolved type or empty if unresolved.
         * For functions: resolved return type or empty if unresolved.
         * For constructors: may be struct/class name or empty in any case.
         * Otherwise (probably) empty.
         */
        string typeOf;
    }

    /**
     * The autocompletion type. (Parameters or identifier)
     */
    string completionType;

    /**
     * The path to the file that contains the symbol.
     */
    string symbolFilePath;

    /**
     * The byte offset at which the symbol is located.
     */
    size_t symbolLocation;

    /**
     * The completions
     */
    Completion[] completions;

    /**
     * Import paths that are registered by the server.
     */
    string[] importPaths;

    /**
     * Symbol identifier
     */
    ulong symbolIdentifier;
}


struct DSymbolInfo
{
    string name;
    ubyte kind;
    size_t[2] range;
    DSymbolInfo[] children;
}

extern(C) DSymbolInfo[] dcd_document_symbols(const(char)* filename, const(char)* content);

/**
 * One semantic token: a byte range in the file, its type and its modifiers.
 * The type and the modifier bits are indices into the token legend the server
 * sends with `initialize` (`enable_semantic_tokens` in `dls/initialize.d`).
 */
struct DSemanticToken
{
    size_t start;
    size_t length;
    ubyte type;
    ubyte modifiers;
}

extern(C) DSemanticToken[] dcd_semantic_tokens(const(char)* filename, const(char)* content);



struct Location
{
    string path;
    size_t position;
}

extern(C) Location[] dcd_definition(const(char)* filename, const(char)* content, int position);
extern(C) export string[] dcd_hover(const(char)* filename, const(char)* content, int position);
