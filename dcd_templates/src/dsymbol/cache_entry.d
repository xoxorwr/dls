module dsymbol.cache_entry;

import dsymbol.symbol;
import std.datetime;
import containers.openhashset;
import containers.unrolledlist;

/**
 * Module cache entry
 */
struct CacheEntry
{
	@disable this(this);

	/// Module root symbol
	DSymbol* symbol;

	/// Modification time when this file was last cached
	SysTime modificationTime;

	/// The path to the module
	istring path;

	/// The modules that this module depends on
	OpenHashSet!istring dependencies;

	/// Hash of the source this entry was parsed from, so an unchanged save can
	/// skip re-parsing it (see ModuleCache.sourceUnchanged).
	ulong contentHash;

	~this()
	{
		if (symbol !is null)
			typeid(DSymbol).destroy(symbol);
	}

pure nothrow @nogc @safe:

	ptrdiff_t opCmp(ref const CacheEntry other) const
	{
		import std.algorithm.comparison : cmp;
		return cmp(this.path.data, other.path.data);
	}

	bool opEquals(ref const CacheEntry other) const
	{
		return this.path.data == other.path.data;
	}

	size_t toHash() const
	{
		return path.toHash();
	}

	@disable void opAssign(ref const CacheEntry other);
}
