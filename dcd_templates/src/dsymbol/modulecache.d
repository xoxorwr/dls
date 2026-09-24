/**
 * This file is part of DCD, a development tool for the D programming language.
 * Copyright (C) 2014 Brian Schott
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

module dsymbol.modulecache;

import containers.dynamicarray;
import containers.hashset;
import containers.hashmap;
import containers.ttree;
import containers.unrolledlist;
import dsymbol.conversion;
import dsymbol.conversion.first;
import dsymbol.conversion.second;
import dsymbol.cache_entry;
import dsymbol.scope_;
import dsymbol.semantic;
import dsymbol.symbol;
import dsymbol.string_interning;
import dsymbol.deferred;
import std.algorithm;
import std.experimental.allocator;
import std.experimental.allocator.building_blocks.allocator_list;
import std.experimental.allocator.building_blocks.region;
import std.experimental.allocator.building_blocks.null_allocator;
import std.experimental.allocator.mallocator : Mallocator;
import std.experimental.allocator.gc_allocator : GCAllocator;
import std.conv;
import dparse.ast;
import std.datetime;
import dparse.lexer;
import dparse.parser;
import std.experimental.logger;
import std.file;
import std.experimental.lexer;
import std.path;

	/**
	 * Returns: true if a file exists at the given path.
	 */
	bool existanceCheck(A)(A path)
{
	if (path.exists())
		return true;
	warning("Cannot cache modules in ", path, " because it does not exist");
	return false;
}

alias DeferredSymbolsAllocator = GCAllocator; // NOTE using `Mallocator` here fails when analysing Phobos as `free(): invalid pointer`

/**
 * Caches pre-parsed module information.
 */
/**
 * XXH64 over the source a module was parsed from.  Used to detect a save that
 * carries the text DCD already has cached (see sourceUnchanged) and, through
 * 'dcd_content_unchanged', a save that reaches the server twice.
 *
 * This was FNV-1a: byte-at-a-time, and clustered on the input that matters
 * here - a file and its next revision.  See 'dsymbol.hash'.
 */
ulong hashSource(const(ubyte)[] data)
{
	import dsymbol.hash : xxh64;
	return xxh64(data);
}

struct ModuleCache
{
	/// No copying.
	@disable this(this);

	~this()
	{
		clear();
	}

	/**
	 * Adds the given paths to the list of directories checked for imports.
	 * Performs duplicate checking, so multiple instances of the same path will
	 * not be present.
	 */
	void addImportPaths(const string[] paths)
	{
		import std.path : baseName;
		import std.array : array;

		auto newPaths = paths
			.map!(a => absolutePath(expandTilde(a)))
			.filter!(a => existanceCheck(a) && !importPaths[].canFind!(b => b.path == a))
			.map!(a => ImportPath(istring(a)))
			.array;
		importPaths.insert(newPaths);
	}

	/**
	 * Removes the given paths from the list of directories checked for
	 * imports. Corresponding cache entries are removed.
	 */
	void removeImportPaths(const string[] paths)
	{
		import std.array : array;

		foreach (path; paths[])
		{
			if (!importPaths[].canFind!(a => a.path == path))
			{
				warning("Cannot remove ", path, " because it is not imported");
				continue;
			}

			foreach (ref importPath; importPaths[].filter!(a => a.path == path).array)
				importPaths.remove(importPath);

			foreach (cacheEntry; cache[])
			{
				if (cacheEntry.path.data.startsWith(path))
				{
					foreach (deferredSymbol; deferredSymbols[].find!(d => d.symbol.symbolFile.data.startsWith(cacheEntry.path.data)))
					{
						deferredSymbols.remove(deferredSymbol);
						DeferredSymbolsAllocator.instance.dispose(deferredSymbol);
					}

					cache.remove(cacheEntry);
					CacheAllocator.instance.dispose(cacheEntry);
				}
			}
		}
	}

	/**
	 * Clears the cache from all import paths
	 */
	void clear()
	{
		foreach (entry; cache[])
			CacheAllocator.instance.dispose(entry);
		foreach (symbol; deferredSymbols[])
			DeferredSymbolsAllocator.instance.dispose(symbol);

		cache.clear();
		deferredSymbols.clear();
		importPaths.clear();
	}

	/**
	 * Caches the module at the given location
	 */
	DSymbol* cacheModule(string location, ubyte[] content = null, bool force = false)
	{
	    import std.stdio : File;
	    import std.path : extension;
	    import std.process : execute;
	    import core.memory: GC;

	    assert (location !is null);

	    const cachedLocation = istring(location);

	    if (recursionGuard.contains(&cachedLocation.data[0]))
	        return null;

	    if (!needsReparsing(cachedLocation) && content.ptr == null && !force)
	        return getEntryFor(cachedLocation).symbol;

	    scope(exit) GC.collect();

	    warning("caching: ", location, " content: ", content.ptr);

	    recursionGuard.insert(&cachedLocation.data[0]);
	    // Release the guard on every return path, not just the successful one.
	    // The early returns below -- a zero-length source ("> empty") and a
	    // failed C-header generation -- used to leave the path in the guard
	    // forever, so every later call for it returned immediately and the
	    // module stayed uncached for the rest of the session: a file that was
	    // empty or missing when a dependent first imported it could never be
	    // picked up again.
	    scope(exit) recursionGuard.remove(&cachedLocation.data[0]);

	    ubyte[] source;
	    size_t sourceLength;
	    bool isCFile = cachedLocation.extension == ".c";

	    if (isCFile)
	    {
            version(Windows)
	            auto result = execute(["dmd.exe", "-o-", "-Hf=-", location]);
            else
	            auto result = execute(["dmd", "-o-", "-Hf=-", location]);
	        if (result.status != 0 || result.output.length == 0){
	            warning("failed to generate di for ", location);
	            return null;
	        }
	        sourceLength = result.output.length;
	        source = cast(ubyte[]) Mallocator.instance.allocate(sourceLength);
	        source[] = cast(ubyte[]) result.output[];
	    }
	    else if (content.ptr)
	    {
	        source = content;
	        sourceLength = content.length;
	        if (sourceLength == 0){
	            warning("> empty");
	            return null;
	        }
	    }
	    else
	    {
	        File f = File(cachedLocation);
	        sourceLength = cast(size_t) f.size;
	        if (sourceLength == 0){
	            warning("> empty");
	            return null;
	        }
	        source = cast(ubyte[]) Mallocator.instance.allocate(sourceLength);
	        f.rawRead(source);
	    }

	    scope (exit) if(content.ptr == null) Mallocator.instance.deallocate(source);

	    const(Token)[] tokens;
	    auto parseStringCache = StringCache(sourceLength.optimalBucketCount);
	    {
	        LexerConfig config;
	        config.fileName = cachedLocation;
	        auto contentToParse = (source.length >= 3 && source[0 .. 3] == "\xef\xbb\xbf"c)
	            ? source[3 .. $]
	            : source;
	        tokens = getTokensForParser(contentToParse, config, &parseStringCache);
	    }

	    CacheEntry* newEntry = CacheAllocator.instance.make!CacheEntry();

	    import dparse.rollback_allocator:RollbackAllocator;
	    RollbackAllocator parseAllocator;
	    Module m = parseModuleSimple(tokens[], cachedLocation, &parseAllocator, isCFile);

	    scope first = new FirstPass(m, cachedLocation, &this, newEntry);
	    first.run();

	    secondPass(first.rootSymbol, first.rootSymbol, first.moduleScope, this);

	    typeid(Scope).destroy(first.moduleScope);
	    symbolsAllocated += first.symbolsAllocated;

	    SysTime access;
	    SysTime modification;
	    if (exists(cachedLocation.data))
	    {
	        try { 
	        	getTimes(cachedLocation.data, access, modification); 
	        } catch (Exception e) {

	        }
	    }

	    newEntry.symbol = first.rootSymbol.acSymbol;
	    newEntry.modificationTime = modification;
	    newEntry.path = cachedLocation;
	    newEntry.contentHash = hashSource(source[0 .. sourceLength]);

		CacheEntry* oldEntry = getEntryFor(cachedLocation);

		// Declare outside the if block so it stays alive through resolveDeferredTypes
		UpdatePairCollection updatePairs;

		// The cache is keyed by path only and TTree.insert never overwrites a
		// duplicate (the overwrite flag is ignored for duplicates that live
		// inside a full internal node), so the old entry has to leave the tree
		// before the new one goes in.  Doing it the other way around makes the
		// insert a no-op, and any later removal matches by path and drops the
		// new entry instead - evicting the module from the cache.
		//
		// The new entry must be in the cache before resolveDeferredTypes and
		// update_dependen run: those resolve imports of the dependents against
		// this module, and they are what keeps the dependents' references off
		// the old symbol tree that gets disposed at the end of this block.
		if (oldEntry !is null)
		    cache.remove(oldEntry);

		cache.insert(newEntry);

		resolveDeferredTypes(cachedLocation);

		if (oldEntry !is null)
		{
		    generateUpdatePairs(oldEntry.symbol, newEntry.symbol, updatePairs);

		    HashSet!istring _rg;
			void update_dependen(istring l, ref HashSet!istring rg)
			{
			  foreach (c; cache[])
			  {
			      if (!c.dependencies.contains(l)) continue;
			      if (rg.contains(c.path)) continue;
			      rg.insert(c.path);
			      warning("  update dep: ", c.path);
			      c.symbol.updateTypes(updatePairs);

			      HashSet!size_t visited;
			      tryResolveUnresolvedTypes(c.symbol, c.symbol, this, visited);

			      update_dependen(c.path, rg);
			  }
			}
		    update_dependen(cachedLocation, _rg);

		    // Safe to free only now
		    CacheAllocator.instance.dispose(oldEntry);
		}
		else
		{
		    warning("mod: ", location, " didn't have old entry");
		}

		// Force re-cache modules that had deferred symbols resolved —
		// their initializer-based type resolutions (resolveTypeFromInitializer)
		// ran during original secondPass when dependencies weren't available yet
		// and have no deferred path, so they need a full re-parse now.
		//foreach (path; deferredResolved)
		//{
		//    if (path == cachedLocation) continue;
		//    // Still inside our recursionGuard so no infinite loop
		//    warning("  force re-cache after deferred resolution: ", path.data);
		//    cacheModule(path.data, null, true);
		//}

		// recursionGuard is released by the scope(exit) set above, so this
		// path stays inside the guard while it re-points dependents, exactly
		// as before.
		typeid(SemanticSymbol).destroy(first.rootSymbol);
		return newEntry.symbol;
	}
	/**
	 * Returns: true when 'content' is byte-identical to the source this module
	 * was last parsed from, so there is nothing to re-parse.
	 */
	bool sourceUnchanged(istring path, const(ubyte)[] content)
	{
		auto entry = getEntryFor(path);
		if (entry is null || entry.contentHash == 0)
			return false;
		return entry.contentHash == hashSource(content);
	}

	/**
	 * Notifies the dependents of 'cachedLocation' without re-parsing it.
	 *
	 * This is what a save of identical text still has to do: a dependent that
	 * holds a stale instance of one of this module's symbols is re-pointed at
	 * the live tree (updateTypes matches by pointer or by name+kind), and
	 * unresolved types are retried -- the same work a real re-cache performs,
	 * minus the lex/parse/second-pass/rebuild.
	 *
	 * The cached modification time is re-anchored too, so the next lookup
	 * doesn't decide the file needs re-reading from disk.
	 */
	void refreshDependents(istring cachedLocation)
	{
		import std.file : exists, getTimes;
		import std.datetime : SysTime;

		auto entry = getEntryFor(cachedLocation);
		if (entry is null)
			return;

		if (exists(cachedLocation.data))
		{
			try
			{
				SysTime access;
				SysTime modification;
				getTimes(cachedLocation.data, access, modification);
				entry.modificationTime = modification;
			}
			catch (Exception)
			{
			}
		}

		// Collect the dependents first: with none cached there is nothing to
		// notify, and the identity pair set is not worth building.
		HashSet!istring rg;
		void collect(istring l)
		{
			foreach (c; cache[])
			{
				if (!c.dependencies.contains(l)) continue;
				if (rg.contains(c.path)) continue;
				rg.insert(c.path);
				collect(c.path);
			}
		}
		collect(cachedLocation);

		if (rg.empty)
			return;

		UpdatePairCollection updatePairs;
		generateIdentityPairs(entry.symbol, updatePairs);

		void notify(istring l)
		{
			foreach (c; cache[])
			{
				if (!c.dependencies.contains(l)) continue;
				if (!rg.contains(c.path)) continue;
				warning("  update dep (refresh): ", c.path);
				c.symbol.updateTypes(updatePairs);

				HashSet!size_t visited;
				tryResolveUnresolvedTypes(c.symbol, c.symbol, this, visited);
			}
		}
		notify(cachedLocation);
	}

	void tryResolveUnresolvedTypes(DSymbol* moduleSymbol, DSymbol* current, ref ModuleCache cache, ref HashSet!size_t visited)
	{
		import dsymbol.builtin.names;
		import dsymbol.builtin.symbols;

	    if (current is null || visited.contains(cast(size_t) current)) return;
	    visited.insert(cast(size_t) current);

	  // If this symbol has a null type but a typeSymbolName, try to resolve it
	  if (current.type is null && current.typeSymbolName.length > 0)
	  {
		  // Check built-ins first
		  foreach (s; builtinSymbols[])
		  {
			  if (s.name == current.typeSymbolName)
			  {
				  current.type = cast(DSymbol*) s;
				  current.ownType = false;
				  goto next;
			  }
		  }

	      // Try to find the type in the module's scope (includes public imports)
	      auto typeSym = moduleSymbol.getFirstPartNamed(current.typeSymbolName);
	      if (typeSym is null)
	      {
	          // Try in imported modules (even if not public)
	          DSymbol importSym = DSymbol(IMPORT_SYMBOL_NAME);
	          foreach (im; moduleSymbol.parts.equalRange(SymbolOwnership(&importSym)))
	          {
	              if (im.type !is null)
	              {
	                  typeSym = im.type.getFirstPartNamed(current.typeSymbolName);
	                  if (typeSym !is null) break;
	              }
	          }
	      }

	      if (typeSym !is null)
	      {
	          current.type = typeSym;
	          current.ownType = false;
	      }
	  }

	next:
      if (current.type !is null)
          tryResolveUnresolvedTypes(moduleSymbol, current.type, cache, visited);

	  // Recurse into parts
	  foreach (part; current.parts[])
	  {
	      tryResolveUnresolvedTypes(moduleSymbol, part, cache, visited);
	  }
	}

	void deps_for(istring cachedLocation, ref HashSet!istring rg)
	{
		void update_dependen(istring l)
		{
		    foreach(c; cache[])
		    {
		        if (c.dependencies.contains(l))
		        {
		            if (c.path == cachedLocation || rg.contains(c.path)) continue;
		            rg.insert(c.path);
		            update_dependen(c.path);
		        }
		    }
		}
		foreach(c; cache[])
		{
		    if (c.dependencies.contains(cachedLocation))
		    {
		        if (c.path == cachedLocation) continue;
		        if (rg.contains(c.path)) continue;
		        rg.insert(c.path);

		        update_dependen(c.path); 
		    }
		}
	}
	/**
	 * Resolves types for deferred symbols
	 */
	void resolveDeferredTypes(istring location)
	{
		import dsymbol.type_lookup;
	    DeferredSymbols temp;
	    temp.insert(deferredSymbols[]);
	    deferredSymbols.clear();
	    foreach (deferred; temp[])
	    {
	        if (!deferred.imports.empty && !deferred.dependsOn(location))
	        {
	            deferredSymbols.insert(deferred);
	            continue;
	        }
	        assert(deferred.symbol.type is null);
	        if (deferred.symbol.kind == CompletionKind.importSymbol)
	        {
	            resolveImport(null, deferred.symbol, deferred.typeLookups, this);
	        }
	        else if (!deferred.typeLookups.empty)
	        {
	            auto lookup = deferred.typeLookups.front;
	            if (lookup.kind == TypeLookupKind.initializer
	                || lookup.kind == TypeLookupKind.foreachElement)
	            {
	                // Was previously never retried — now gets a second chance
	                // once the module that owns the initializer's type is cached
	                resolveTypeFromInitializer(deferred.symbol, lookup, null, this);
	                // if it still fails it re-defers itself via the new path above
	            }
	            else
	            {
	                resolveTypeFromType(deferred.symbol, lookup, null,
	                    this, &deferred.imports);
	            }
	        }
	        DeferredSymbolsAllocator.instance.dispose(deferred);
	    }
	}

	/**
	 * Params:
	 *     moduleName = the name of the module in "a/b/c" form
	 * Returns:
	 *     The symbols defined in the given module, or null if the module is
	 *     not cached yet.
	 */
	DSymbol* getModuleSymbol(istring location)
	{
		auto existing = getEntryFor(location);
		return existing ? existing.symbol : cacheModule(location);
	}

	/**
	 * Params:
	 *     moduleName = the name of the module being imported, in "a/b/c" style
	 * Returns:
	 *     The absolute path to the file that contains the module, or null if
	 *     not found.
	 */
	istring resolveImportLocation(bool reverse = false)(string moduleName)
	{
		assert(moduleName !is null, "module name is null");
		if (isRooted(moduleName))
			return istring(moduleName);
		string alternative;

		auto _getImports()
		{
			static if (reverse)
			{
				import  std.algorithm.mutation: reverse;
				ImportPath[] ret;
				foreach (importPath; importPaths[])
				{
					ret ~= importPath;
				}
				ret = ret.reverse;
				return ret;
			}
			else
				return importPaths[];
		}

		auto ipaths = _getImports();

		foreach (importPath; ipaths)
		{
			auto path = importPath.path;
			// import path is a filename
			// first check string if this is a feasable path (no filesystem usage)
			if (path.stripExtension.endsWith(moduleName)
				&& path.existsAnd!isFile)
			{
				// prefer exact import names above .di/package.d files
				return istring(path);
			}
			// no exact matches and no .di/package.d matches either
			else if (!alternative.length)
			{
				string filePath = buildPath(path, moduleName);
				string dotDi = filePath ~ ".di";
				string dotC = filePath ~ ".c";
				string dotD = dotDi[0 .. $ - 1];
				string withoutSuffix = dotDi[0 .. $ - 3];
				if (existsAnd!isFile(dotD))
				{
					return istring(dotD); // return early for exactly matching .d files
				}
				else if (existsAnd!isFile(dotC))
					return istring(dotC);
				else if (existsAnd!isFile(dotDi))
					alternative = dotDi;
				else if (existsAnd!isDir(withoutSuffix))
				{
					string packagePath = buildPath(withoutSuffix, "package.di");
					if (existsAnd!isFile(packagePath[0 .. $ - 1]))
						alternative = packagePath[0 .. $ - 1];
					else if (existsAnd!isFile(packagePath))
						alternative = packagePath;
				}
			}
			// we have a potential .di/package.d file but continue searching for
			// exact .d file matches to use instead
			else
			{
				string dotD = buildPath(path, moduleName) ~ ".d";
				if (existsAnd!isFile(dotD))
				{
					return istring(dotD); // return early for exactly matching .d files
				}
			}
		}
		return alternative.length > 0 ? istring(alternative) : istring(null);
	}

	auto getImportPaths() const
	{
		return importPaths[].map!(a => a.path);
	}

	auto getAllSymbols()
	{
		scanAll();
		return cache[];
	}

	/**
	 * Like 'getAllSymbols', but only force-parses import paths listed in
	 * 'paths' (an exact match against a path as it was registered with
	 * 'addImportPaths') instead of every registered import path.
	 *
	 * This exists for workspace-wide symbol search: scanning *every* import
	 * path unconditionally would also eagerly parse the compiler's own
	 * stdlib paths (phobos/druntime), which are typically registered
	 * alongside the project's own paths and dwarf them in file count. The
	 * cache has no eviction, so that cost is permanent for the process's
	 * lifetime - callers pass just the caller's own project paths to keep
	 * that cost bounded to the project, and let stdlib symbols keep being
	 * cached lazily (via normal import resolution) as they already are.
	 *
	 * The returned range still includes whatever else is already cached
	 * (e.g. stdlib modules pulled in earlier by ordinary import
	 * resolution) - only the *scanning* is scoped, not the result.
	 */
	auto getWorkspaceSymbols(const string[] paths)
	{
		scanMatching((const ref ImportPath ip) => paths.canFind(ip.path));
		return cache[];
	}

	alias DeferredSymbols = UnrolledList!(DeferredSymbol*, DeferredSymbolsAllocator);
	DeferredSymbols deferredSymbols;

	/// Count of autocomplete symbols that have been allocated
	uint symbolsAllocated;

	CacheEntry* getEntryFor(istring cachedLocation)
	{
		CacheEntry dummy;
		dummy.path = cachedLocation;
		auto r = cache.equalRange(&dummy);
		return r.empty ? null : r.front;
	}



private:



	/**
	 * Params:
	 *     mod = the path to the module
	 * Returns:
	 *     true  if the module needs to be reparsed, false otherwise
	 */
	bool needsReparsing(istring mod)
	{
		if (!exists(mod.data))
			return true;
		CacheEntry e;
		e.path = mod;
		auto r = cache.equalRange(&e);
		if (r.empty)
			return true;

		auto m = r.front.symbol;
		SysTime access;
		SysTime modification;
		getTimes(mod.data, access, modification);
		return r.front.modificationTime != modification;
	}

	void scanAll()
	{
		scanMatching((const ref ImportPath ip) => true);
	}

	/// 'scanAll', but an import path is force-parsed only when 'pred'
	/// accepts it; one 'pred' rejects is left unscanned (not marked
	/// 'scanned'), so a later, less restrictive scan can still pick it up.
	void scanMatching(bool delegate(const ref ImportPath) pred)
	{
		foreach (ref importPath; importPaths)
		{
			if (importPath.scanned)
				continue;
			if (!pred(importPath))
				continue;
			scope(success) importPath.scanned = true;

			if (importPath.path.existsAnd!isFile)
			{
				if (importPath.path.baseName.startsWith(".#"))
					continue;
				cacheModule(importPath.path);
			}
			else
			{
				void scanFrom(const string root)
				{
					if (exists(buildPath(root, ".no-dcd")))
						return;

					try foreach (f; dirEntries(root, SpanMode.shallow))
					{
						if (f.name.existsAnd!isFile)
						{
							if (!f.name.extension.among(".d", ".di") || f.name.baseName.startsWith(".#"))
								continue;
							cacheModule(f.name);
						}
						else scanFrom(f.name);
					}
					catch(FileException) {}
				}
				scanFrom(importPath.path);
			}
		}
	}

	// Mapping of file paths to their cached symbols.
	alias CacheAllocator = GCAllocator; // NOTE using `Mallocator` here fails when analysing Phobos as `Segmentation fault (core dumped)`
	alias Cache = TTree!(CacheEntry*, CacheAllocator);
	public Cache cache;
    public HashMap!(string, string, GCAllocator) source_cache;

	HashSet!(immutable(char)*) recursionGuard;

	struct ImportPath
	{
		string path;
		bool scanned;
	}

	// Listing of paths to check for imports
	UnrolledList!ImportPath importPaths;
}

/// Wrapper to check some attribute of a path, ignoring errors
/// (such as on a broken symlink).
private static bool existsAnd(alias fun)(string file)
{
	try
		return fun(file);
	catch (FileException e)
		return false;
}

/// same as getAttributes without throwing
/// Returns: true if exists, false otherwise
private static bool getFileAttributesFast(R)(R name, uint* attributes)
{
	version (Windows)
	{
		import std.internal.cstring : tempCStringW;
		import core.sys.windows.winnt : INVALID_FILE_ATTRIBUTES;
		import core.sys.windows.winbase : GetFileAttributesW;

		auto namez = tempCStringW(name);
		static auto trustedGetFileAttributesW(const(wchar)* namez) @trusted
		{
			return GetFileAttributesW(namez);
		}
		*attributes = trustedGetFileAttributesW(namez);
		return *attributes != INVALID_FILE_ATTRIBUTES;
	}
	else version (Posix)
	{
		import core.sys.posix.sys.stat : stat, stat_t;
		import std.internal.cstring : tempCString;

		auto namez = tempCString(name);
		static auto trustedStat(const(char)* namez, out stat_t statbuf) @trusted
		{
			return stat(namez, &statbuf);
		}

		stat_t statbuf;
		const ret = trustedStat(namez, statbuf) == 0;
		*attributes = statbuf.st_mode;
		return ret;
	}
	else
	{
		static assert(false, "Unimplemented getAttributes check");
	}
}

private static bool existsAnd(alias fun : isFile)(string file)
{
	uint attributes;
	if (!getFileAttributesFast(file, &attributes))
		return false;
	return attrIsFile(attributes);
}

private static bool existsAnd(alias fun : isDir)(string file)
{
	uint attributes;
	if (!getFileAttributesFast(file, &attributes))
		return false;
	return attrIsDir(attributes);
}

version (Windows)
{
	unittest
	{
		assert(existsAnd!isFile(`C:\Windows\regedit.exe`));
		assert(existsAnd!isDir(`C:\Windows`));
		assert(!existsAnd!isDir(`C:\Windows\regedit.exe`));
		assert(!existsAnd!isDir(`C:\SomewhereNonExistant\nonexistant.exe`));
		assert(!existsAnd!isFile(`C:\SomewhereNonExistant\nonexistant.exe`));
		assert(!existsAnd!isFile(`C:\Windows`));
	}
}
else version (Posix)
{
	unittest
	{
		assert(existsAnd!isFile(`/bin/sh`));
		assert(existsAnd!isDir(`/bin`));
		assert(!existsAnd!isDir(`/bin/sh`));
		assert(!existsAnd!isDir(`/nonexistant_dir/__nonexistant`));
		assert(!existsAnd!isFile(`/nonexistant_dir/__nonexistant`));
		assert(!existsAnd!isFile(`/bin`));
	}
}
