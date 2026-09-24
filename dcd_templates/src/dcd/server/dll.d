module dcd.server.dll;

import std.experimental.logger: warning;
import std.string: fromStringz;
import std.datetime.systime;
import std.experimental.allocator;
import std.experimental.allocator.building_blocks.allocator_list;
import std.experimental.allocator.building_blocks.region;
import std.experimental.allocator.building_blocks.null_allocator;
import std.experimental.allocator.mallocator : Mallocator;
import std.experimental.allocator.gc_allocator : GCAllocator;

import containers.dynamicarray;
import containers.hashset;
import containers.ttree;
import containers.unrolledlist;

import core.runtime;
import core.stdc.stdio;
import core.stdc.stdlib;
import core.stdc.string;
import core.stdc.ctype;
import core.stdc.stdarg;

import dcd.common.messages;
import dcd.server.autocomplete;
import dcd.server.autocomplete.util;

import dparse.ast;
import dparse.lexer;

import dsymbol.scope_;
import dsymbol.signature;
import dsymbol.symbol;
import dsymbol.modulecache;
import dsymbol.utils;
import dsymbol.conversion.first : convertChainToImportPath;


__gshared:

ModuleCache cache;

extern(C) export void dcd_init()
{
    rt_init();
}

extern(C) export void dcd_add_imports(string[] importPaths)
{
    string[] cloned;
    cloned.length = importPaths.length;
    for(int i = 0; i < importPaths.length; i++)
    {
        cloned[i] = importPaths[i].idup;

        warning("adding import: ", cloned[i]);
    }
    cache.addImportPaths(cloned);
}

extern(C) export void dcd_clear()
{
    cache.clear();
}
extern(C) export void dcd_on_open(const(char)* filename, const(char)* content)
{
    import std.algorithm.searching: startsWith;
    auto p = cast(string) fromStringz(filename);
    auto c = cast(ubyte[]) fromStringz(content);
    if (p.startsWith("file://"))
        p = p[7 .. $];
    warning("on_open:", p, (content == null ? 0: c.length) );

    auto im = istring(p);

    // Initial cache — may produce broken circular references
    cache.cacheModule(p, c);
    cache.resolveDeferredTypes(im);

    // Collect deps before re-caching so we have a stable set
    HashSet!istring rg;
    cache.deps_for(im, rg);

    // Pass 1: force re-cache all deps that were cached during the circular
    // import cycle — they may have null types due to recursionGuard hits.
    // Now that im is fully in cache, their secondPass can resolve properly.
    //foreach (it; rg)
    //{
    //    auto ee = cache.getEntryFor(it);
    //    if (ee)
    //    {
    //        warning("force re-cache dep: ", it.data);
    //        cache.cacheModule(it.data, null, true);
    //    }
    //    else
    //    {
    //        warning("cache missing dep: ", it.data);
    //        cache.cacheModule(it.data);
    //    }
    //}

    // Pass 2: now force re-cache im itself — its own resolveTypeFromInitializer
    // symbols (like `self`) were null because deps weren't available.
    // After pass 1, deps are properly resolved so this re-parse will fix them.
    warning("force re-cache self after deps fixed: ", p);
    cache.cacheModule(p, cast(ubyte[]) fromStringz(content), true);
}

extern(C) export void dcd_on_save(const(char)* filename, const(char)* content)
{
    import std.algorithm.searching: startsWith;
    auto p = cast(string) fromStringz(filename);
    if (p.startsWith("file://"))
        p = p[7 .. $];
    warning("on_save:", p);
    auto im = istring(p);

    auto bytes = content is null ? null : cast(ubyte[]) fromStringz(content);

    if (bytes !is null && cache.sourceUnchanged(im, bytes))
    {
        // The save carries the text DCD already has: skip the parse, but still
        // notify the dependents (that is the point of a save here).
        warning("on_save: content unchanged, notifying dependents only");
        cache.refreshDependents(im);
        return;
    }

    //auto e = cache.getEntryFor(im);
    //if(e) e.modificationTime = SysTime.max;

    cache.cacheModule(p, bytes);
}

/**
 * Returns non-zero when the cache already holds exactly 'content' for
 * 'filename'.
 *
 * The server asks this before re-handing DCD a file an editor saved: a save
 * arrives twice (as 'didSave' and as a watched file event for the same
 * write), and the second one would notify every dependent again for nothing.
 * The comparison is DCD's own content hash, so it is exact and lives in one
 * place.
 */
extern(C) export int dcd_content_unchanged(const(char)* filename, const(char)* content)
{
    import std.algorithm.searching: startsWith;
    if (filename is null || content is null)
        return 0;

    auto p = cast(string) fromStringz(filename);
    if (p.startsWith("file://"))
        p = p[7 .. $];

    return cache.sourceUnchanged(istring(p), cast(ubyte[]) fromStringz(content)) ? 1 : 0;
}

extern(C) export AutocompleteResponse dcd_complete(const(char)* filename, const(char)* content, int position)
{
    import std.algorithm.searching: startsWith;
    auto p = cast(string) fromStringz(filename);
    if (p.startsWith("file://"))
        p = p[7 .. $];
    warning("dcd_complete");
    scope(exit) warning("finish");

    AutocompleteRequest request;
    request.fileName = p;
    request.cursorPosition = position;
    request.kind |= RequestKind.autocomplete;
    request.sourceCode = cast(ubyte[]) fromStringz(content);
    auto im = istring(p);

	cache.resolveDeferredTypes(im);

    HashSet!istring rg;
    cache.deps_for(im, rg);
    foreach(it; rg)
    {
	    auto ee = cache.getEntryFor(it);
	    if(ee){

	    	warning("complete in", p, " dep was cached: ", it.data);
	    }
	    else{
	    	warning("complete in", p, " dep not cached: ", it.data);
	    	cache.cacheModule(it);
	    } 
    }

	cache.resolveDeferredTypes(im);

    //auto e = cache.getEntryFor(im);
    //if(e) e.modificationTime = SysTime.max;
    //else cache.cacheModule(im);

    //cache.cacheModule(p, request.sourceCode);


    auto ret = complete(request, cache);
    return ret;
}

struct DSymbolInfo
{
    string name;
    ubyte kind;
    size_t[2] range;
    DSymbolInfo[] children;
}

extern(C) export DSymbolInfo[] dcd_document_symbols(const(char)* filename, const(char)* content)
{
    import containers.ttree : TTree;
    import containers.hashset;
    import dcd.server.autocomplete.util;

    import dparse.lexer;
    import dparse.rollback_allocator;

    import dsymbol.builtin.names;
    import dsymbol.builtin.symbols;
    import dsymbol.conversion;
    import dsymbol.modulecache;
    import dsymbol.scope_;
    import dsymbol.string_interning;
    import dsymbol.symbol;
    //import dsymbol.ufcs;
    import dsymbol.utils;

    import dcd.common.constants;
    import dcd.common.messages;

    DSymbolInfo[] ret;

    AutocompleteRequest request;
    request.fileName = cast(string) fromStringz(filename);
    request.cursorPosition = 0;
    request.kind |= RequestKind.autocomplete;
    request.sourceCode = cast(ubyte[]) fromStringz(content);

    if (request.sourceCode == null || request.sourceCode.length == 0) return ret;

    LexerConfig config;
    config.fileName = "";
    auto sc = StringCache(request.sourceCode.length.optimalBucketCount);
    auto tokenArray = getTokensForParser(cast(ubyte[]) request.sourceCode, config, &sc);
    RollbackAllocator rba;
    auto pair = generateAutocompleteTrees(tokenArray, &rba, -1, cache);
    scope(exit) pair.destroy();


    bool exist(DSymbol* it)
    {
        foreach(ref s; ret)
        {
            if (s.name == it.name && s.kind == it.kind) return true;
        }
        return false;
    }


    void check(DSymbol* it, ref int p, DSymbolInfo* info)
    {
        //for (int i = 0; i < p; i++)
        //fprintf(stderr, " ");
        //fprintf(stderr, "loc: %ld k: %c sym: %.*s\n", it.location, cast(char) it.kind, it.name.length, it.name.ptr);

        p += 1;


        info.name = it.name;
        info.range[0] = it.location;

        if (it.location_end == 0)
            info.range[1] = it.location + it.name.length;
        else
            info.range[1] = it.location_end;
        info.kind = it.kind;

        foreach(sym; it.opSlice())
        {
            if (sym.symbolFile != "stdin") continue;
            if (sym.generated) continue;
            if (
                (sym.kind == CompletionKind.functionName
                || sym.kind == CompletionKind.enumName
                || sym.kind == CompletionKind.structName
                || sym.kind == CompletionKind.unionName
                ) == false
            )
                continue;

            DSymbolInfo child;
            check(sym, p, &child);
            info.children ~= child;
       }
       p -= 1;
    }

    int pos = 0;
    foreach (symbol; pair.scope_.symbols)
    {
        if (symbol.symbolFile != "stdin") continue;
        if (symbol.generated) continue;
        DSymbolInfo info;
        check(symbol, pos, &info);
        ret ~= info;
    }

    return ret;
}

/**
 * One semantic token: the byte range in the file a client should colour, and
 * what it is.  `type` and `modifiers` are indices into the legend the client
 * was given with `initialize` (see `enable_semantic_tokens` in
 * `server/dls/initialize.d`, which lists the names in this order).
 */
struct DSemanticToken
{
    size_t start;
    size_t length;
    ubyte type;
    ubyte modifiers;
}

/**
 * Token types `dcd_semantic_tokens` reports.  The values are legend indices,
 * so the client's legend has to list these names in this order; the ones no
 * symbol maps to yet are kept anyway, so the indices stay readable.
 *
 * Only names are reported: keywords, literals, comments and operators are
 * what the client's own grammar already colours, and what it cannot know is
 * which symbol a name resolves to.  The lexical entries stay in the legend so
 * the indices do not move.
 */
enum DSemanticTokenType : ubyte
{
    none = ubyte.max,
    namespace_ = 0,
    type = 1,
    class_ = 2,
    enum_ = 3,
    interface_ = 4,
    struct_ = 5,
    typeParameter = 6,
    /// Nothing maps here yet: DCD records a parameter as a variable.
    parameter = 7,
    variable = 8,
    property = 9,
    enumMember = 10,
    function_ = 12,
    keyword = 15,
    /// Nothing maps here yet: D's modifiers are keywords to the lexer.
    modifier = 16,
    comment = 17,
    string = 18,
    number = 19,
    operator = 21,
}

/// Token modifiers, as bit positions in the client's modifier legend.
enum DSemanticTokenModifier : ubyte
{
    declaration = 0,
    readonly = 2,
    defaultLibrary = 9,
}

alias DSemanticModifiers = ubyte;

/// The token type a symbol's `CompletionKind` is shown as.
private ubyte semanticTokenTypeOf(CompletionKind kind) pure nothrow @safe @nogc
{
    switch (kind)
    {
    case CompletionKind.className:
        return DSemanticTokenType.class_;
    case CompletionKind.interfaceName:
        return DSemanticTokenType.interface_;
    case CompletionKind.structName:
    case CompletionKind.unionName:
        return DSemanticTokenType.struct_;
    case CompletionKind.enumName:
        return DSemanticTokenType.enum_;
    case CompletionKind.enumMember:
        return DSemanticTokenType.enumMember;
    case CompletionKind.variableName:
        return DSemanticTokenType.variable;
    case CompletionKind.memberVariableName:
        return DSemanticTokenType.property;
    case CompletionKind.functionName:
    case CompletionKind.ufcsName:
        return DSemanticTokenType.function_;
    case CompletionKind.packageName:
    case CompletionKind.moduleName:
        return DSemanticTokenType.namespace_;
    case CompletionKind.templateName:
    case CompletionKind.mixinTemplateName:
    case CompletionKind.aliasName:
        return DSemanticTokenType.type;
    case CompletionKind.typeTmpParam:
    case CompletionKind.variadicTmpParam:
        return DSemanticTokenType.typeParameter;
    case CompletionKind.keyword:
        // The builtin properties (`sizeof`, `init`, `mangleof`, ...).
        return DSemanticTokenType.property;
    default:
        return DSemanticTokenType.none;
    }
}

/**
 * The symbol the token chain ending at 'parserTokens[parserIndex]' resolves
 * to, or null.
 *
 * The scope tree only holds the names that are visible where they are
 * written, which is what a declaration and a plain use need; a member after a
 * `.` (`state.valuea`) is resolved through the expression walk instead, the
 * same way hover does it.  Shared by every walk that classifies the token
 * stream this way (semantic tokens, unused-symbol detection).
 */
private DSymbol* resolveTokenSymbol(const(Token)[] parserTokens, size_t parserIndex,
    Scope* symbolScope)
{
    auto expression = getExpression(parserTokens[0 .. parserIndex + 1]);
    auto symbols = getSymbolsByTokenChain(symbolScope, expression,
        parserTokens[parserIndex].index, CompletionType.location);
    return symbols.length == 0 ? null : symbols[0];
}

/**
 * The symbol an identifier token names and what that symbol is.
 */
private ubyte identifierTokenType(const(Token) token, const(Token)[] parserTokens,
    size_t parserIndex, Scope* symbolScope, out DSemanticModifiers modifiers)
{
    auto symbol = resolveTokenSymbol(parserTokens, parserIndex, symbolScope);
    if (symbol is null)
        return DSemanticTokenType.none;

    // A function with a body records the end of its name as its location
    // (`FirstPass.visit(FunctionDeclaration)` puts its scope there) instead of
    // the name's start, so both spellings have to mean "declaration".
    immutable bool functionName = symbol.kind == CompletionKind.functionName
        || symbol.kind == CompletionKind.ufcsName;
    if (symbol.location == token.index
        || (functionName && token.text.length > 0
            && symbol.location == token.index + token.text.length))
        modifiers |= 1 << DSemanticTokenModifier.declaration;
    // Anything that is not part of the file being coloured comes from a
    // module the client did not ask about - `object.d` for `string`, an
    // import path for a project module - which is what the modifier is for.
    if (symbol.symbolFile.length > 0 && symbol.symbolFile != "stdin")
        modifiers |= 1 << DSemanticTokenModifier.defaultLibrary;
    if (symbol.kind == CompletionKind.enumMember
        || symbol.kind == CompletionKind.typeTmpParam
        || symbol.kind == CompletionKind.variadicTmpParam)
        modifiers |= 1 << DSemanticTokenModifier.readonly;

    return semanticTokenTypeOf(symbol.kind);
}

/**
 * Classifies the names of the file: what each resolves to, so a client can
 * colour the parts its grammar cannot know (which name is a type, which is a
 * variable, which member of what).  A name no symbol is found for is left
 * out, and the client's grammar keeps colouring it.
 */
extern(C) export DSemanticToken[] dcd_semantic_tokens(const(char)* filename, const(char)* content)
{
    import containers.hashset;
    import dcd.server.autocomplete.util;

    import dparse.lexer;
    import dparse.rollback_allocator;

    import dsymbol.builtin.names;
    import dsymbol.builtin.symbols;
    import dsymbol.conversion;
    import dsymbol.modulecache;
    import dsymbol.scope_;
    import dsymbol.string_interning;
    import dsymbol.symbol;
    import dsymbol.utils;

    DSemanticToken[] ret;
    if (content is null)
        return ret;
    auto source = cast(ubyte[]) fromStringz(content);
    if (source.length == 0)
        return ret;

    auto sc = StringCache(source.length.optimalBucketCount);

    // The parser's tokens and the scope tree.  The whole file is parsed
    // (`parseWholeFile`): the autocomplete parser otherwise keeps only the
    // block a cursor sits in, since nothing behind a cursor can be completed -
    // but this walk has to know every name, including the locals of blocks no
    // completion could be about.  The cursor still marks where the file is
    // being typed, so the end of it keeps the recovery for an unfinished
    // statement; resolving a token then happens by position
    // (`getScopeByCursor`), which is where the name it names is visible.
    LexerConfig parserConfig;
    parserConfig.fileName = "";
    auto parserTokens = getTokensForParser(source, parserConfig, &sc);

    RollbackAllocator rba;
    auto pair = generateAutocompleteTrees(parserTokens, &rba, source.length, cache, true);
    scope(exit) pair.destroy();

    // Names are all this reports (see `DSemanticTokenType`), and the parser's
    // tokens hold every one of them, so there is no second lexer pass.
    foreach (i, token; parserTokens)
    {
        if (token.type != tok!"identifier" || token.text.length == 0)
            continue;
        DSemanticModifiers modifiers;
        auto type = identifierTokenType(token, parserTokens, i, pair.scope_, modifiers);
        if (type == DSemanticTokenType.none)
            continue;
        ret ~= DSemanticToken(token.index, token.text.length, type, modifiers);
    }

    return ret;
}

/// Kinds `dcd_unused_symbols` reports.
enum DUnusedKind : ubyte { import_ = 0, parameter = 1 }

/**
 * One unused import name/binding or unused parameter: the span to
 * underline, and - for an import only - the byte range a "remove it" code
 * action deletes (see `dcd_unused_symbols` for how a comma-separated list is
 * handled: sometimes that is the whole statement, sometimes just the one
 * item and an adjacent comma).
 */
struct DUnusedSymbol
{
    size_t start;
    size_t length;
    DUnusedKind kind;
    string name;
    size_t removeStart;
    size_t removeLength;
}

/**
 * One import name/binding or parameter this file declares, collected by
 * `UnusedCandidateVisitor` - a place the token-stream pass in
 * `dcd_unused_symbols` checks for a use, and what to report if none is
 * found.  `start` doubles as that pass's key for "this token is the
 * declaration itself, not a use of it".
 */
private struct UnusedCandidate
{
    size_t start;
    size_t length;
    DUnusedKind kind;
    string name;
    size_t removeStart;
    size_t removeLength;
    bool used;

    // The comparison key a use is matched against, filled in differently per
    // kind.  A whole-module import matches by the module it names (any
    // symbol used from that module counts, qualified or not, via
    // `modulePath`); a selective binding or a parameter matches by the exact
    // resolved symbol via `target` (`matchByTarget`) - a parameter's own is
    // captured lazily, the first time the token-stream pass reaches its
    // declaration token.
    string modulePath;
    DSymbol* target;
    bool matchByTarget;
}

/// The byte offset just past `token` - text tokens (identifiers, literals)
/// carry their own length, static ones (keywords, punctuation) spell it.
private size_t tokenEnd(const Token token)
{
    return token.index + (token.text.length > 0 ? token.text.length : str(token.type).length);
}

/// Whether `fn` is written `override` - checked in both positions the
/// grammar allows it: a prefix storage class (`override void foo()`, by far
/// the common style) or a postfix member-function attribute (`void foo() override`).
private bool hasOverride(const(StorageClass)[] storageClasses,
    const(MemberFunctionAttribute)[] memberAttrs)
{
    foreach (s; storageClasses)
        if (s.token.type == tok!"override")
            return true;
    foreach (a; memberAttrs)
        if (a.tokenType == tok!"override")
            return true;
    return false;
}

/// Whether `body_` is an actual body (braces or `=> expr`), not a bare `;`
/// declaration (interface method, abstract, `extern`) - `FunctionBody` wraps
/// all three shapes, so a non-null `FunctionBody` alone does not mean there
/// is anything to walk for uses.
private bool hasRealBody(const FunctionBody body_)
{
    return body_ !is null && body_.missingFunctionBody is null;
}

/**
 * The byte range a code action deletes to drop one comma-separated item
 * (spanning `itemTokens`) out of a declaration (spanning `declTokens`, with
 * overall bounds `[declStart, declEnd)`): the item's own tokens plus one
 * adjacent comma - the one after it, or the one before it when this is the
 * last of several - or, when there is no comma at all (the only item), the
 * whole declaration.
 */
private void listItemRemoval(const(Token)[] declTokens, const(Token)[] itemTokens,
    size_t declStart, size_t declEnd, out size_t removeStart, out size_t removeLength)
{
    immutable itemStart = itemTokens[0].index;
    immutable itemEnd = tokenEnd(itemTokens[$ - 1]);

    foreach (t; declTokens)
    {
        if (t.index < itemEnd)
            continue;
        if (t.type == tok!",")
        {
            removeStart = itemStart;
            removeLength = tokenEnd(t) - itemStart;
            return;
        }
    }

    size_t precedingComma = size_t.max;
    foreach (t; declTokens)
    {
        if (t.index >= itemStart)
            break;
        if (t.type == tok!",")
            precedingComma = t.index;
    }
    if (precedingComma != size_t.max)
    {
        removeStart = precedingComma;
        removeLength = itemEnd - precedingComma;
        return;
    }

    removeStart = declStart;
    removeLength = declEnd - declStart;
}

/**
 * Collects every module-level import name/binding and every parameter of a
 * function/constructor that has a body, as `UnusedCandidate`s.
 *
 * Only module-level imports are considered - the walk still descends into
 * function bodies (for nested functions and their own parameters), it just
 * does not record an import found inside one.  `public import` is skipped
 * entirely (meant for re-export, not local use), detected from the enclosing
 * `Declaration`'s own attributes - a narrower check than DCD's own
 * protection stack (which also tracks `public:` blocks), not worth
 * replicating in full here.
 */
private final class UnusedCandidateVisitor : ASTVisitor
{
    UnusedCandidate[] candidates;

    alias visit = ASTVisitor.visit;

    override void visit(const Declaration dec)
    {
        // `override` (like `public`) is parsed as a declaration-prefix
        // Attribute, not as a FunctionDeclaration.storageClasses/
        // memberFunctionAttributes entry - see dparse's parseAttribute.
        immutable wasPublic = declarationIsPublic;
        immutable wasOverride = declarationIsOverride;
        foreach (attr; dec.attributes)
        {
            if (attr.attribute.type == tok!"public")
                declarationIsPublic = true;
            else if (attr.attribute.type == tok!"override")
                declarationIsOverride = true;
        }
        super.visit(dec);
        declarationIsPublic = wasPublic;
        declarationIsOverride = wasOverride;
    }

    override void visit(const ImportDeclaration importDecl)
    {
        if (!declarationIsPublic && functionDepth == 0)
        {
            foreach (single; importDecl.singleImports)
            {
                if (single is null || single.identifierChain is null
                    || single.identifierChain.identifiers.length == 0)
                    continue;
                addWholeModuleImport(importDecl, single);
            }
            if (importDecl.importBindings !is null
                && importDecl.importBindings.singleImport !is null
                && importDecl.importBindings.singleImport.identifierChain !is null)
                addSelectiveImports(importDecl, importDecl.importBindings);
        }
        // Nothing nested is worth visiting inside an import statement.
    }

    override void visit(const FunctionDeclaration fn)
    {
        if (hasRealBody(fn.functionBody) && fn.parameters !is null && !declarationIsOverride
            && !hasOverride(fn.storageClasses, fn.memberFunctionAttributes))
            addParameters(fn.parameters);
        functionDepth++;
        super.visit(fn);
        functionDepth--;
    }

    override void visit(const Constructor ctor)
    {
        if (hasRealBody(ctor.functionBody) && ctor.parameters !is null)
            addParameters(ctor.parameters);
        functionDepth++;
        super.visit(ctor);
        functionDepth--;
    }

    private bool declarationIsPublic;
    private bool declarationIsOverride;
    private int functionDepth;

    private void addParameters(const Parameters parameters)
    {
        foreach (p; parameters.parameters)
        {
            if (p.name.text.length == 0 || p.name.text[0] == '_')
                continue;
            UnusedCandidate c;
            c.start = p.name.index;
            c.length = p.name.text.length;
            c.kind = DUnusedKind.parameter;
            c.name = p.name.text.idup; // survives past this call, unlike a lexer-owned slice
            c.matchByTarget = true; // 'target' is filled in lazily
            candidates ~= c;
        }
    }

    private void addWholeModuleImport(const ImportDeclaration importDecl, const SingleImport single)
    {
        immutable path = convertChainToImportPath(single.identifierChain);
        auto modulePath = cache.resolveImportLocation(path);
        if (modulePath is null)
            return; // unresolvable - nothing to compare a use against

        const nameToken = single.rename == tok!"" ? single.identifierChain.identifiers[$ - 1] : single.rename;

        // A rename introduces its own binding, so that alias is what a
        // "remove/underline this" message should name. An un-renamed import
        // has no binding of its own though - `nameToken` is just the last
        // segment of the chain - so the message names the whole qualified
        // path ('rt.io.binary', not the ambiguous-when-several-modules-
        // share-a-tail 'binary') instead.
        string displayName;
        if (single.rename == tok!"")
        {
            import std.array : appender;
            auto app = appender!string();
            foreach (i, ident; single.identifierChain.identifiers)
            {
                app.put(ident.text);
                if (i + 1 < single.identifierChain.identifiers.length)
                    app.put(".");
            }
            displayName = app.data;
        }
        else
            displayName = nameToken.text.idup;

        UnusedCandidate c;
        c.start = nameToken.index;
        c.length = nameToken.text.length;
        c.kind = DUnusedKind.import_;
        c.name = displayName;
        c.modulePath = modulePath;
        listItemRemoval(importDecl.tokens, single.tokens, importDecl.startIndex, importDecl.endIndex,
            c.removeStart, c.removeLength);
        candidates ~= c;
    }

    private void addSelectiveImports(const ImportDeclaration importDecl, const ImportBindings bindings)
    {
        immutable path = convertChainToImportPath(bindings.singleImport.identifierChain);
        auto modulePath = cache.resolveImportLocation(path);
        if (modulePath is null)
            return;
        auto moduleSymbol = cache.cacheModule(modulePath);
        if (moduleSymbol is null)
            return;

        foreach (bind; bindings.importBinds)
        {
            immutable bool renamed = bind.right != tok!"";
            immutable origName = renamed ? bind.right.text : bind.left.text;
            if (origName.length == 0 || bind.left.text.length == 0)
                continue;
            auto target = moduleSymbol.getFirstPartNamed(internString(origName));
            if (target is null)
                continue;

            UnusedCandidate c;
            c.start = bind.left.index;
            c.length = bind.left.text.length;
            c.kind = DUnusedKind.import_;
            c.name = bind.left.text.idup; // ditto
            c.target = target;
            c.matchByTarget = true;
            listItemRemoval(importDecl.tokens, bind.tokens, importDecl.startIndex, importDecl.endIndex,
                c.removeStart, c.removeLength);
            candidates ~= c;
        }
    }
}

/**
 * The imports and parameters this file declares but never uses again.
 *
 * Declarations are read from the syntax tree (`UnusedCandidateVisitor`), not
 * from the resolved symbol tree: a plain (non-renamed) import's `DSymbol`
 * carries no real in-file position (`location` is 0, the name is a sentinel -
 * see `dsymbol.conversion.first`'s import visitor), so there is nothing
 * there to underline or key a removal edit from.
 *
 * Whether a candidate is used is answered by one linear pass over the same
 * token-and-resolve walk `dcd_semantic_tokens` already does: for every
 * identifier token, resolve it, and it is either a candidate's own
 * declaration token (by byte offset - skip it, and for a parameter this is
 * also where its comparison pointer is captured) or a use, checked against
 * every candidate (a handful, K) rather than inserted into a map sized by
 * the file's identifier count (N, in the thousands) - O(n*K) with a trivial
 * per-comparison cost, and no allocation beyond the result itself.
 */
extern(C) export DUnusedSymbol[] dcd_unused_symbols(const(char)* filename, const(char)* content)
{
    import containers.hashset;
    import dcd.server.autocomplete.util;

    import dparse.lexer;
    import dparse.rollback_allocator;

    import dsymbol.builtin.names;
    import dsymbol.builtin.symbols;
    import dsymbol.conversion;
    import dsymbol.modulecache;
    import dsymbol.scope_;
    import dsymbol.string_interning;
    import dsymbol.symbol;
    import dsymbol.utils;

    DUnusedSymbol[] ret;
    if (content is null)
        return ret;
    auto source = cast(ubyte[]) fromStringz(content);
    if (source.length == 0)
        return ret;

    auto sc = StringCache(source.length.optimalBucketCount);

    LexerConfig parserConfig;
    parserConfig.fileName = "";
    auto parserTokens = getTokensForParser(source, parserConfig, &sc);

    RollbackAllocator rba;
    auto pair = generateAutocompleteTrees(parserTokens, &rba, source.length, cache, true);
    scope(exit) pair.destroy();

    auto visitor = new UnusedCandidateVisitor();
    pair.syntaxTree.accept(visitor);
    auto candidates = visitor.candidates;
    if (candidates.length == 0)
        return ret;

    foreach (i, token; parserTokens)
    {
        if (token.type != tok!"identifier" || token.text.length == 0)
            continue;

        // Is this token one of the candidates' own declaration tokens?
        bool isDeclaration;
        foreach (ref c; candidates)
        {
            if (c.start != token.index)
                continue;
            isDeclaration = true;
            if (c.kind == DUnusedKind.parameter && c.target is null)
                c.target = resolveTokenSymbol(parserTokens, i, pair.scope_);
            break;
        }
        if (isDeclaration)
            continue;

        auto symbol = resolveTokenSymbol(parserTokens, i, pair.scope_);
        if (symbol is null)
            continue;

        foreach (ref c; candidates)
        {
            if (c.used)
                continue;
            if (c.matchByTarget)
            {
                if (c.target !is null && c.target is symbol)
                    c.used = true;
            }
            else if (c.modulePath.length > 0 && symbol.symbolFile == c.modulePath)
            {
                c.used = true;
            }
        }
    }

    foreach (c; candidates)
    {
        if (c.used)
            continue;
        auto d = DUnusedSymbol(c.start, c.length, c.kind, c.name);
        if (c.kind == DUnusedKind.import_)
        {
            d.removeStart = c.removeStart;
            d.removeLength = c.removeLength;
            // No blank line left behind when the whole statement goes.
            immutable past = d.removeStart + d.removeLength;
            if (past < source.length && source[past] == '\n')
                d.removeLength++;
            else if (past + 1 < source.length && source[past] == '\r' && source[past + 1] == '\n')
                d.removeLength += 2;
        }
        ret ~= d;
    }

    return ret;
}

/**
 * One folding range, as the zero-based line numbers a client collapses from
 * and to.  `kind` is the LSP FoldingRangeKind ("comment") or null for a plain
 * bracket pair: it is what makes a client show comment folds apart from code.
 */
struct DCFoldingRange
{
    size_t startLine;
    size_t endLine;
    const(char)* kind;
}

/// Whether a comment token is a `//` one rather than `/* */` or `/+ +/`.
private bool isLineComment(scope const(char)[] text) pure nothrow @safe @nogc
{
    return text.length >= 2 && text[0] == '/' && text[1] == '/';
}

/// How many lines a token's text covers: the height of a block comment.
private size_t countNewlines(scope const(char)[] text) pure nothrow @safe @nogc
{
    size_t count;
    foreach (c; text)
        if (c == '\n')
            count++;
    return count;
}

/**
 * The block structure of a file for `textDocument/foldingRange`.
 *
 * The lexer decides what is structure: a bracket is only seen where DCD put
 * one, and a string literal (`q{}`, `r"..."`, backticks), a comment or a
 * character literal arrives as a single token, so the brackets written inside
 * them never pass for code.
 *
 * A bracket whose partner has not been typed yet is left alone rather than
 * guessed at: the file is usually being edited.
 *
 * Ranges come back sorted, outermost first: clients reject a list where a
 * folded range starts before the one containing it.
 */
extern(C) export DCFoldingRange[] dcd_folding_ranges(const(char)* filename, const(char)* content)
{
    import dparse.lexer;
    import std.algorithm : sort;

    DCFoldingRange[] ret;
    if (content is null)
        return ret;
    auto source = cast(ubyte[]) fromStringz(content);
    if (source.length == 0)
        return ret;

    auto sc = StringCache(source.length.optimalBucketCount);

    // Comments travel through here as their own tokens (the parser folds them
    // into trivia instead, which is why this walks the lexer directly).
    LexerConfig config;
    config.fileName = "";
    config.whitespaceBehavior = WhitespaceBehavior.skip;
    auto lexer = DLexer(source, config, &sc);

    struct OpenBracket
    {
        IdType type;
        size_t line;
    }
    OpenBracket[] stack;

    // A run of whole line `//` comments that is still going.
    size_t runStart;
    size_t runEnd;
    bool runOpen;

    void flushRun()
    {
        if (runOpen && runEnd > runStart)
            ret ~= DCFoldingRange(runStart - 1, runEnd - 1, "comment");
        runOpen = false;
    }

    while (!lexer.empty)
    {
        auto token = lexer.front;
        lexer.popFront();

        if (token.type == tok!"comment")
        {
            auto endLine = token.line + countNewlines(token.text);
            if (endLine > token.line)
            {
                // A block comment over several lines folds on its own.
                flushRun();
                ret ~= DCFoldingRange(token.line - 1, endLine - 1, "comment");
            }
            else if (isLineComment(token.text))
            {
                // Consecutive `//` lines are one region.
                if (runOpen && token.line == runEnd + 1)
                    runEnd = token.line;
                else
                {
                    flushRun();
                    runStart = token.line;
                    runEnd = token.line;
                    runOpen = true;
                }
            }
            else
                flushRun();
            continue;
        }

        auto type = token.type;
        if (type == tok!"{" || type == tok!"(" || type == tok!"[")
            stack ~= OpenBracket(type, token.line);
        else if (type == tok!"}" || type == tok!")" || type == tok!"]")
        {
            auto want = type == tok!"}" ? tok!"{" : (type == tok!")" ? tok!"(" : tok!"[");

            // A bracket left dangling above the match does not have to hide
            // it: look down the stack and drop whatever was left unclosed.
            size_t match = stack.length;
            while (match > 0 && stack[match - 1].type != want)
                match--;

            if (match > 0)
            {
                auto open = stack[match - 1];
                stack.length = match - 1;
                if (token.line > open.line)
                    ret ~= DCFoldingRange(open.line - 1, token.line - 1, null);
            }
        }
    }
    flushRun();

    sort!((a, b) => a.startLine != b.startLine
        ? a.startLine < b.startLine
        : a.endLine > b.endLine)(ret);

    return ret;
}

struct Location
{
    string path;
    size_t position;
}

extern(C) export Location[] dcd_definition(const(char)* filename, const(char)* content, int position)
{
    import std.algorithm;
    import std.array;
    import containers.ttree : TTree;
    import containers.hashset;
    import dcd.server.autocomplete.util;

    import dparse.lexer;
    import dparse.rollback_allocator;

    import dsymbol.builtin.names;
    import dsymbol.builtin.symbols;
    import dsymbol.conversion;
    import dsymbol.modulecache;
    import dsymbol.scope_;
    import dsymbol.string_interning;
    import dsymbol.symbol;
    // import dsymbol.ufcs;
    import dsymbol.utils;

    import dcd.common.constants;
    import dcd.common.messages;

    auto p = cast(string) fromStringz(filename);
    if (p.startsWith("file://"))
        p = p[7 .. $];

    AutocompleteRequest request;
    request.fileName = p;
    request.cursorPosition = position;
    request.kind |= RequestKind.autocomplete;
    request.sourceCode = cast(ubyte[]) fromStringz(content);

    auto im = istring(p);
    cache.resolveDeferredTypes(im);

    HashSet!istring rg;
    cache.deps_for(im, rg);
    foreach(it; rg)
    {
        auto ee = cache.getEntryFor(it);
        if (!ee)
            cache.cacheModule(it);
    }
    cache.resolveDeferredTypes(im);

    RollbackAllocator rba;
    auto sc = StringCache(request.sourceCode.length.optimalBucketCount);
    SymbolStuff stuff = getSymbolsForCompletion(request, CompletionType.location, &rba, sc, cache);
    scope(exit) stuff.destroy();

    Location[] ret;
    if (stuff.symbols.length > 0)
    {
        stuff.symbols.sort!((a, b) {
            if (a.symbolFile != b.symbolFile) return a.symbolFile < b.symbolFile;
            return a.location < b.location;
        });

        foreach(sym; stuff.symbols.uniq!((a, b) => a.symbolFile == b.symbolFile && a.location == b.location))
        {
            //fprintf(stderr, "found: %.*s  at: %.*s -> %lu\n", sym.name.length, sym.name.ptr, sym.symbolFile.length, sym.symbolFile.ptr, sym.location);
            ret ~= Location(sym.symbolFile, sym.location);
        }
    }
    return ret;
}


string from_kind(CompletionKind kind)
{
    switch (kind)
    {
        case CompletionKind.structName: return "struct";
        case CompletionKind.className: return "class";
        case CompletionKind.interfaceName: return "interface";
        case CompletionKind.enumName: return "enum";
        case CompletionKind.unionName: return "union";
        case CompletionKind.aliasName: return "alias";
        default: return "";
    }
}

extern(C) export string[] dcd_hover(const(char)* filename, const(char)* content, int position)
{
    import std.algorithm;
    import std.array;
    import containers.ttree : TTree;
    import containers.hashset;
    import dcd.server.autocomplete.util;

    import dparse.lexer;
    import dparse.rollback_allocator;

    import dsymbol.builtin.names;
    import dsymbol.builtin.symbols;
    import dsymbol.conversion;
    import dsymbol.modulecache;
    import dsymbol.scope_;
    import dsymbol.string_interning;
    import dsymbol.symbol;
    // import dsymbol.ufcs;
    import dsymbol.utils;

    import dcd.common.constants;
    import dcd.common.messages;

    auto p = cast(string) fromStringz(filename);
    if (p.startsWith("file://"))
        p = p[7 .. $];

    AutocompleteRequest request;
    request.fileName = p;
    request.cursorPosition = position;
    request.kind |= RequestKind.autocomplete;
    request.sourceCode = cast(ubyte[]) fromStringz(content);

    auto im = istring(p);
    cache.resolveDeferredTypes(im);

    HashSet!istring rg;
    cache.deps_for(im, rg);
    foreach(it; rg)
    {
        auto ee = cache.getEntryFor(it);
        if (!ee)
            cache.cacheModule(it);
    }
    cache.resolveDeferredTypes(im);

    RollbackAllocator rba;
    auto sc = StringCache(request.sourceCode.length.optimalBucketCount);
    SymbolStuff stuff = getSymbolsForCompletion(request, CompletionType.location, &rba, sc, cache);
    scope(exit) stuff.destroy();

    string[] ret;
    if (stuff.symbols.length > 0)
    {
        foreach(sym; stuff.symbols.uniq)
        {
            warning("found: ", sym.name, " k:", sym.kind,"  at: ",sym.symbolFile," -> ", sym.location,"\n");
            if (sym.type)
                warning("  type: ", sym.type.name, " k:", sym.type.kind,"  at: ",sym.type.symbolFile," -> ", sym.type.location,"\n");

            string value;


            auto ms = cache.getEntryFor(sym.symbolFile);
            if (ms && ms.symbol && ms.symbol.renderedText())
            {
                value ~= ms.symbol.renderedText().text;
                value ~= "\n";
            }

            if (auto signature = sym.signature())
            {
                // A callable's line is rendered from the signature's parts,
                // which is also where signature help reads them from; an
                // aggregate's is its rendered body, when it has one (a
                // non-templated `className` never does - see `extra`'s doc
                // in `symbol.d`).
                value ~= signature.body.length > 0
                    ? signature.body : renderSignature(signature).label;
            }
            else
            {
                if (sym.kind == CompletionKind.enumName)
                {
                    value ~= "enum " ~ sym.name ~ "\n{\n";
                    foreach (child; sym.opSlice())
                    {
                        if (child.kind == CompletionKind.enumMember)
                        {
                            value ~= "    " ~ child.name ~ ",\n"; //", //ct:" ~ child.callTip[] ~ "\n";

                            //foreach (it; child.opSlice[])
                            //{
                            //	value ~= "        " ~ it.name ~ ",\n";
                            //}
                        }
                    }
                    value ~= "}";
                }
                else if (sym.kind == CompletionKind.className)
                    value ~= "class";
                else if (sym.kind == CompletionKind.interfaceName)
                    value ~= "interface";
                else if (sym.kind == CompletionKind.keyword)
                    value ~= "keyword";
                else if (sym.kind == CompletionKind.variableName || sym.kind == CompletionKind.memberVariableName)
                {
                    if (sym.type != null)
                    {
                        import dsymbol.conversion.second : typeSwap;
                        DSymbol* type = cast(DSymbol*) sym.type;
                        // Same rule as completion: through same-file aliases to
                        // the terminal type (`M value` hovers as `int value;`,
                        // while `string` keeps its imported name).
                        size_t aliasDepth = 0;
                        while (type !is null
                            && type.kind == CompletionKind.aliasName
                            && type.type !is null && aliasDepth++ < 16
                            && type.symbolFile.length > 0
                            && type.symbolFile == sym.symbolFile)
                            type = type.type;
                        string typeName = type is null ? "" : type.formatType();

                        switch(type.kind) {
                            case CompletionKind.structName: typeName = "struct " ~ typeName; break; 
                            case CompletionKind.enumName: typeName = "enum " ~ typeName; break; 
                            case CompletionKind.unionName: typeName = "union " ~ typeName; break; 
                            default:
                        }
                        
                        typeSwap(type);
                        if (type && typeName.length == 0)
                        {
                            typeName = type.formatType();

                            switch(type.kind) {
                                case CompletionKind.structName: typeName = "struct " ~ typeName; break; 
                                case CompletionKind.enumName: typeName = "enum " ~ typeName; break; 
                                case CompletionKind.unionName: typeName = "union " ~ typeName; break; 
                                default:
                            }
                        }
                        
                        string storagePrefix = parameterStorageClassPrefix(sym);
                        if (typeName.length > 0){
                            value ~= storagePrefix ~ declaredTypeQualifierWrap(sym, typeName) ~ " " ~ sym.name ~ ";";
                        }
                        else{
                            value ~= storagePrefix
                                ~ declaredTypeQualifierWrap(sym, sym.type.formatType())
                                ~ " " ~ sym.name ~ ";";


                        }
                    } else {
                        value ~= "??? " ~ sym.name ~ ";";
                    }
                }
                else if (sym.kind == CompletionKind.aliasName)
                {
                    value ~= "alias " ~ sym.name ~ " => ";
                    if (sym.type != null)
                    {
                        import dsymbol.conversion.second : typeSwap;
                        DSymbol* type = cast(DSymbol*) sym.type;
                        // Follow the whole chain: `alias M = getMember(...)`
                        // lands on another alias (`bar`), and the useful type
                        // is at the end (`int`), not the next hop.
                        size_t depth = 0;
                        while (type !is null
                            && type.kind == CompletionKind.aliasName
                            && type.type !is null && depth++ < 8)
                            type = type.type;
                        string typeName = type is null ? "" : type.formatType();

                        typeSwap(type);
                        if (type && typeName.length == 0)
                            typeName = type.formatType();

                        if (typeName.length > 0)
                            value ~= declaredTypeQualifierWrap(sym, typeName);
                        else
                            value ~= declaredTypeQualifierWrap(sym, sym.type.formatType());
                    }
                }
                else if (sym.kind == CompletionKind.enumMember)
                {
                    if (sym.type && sym.type.kind == CompletionKind.enumName)
                        value ~= "enum " ~ sym.type.name ~ "." ~ sym.name;
                    else
                        value ~= "enum member " ~ sym.name;
                }
            }
            ret ~= value;
        }
    }
    return ret;
}



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


ModuleCache cache_scanner;
extern(C) Diagnostic[] dcd_diagnostic(const(char)* buffer)
{
    Diagnostic[] ret;


    return ret;
}

extern(C) SignatureHelpResponse dcd_get_signature(const(char)* filename, const(char)* content, int position)
{
    import std.algorithm;
    import std.array;
    import std.string: indexOf, lastIndexOf;
    import containers.ttree : TTree;
    import containers.hashset;
    import dcd.server.autocomplete.util;

    import dparse.lexer;
    import dparse.rollback_allocator;

    import dsymbol.builtin.names;
    import dsymbol.builtin.symbols;
    import dsymbol.conversion;
    import dsymbol.modulecache;
    import dsymbol.scope_;
    import dsymbol.string_interning;
    import dsymbol.symbol;
    // import dsymbol.ufcs;
    import dsymbol.utils;

    import dcd.common.constants;
    import dcd.common.messages;

    SignatureHelpResponse response;

    auto sourceCode = cast(ubyte[]) fromStringz(content);
    if (sourceCode == null || sourceCode.length == 0) return response;

    auto sc = StringCache(sourceCode.length.optimalBucketCount);
    const(Token)[] tokenArray;
    auto beforeTokens = getTokensBeforeCursor(sourceCode, position, sc, tokenArray);
    auto beforeTokensRelease = beforeTokens.release;

    size_t dummyParenIndex; 
    CalltipHint calltipHint = getCalltipHint(beforeTokensRelease, dummyParenIndex);
    if (calltipHint == CalltipHint.none) return response;

    // 1. Move the opening parenthesis search BEFORE getting the expression
    size_t openParenIdx = 0;
    int parenDepth = 0;
    bool foundOpen = false;
    for (size_t i = beforeTokensRelease.length; i > 0; i--)
    {
        auto t = beforeTokensRelease[i - 1];
        if (t.type == tok!")" || t.type == tok!"]")
        {
            parenDepth++;
        }
        else if (t.type == tok!"(" || t.type == tok!"[")
        {
            if (parenDepth == 0)
            {
                openParenIdx = i - 1;
                foundOpen = true;
                break;
            }
            parenDepth--;
        }
    }

    if (!foundOpen) return response;

    // 2. Define the exact end of the expression (drop the `!` if it's a template bang)
    size_t exprEnd = openParenIdx;
    immutable bool isTemplateInstantiation =
        exprEnd > 0 && beforeTokensRelease[exprEnd - 1].type == tok!"!";
    if (isTemplateInstantiation)
    {
        exprEnd--;
    }

    RollbackAllocator rba;
    ScopeSymbolPair pair = generateAutocompleteTrees(tokenArray, &rba, position, cache);
    scope(exit) pair.destroy();

    // 3. Slice the tokens accurately up to the function identifier
    auto expression = getExpression(beforeTokensRelease[0 .. exprEnd]);

    DSymbol*[] symbols = getSymbolsByTokenChain(pair.scope_, expression, position, CompletionType.calltips);

    if (symbols.length == 0) return response;


// DEBUG
//import std.stdio;
//writeln("=== DEBUG ===");
//writeln("expression tokens: ", expression);
//writeln("symbols.length: ", symbols.length);
//foreach (i, sym; symbols)
//{
//    writeln("  sym[", i, "] name=", sym.name, 
//            " kind=", sym.kind, 
//            " callTip=", sym.callTip is null ? "NULL" : sym.callTip[]);
//    // print children
//    foreach (child; sym.opSlice())
//    {
//        writeln("    child name=", child.name,
//                " kind=", child.kind,
//                " callTip=", child.callTip is null ? "NULL" : child.callTip[]);
//    }
//}
//writeln("=== END DEBUG ===");

    // 4. Use your original forward loop to count the active parameters
    int activeParameter = -1;
    if (calltipHint == CalltipHint.regularArguments || calltipHint == CalltipHint.indexOperator)
    {
        int depth = 1;
        int paramCount = 0;
        for (size_t i = openParenIdx + 1; i < beforeTokensRelease.length; i++)
        {
            auto t = beforeTokensRelease[i];
            if (t.type == tok!"(" || t.type == tok!"[")
            {
                depth++;
            }
            else if (t.type == tok!")" || t.type == tok!"]")
            {
                depth--;
            }
            else if (t.type == tok!"," && depth == 1)
            {
                paramCount++;
            }
        }
        activeParameter = paramCount;
    }

	foreach (sym; symbols)
	{
	    DSymbol* resolved = sym;

	    // Follow alias chain
	    if (resolved.kind == CompletionKind.aliasName && resolved.type !is null)
	        resolved = resolved.type;

	    // `Name(args)` calls the constructor; `Name!(args)` instantiates the
	    // template instead, so its own signature (the "Name(Params)" head
	    // `renderSignature` builds from its `templateList` shape) is what
	    // belongs here, not the constructor's - which is built from the
	    // struct's *fields*, not its template parameters, and would
	    // otherwise show up as this hint.
	    if (!isTemplateInstantiation &&
	        (resolved.kind == CompletionKind.structName || resolved.kind == CompletionKind.unionName || resolved.kind == CompletionKind.className))
	    {
	        DSymbol* ctorSym = null;
	        foreach (child; resolved.opSlice())
	        {
	            if (child.name == internString("*constructor*") && child.signature() !is null)
	            {
	                ctorSym = child;
	                break;
	            }
	        }
	        if (ctorSym is null) continue;
	        resolved = ctorSym;
	    }

	    auto signature = resolved.signature();
	    if (signature is null) continue;

	    SignatureInformation sigInfo;
	    auto rendered = renderSignature(signature);
	    sigInfo.label = rendered.label;
	    // A `Name!(...)` call wants the template parameter list, a plain
	    // `Name(...)` the value parameter list. They are separate fields now,
	    // so the choice is a field read rather than which parenthesis pair
	    // sorts first in a string.
	    if (isTemplateInstantiation)
	        sigInfo.parameters = parameterInformations(signature.templateParameters,
	            rendered.templateSpans);
	    else
	        sigInfo.parameters = parameterInformations(signature.parameters,
	            rendered.parameterSpans);
	    response.signatures ~= sigInfo;
	}

    if (response.signatures.length > 0)
    {
        response.activeSignature = 0;
        response.activeParameter = activeParameter >= 0 ? activeParameter : 0;
    }

    return response;
}

/**
 * Turns one of a signature's parameter lists into the protocol's
 * `ParameterInformation`s.
 *
 * `labels` are the entries as rendered, `spans` where `renderSignature` placed
 * them in the label: the `[start, end)` pair is what a client uses to
 * highlight the exact occurrence dls means, instead of searching the label for
 * text that may appear several times (a single-letter template parameter like
 * `T` in `T get(T)(T data)`).
 */
ParameterInformation[] parameterInformations(const(istring)[] labels, size_t[2][] spans)
{
    ParameterInformation[] params;
    foreach (i, label; labels)
    {
        ParameterInformation info;
        info.label = label.data;
        if (i < spans.length)
        {
            info.labelStart = cast(int) spans[i][0];
            info.labelEnd = cast(int) spans[i][1];
        }
        params ~= info;
    }
    return params;
}
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

    // 'label's exact [start, end) offset within the owning
    // SignatureInformation.label, when known (-1 otherwise). Sent as LSP's
    // [start, end] form instead of the bare string above whenever it's
    // available, so the client highlights the exact substring instead of
    // searching the whole label for 'label' as text and (silently)
    // matching the first, possibly unrelated, occurrence - a single-letter
    // template parameter name like `T` in `T get(T)(T data)` appears three
    // times, only one of which is the parameter itself.
    int labelStart = -1;
    int labelEnd = -1;

    // The human-readable doc-comment of this parameter.
    string documentation; // (Optional)
}



//unittest
//{
//    import std;
//	import dcd.server.autocomplete;

	
//    stderr.writeln("FUUUUUUUUUUUUUUUUCK");

//	string content ="struct Data
//{
//	int aaa;
//	float bbb;
//	Data* next;
//}
//void main()
//{
//	Data data = Data();

//}
//	";

//	auto pos = 83;

//	ModuleCache cache;
//    AutocompleteRequest request;
//    request.fileName = "stdin";
//    request.cursorPosition = pos;
//    request.kind |= RequestKind.autocomplete;
//    request.sourceCode = cast(ubyte[]) content.dup;


//    auto ret = complete(request, cache);


//    stderr.writeln(ret);

//    stderr.writeln("FUUUUUUUUUUUUUUUUCK");

//    //assert(false);
//    stderr.flush();
//}



unittest
{
    import std;
	import dcd.server.autocomplete;

	
    stderr.writeln("FUUUUUUUUUUUUUUUUCK");

	string content ="struct Data
{
	int a;
	float b;
	Data* c;
}

void myfun(int a, float b, Data* c){}

void main()
{
	Data data = Data();
	myfun();

}

alias Data_a = Data;
void main2()
{
	Data_a data = Data_a();
}

	";

	auto retTHIS = dcd_get_signature("", content.dup.ptr, 116);
	auto retFN = dcd_get_signature("", content.dup.ptr, 126);
	auto retTHISALIAS = dcd_get_signature("", content.dup.ptr, 191);

    stderr.writeln(retTHIS);
    stderr.writeln(retFN);
    stderr.writeln(retTHISALIAS);
    stderr.flush();
}

// SignatureHelpResponse([SignatureInformation("this(int a, float b, Data* c)", "", [ParameterInformation("int a", ""), ParameterInformation("float b", ""), ParameterInformation("Data* c", "")], 0)], 0, 0)
// SignatureHelpResponse([SignatureInformation("void myfun(int a, float b, Data* c)", "", [ParameterInformation("int a", ""), ParameterInformation("float b", ""), ParameterInformation("Data* c", "")], 0)], 0, 0)
