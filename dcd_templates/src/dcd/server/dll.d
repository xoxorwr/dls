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

import dsymbol.symbol;
import dsymbol.modulecache;


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

extern(C) export DSymbolInfo[] dcd_document_symbols_sem(const(char)* filename, const(char)* content)
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

    LexerConfig config;
    config.fileName = "";
    auto sc = StringCache(request.sourceCode.length.optimalBucketCount);
    auto tokenArray = getTokensForParser(cast(ubyte[]) request.sourceCode, config, &sc);
    RollbackAllocator rba;
    auto pair = generateAutocompleteTrees(tokenArray, &rba, -1, cache);
    scope(exit) pair.destroy();


    size_t e;

    void check(DSymbol* it)
    {
        //for (int i = 0; i < p; i++)
        //fprintf(stderr, " ");
        //fprintf(stderr, "loc: %ld k: %c sym: %.*s\n", it.location, cast(char) it.kind, it.name.length, it.name.ptr);

        if (it.type != null)
        {
            DSymbolInfo info;
            info.name = it.type.name;
            info.range[0] = it.type.location;
            //if (it.type.location_end == 0)
            //    info.range[1] = it.type.location + it.type.name.length;
            //else
            //    info.range[1] = it.type.location_end;
            info.kind = it.type.kind;
            ret ~= info;
        }

        {
            DSymbolInfo info;
            info.name = it.name;
            info.range[0] = it.location;
            //if (it.location_end == 0)
            //    info.range[1] = it.location + it.name.length;
            //else
            //    info.range[1] = it.location_end;

            info.kind = it.kind;
            ret ~= info;
        }



        foreach(sym; it.opSlice())
        {
            if (sym.symbolFile != "stdin") continue;
            if (sym.generated) continue;

            check(sym);
       }
    }

    foreach (symbol; pair.scope_.symbols)
    {
        if (symbol.symbolFile != "stdin") continue;
        if (symbol.generated) continue;
        check(symbol);
    }

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
            warning("found: ", sym.name, " k:", sym.kind,"  at: ",sym.symbolFile," -> ", sym.location,"\n    ct: ", sym.callTip,"\n");
            if (sym.type)
                warning("  type: ", sym.type.name, " k:", sym.type.kind,"  at: ",sym.type.symbolFile," -> ", sym.type.location,"\n    ct: ", sym.type.callTip,"\n");

            string value;


            auto ms = cache.getEntryFor(sym.symbolFile);
            if (ms && ms.symbol)
            {
                value ~= ms.symbol.callTip;
                value ~= "\n";
            }

            if (sym.callTip.length > 0)
            {
                value ~= sym.callTip;
            }
            else
            {
                if (sym.kind == CompletionKind.structName)
                    value ~=  sym.callTip[];
                else if (sym.kind == CompletionKind.unionName)
                    value ~=  sym.callTip[];
                else if (sym.kind == CompletionKind.enumName)
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
                        
                        if (typeName.length > 0){
                            value ~= typeName ~ " " ~ sym.name ~ ";";
                        }
                        else{
                            value ~= sym.type.formatType() ~ " " ~ sym.name ~ ";";


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
                            value ~= typeName;
                        else
                            value ~= sym.type.formatType();
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
    if (exprEnd > 0 && beforeTokensRelease[exprEnd - 1].type == tok!"!")
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

	    // If it's a struct/class, find the constructor
	    if (
	        (resolved.kind == CompletionKind.structName || resolved.kind == CompletionKind.unionName || resolved.kind == CompletionKind.className))
	    {
	        DSymbol* ctorSym = null;
	        foreach (child; resolved.opSlice())
	        {
	            if (child.name == internString("*constructor*") && child.callTip !is null)
	            {
	                ctorSym = child;
	                break;
	            }
	        }
	        if (ctorSym is null) continue;
	        resolved = ctorSym;
	    }

	    if (resolved.callTip is null) continue;

	    SignatureInformation sigInfo;
	    sigInfo.label = resolved.callTip[];
	    sigInfo.parameters = parseParameters(resolved.callTip[]);
	    response.signatures ~= sigInfo;
	}

    if (response.signatures.length > 0)
    {
        response.activeSignature = 0;
        response.activeParameter = activeParameter >= 0 ? activeParameter : 0;
    }

    return response;
}

ParameterInformation[] parseParameters(string callTip)
{
    import std.string: indexOf, lastIndexOf;
    ParameterInformation[] params;

    auto openParen = callTip.indexOf('(');
    if (openParen < 0) return params;

    auto closeParen = cast(size_t) callTip.lastIndexOf(')');
    if (closeParen < 0 || closeParen <= openParen) return params;

    auto paramStr = callTip[openParen + 1 .. closeParen];
    if (paramStr.length == 0) return params;

    int depth = 0;
    size_t start = 0;
    for (size_t i = 0; i < paramStr.length; i++)
    {
        auto c = paramStr[i];
        if (c == '(' || c == '[' || c == '{' || c == '<')
            depth++;
        else if (c == ')' || c == ']' || c == '}' || c == '>')
            depth--;
        else if (c == ',' && depth == 0)
        {
            auto param = paramStr[start .. i];
            start = i + 1;
            while (param.length > 0 && (param[0] == ' ' || param[0] == '\t'))
                param = param[1 .. $];
            while (param.length > 0 && (param[$-1] == ' ' || param[$-1] == '\t'))
                param = param[0 .. $-1];
            if (param.length > 0)
                params ~= ParameterInformation(param);
        }
    }

    auto param = paramStr[start .. $];
    while (param.length > 0 && (param[0] == ' ' || param[0] == '\t'))
        param = param[1 .. $];
    while (param.length > 0 && (param[$-1] == ' ' || param[$-1] == '\t'))
        param = param[0 .. $-1];
    if (param.length > 0)
        params ~= ParameterInformation(param);

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
