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

module dsymbol.symbol;

import std.array;

import std.experimental.logger;
import std.experimental.allocator.mallocator : Mallocator;
import std.experimental.allocator.gc_allocator : GCAllocator;
import containers.ttree;
import containers.unrolledlist;
import containers.slist;
import containers.hashset;
import dparse.lexer;
import std.bitmanip;

import dsymbol.builtin.names;
public import dsymbol.string_interning;
import dsymbol.signature;

import std.range : isOutputRange;

/**
 * Identifies the kind of the item in an identifier completion list
 */
enum CompletionKind : char
{
	/// Invalid completion kind. This is used internally and will never
	/// be returned in a completion response.
	dummy = '?',

	/// Import symbol. This is used internally and will never
	/// be returned in a completion response.
	importSymbol = '*',

	/// With symbol. This is used internally and will never
	/// be returned in a completion response.
	withSymbol = 'w',

	/// class names
	className = 'c',

	/// interface names
	interfaceName = 'i',

	/// structure names
	structName = 's',

	/// union name
	unionName = 'u',

	/// variable name
	variableName = 'v',

	/// member variable
	memberVariableName = 'm',

	/// keyword, built-in version, scope statement
	keyword = 'k',

	/// function or method
	functionName = 'f',

	/// UFCS function
	ufcsName = 'F',

	/// enum name
	enumName = 'g',

	/// enum member
	enumMember = 'e',

	/// package name
	packageName = 'P',

	/// module name
	moduleName = 'M',

	/// alias name
	aliasName = 'l',

	/// template name
	templateName = 't',

	/// mixin template name
	mixinTemplateName = 'T',

	/// variadic template parameter
	variadicTmpParam = 'p',

	/// type template parameter when no constraint
	typeTmpParam = 'h',
}

/**
 * Returns: true if `kind` is something that can be returned to the client
 */
bool isPublicCompletionKind(CompletionKind kind) pure nothrow @safe @nogc
{
	return kind != CompletionKind.dummy && kind != CompletionKind.importSymbol
		&& kind != CompletionKind.withSymbol;
}


/**
 * Any special information about a variable declaration symbol.
 */
enum SymbolQualifier : ubyte
{
	/// None
	none,
	/// The symbol is an array
	array,
	/// The symbol is a associative array
	assocArray,
	/// The symbol is a function or delegate pointer
	func,
	/// Selective import
	selectiveImport,
	/// The symbol is a pointer
	pointer,
	/// The symbol is templated
	templated,
}

/**
 * Autocompletion symbol
 */
struct DSymbol
{
	// Copying is disabled
	@disable this();
	@disable this(this);

	/**
	 * Params:
	 *     name = the symbol's name
	 *     kind = the symbol's completion kind
	 *     type = the resolved type of the symbol
	 */
	this(string name, CompletionKind kind = CompletionKind.dummy, DSymbol* type = null) nothrow @nogc @safe
	{
		this.name = istring(name);
		this.kind = kind;
		this.type = type;
        this.flags = Flags.init;
	}
	/// ditto
	this(istring name, CompletionKind kind = CompletionKind.dummy, DSymbol* type = null) nothrow @nogc @safe
	{
		this.name = name;
		this.kind = kind;
		this.type = type;
        this.flags = Flags.init;
	}

	~this()
	{
		foreach (ref part; parts[])
		{
			if (part.owned)
			{
				assert(part.ptr !is null);

				typeid(DSymbol).destroy(part.ptr);
			}
			else
				part.ptr = null;
		}
		if (ownType)
			typeid(DSymbol).destroy(type);
        this.flags = Flags.init;
        this.flags.deleted = 1;
        this.type = null;
	}

	ptrdiff_t opCmp(ref const DSymbol other) const pure nothrow @nogc @safe
	{
		return name.opCmpFast(other.name);
	}

	bool opEquals(ref const DSymbol other) const pure nothrow @nogc @safe
	{
		return name == other.name && kind == other.kind;
	}

	size_t toHash() const pure nothrow @nogc @safe
	{
		return name.toHash();
	}

	/**
	 * Gets all parts whose name matches the given string.
	 */
	inout(DSymbol)*[] getPartsByName(istring name) inout
	{
		auto app = appender!(DSymbol*[])();
		HashSet!size_t visited;
		getParts(name, app, visited);
		return cast(typeof(return)) app.data;
	}

	inout(DSymbol)* getFirstPartNamed(this This)(istring name) inout
	{
		auto app = appender!(DSymbol*[])();
		HashSet!size_t visited;
		getParts(name, app, visited);

		//warning("getFirstPartNamed", name, app.data.length);
		return app.data.length > 0 ? cast(typeof(return)) app.data[0] : null;
	}

	/**
	 * Gets all parts and imported parts. Filters based on the part's name if
	 * the `name` argument is not null. Stores results in `app`.
	 */
	void getParts(OR)(istring name, ref OR app, ref HashSet!size_t visited,
			bool onlyOne = false) inout
		if (isOutputRange!(OR, DSymbol*))
	{
		import std.algorithm.iteration : filter;

		if (&this is null)
			return;
		if (visited.contains(cast(size_t) &this))
			return;
		visited.insert(cast(size_t) &this);

		// pointers are implicitly dereferenced on members
		if (qualifier == SymbolQualifier.pointer && this.type) {
			return type.getParts!OR(name, app, visited, onlyOne);
        }

		// follow aliases
		if (kind == CompletionKind.aliasName && this.type) {
			return type.getParts!OR(name, app, visited, onlyOne);
		}

		if (name is null)
		{
			foreach (part; parts[].filter!(a => a.name != IMPORT_SYMBOL_NAME && a.name != "*imported_from*"))
			{
				app.put(cast(DSymbol*) part);
				if (onlyOne)
					return;
			}
			DSymbol p = DSymbol(IMPORT_SYMBOL_NAME);
			foreach (im; parts.equalRange(SymbolOwnership(&p)))
			{
				if (im.type !is null && !im.skipOver)
				{
					if (im.qualifier == SymbolQualifier.selectiveImport)
					{
						app.put(cast(DSymbol*) im.type);
						if (onlyOne)
							return;
					}
					else
						im.type.getParts(name, app, visited, onlyOne);
				}
			}
		}
		else
		{
			DSymbol s = DSymbol(name);
			foreach (part; parts.equalRange(SymbolOwnership(&s)))
			{
				app.put(cast(DSymbol*) part);
				if (onlyOne)
					return;
			}
			if (name == CONSTRUCTOR_SYMBOL_NAME ||
				name == DESTRUCTOR_SYMBOL_NAME ||
				name == UNITTEST_SYMBOL_NAME ||
				name == THIS_SYMBOL_NAME)
				return;	// these symbols should not be imported

			DSymbol p = DSymbol(IMPORT_SYMBOL_NAME);
			foreach (im; parts.equalRange(SymbolOwnership(&p)))
			{
				if (im.type !is null && !im.skipOver)
				{
					if (im.qualifier == SymbolQualifier.selectiveImport)
					{
						if (im.type.name == name)
						{
							app.put(cast(DSymbol*) im.type);
							if (onlyOne)
								return;
						}
					}
					else
						im.type.getParts(name, app, visited, onlyOne);
				}
			}
		}
	}

	/**
	 * Returns: a range over this symbol's parts and publicly visible imports
	 */
	inout(DSymbol)*[] opSlice(this This)() inout
	{
		auto app = appender!(DSymbol*[])();
		HashSet!size_t visited;
		getParts!(typeof(app))(istring(null), app, visited);
		return cast(typeof(return)) app.data;
	}

	void addChild(DSymbol* symbol, bool owns)
	{
		assert(symbol !is null);
		parts.insert(SymbolOwnership(symbol, owns));
	}

	void addChildren(R)(R symbols, bool owns)
	{
		foreach (symbol; symbols)
		{
			assert(symbol !is null);
			parts.insert(SymbolOwnership(symbol, owns));
		}
	}

	void addChildren(DSymbol*[] symbols, bool owns)
	{
		foreach (symbol; symbols)
		{
			assert(symbol !is null);
			parts.insert(SymbolOwnership(symbol, owns));
		}
	}

	/**
	 * Updates the type field based on the mappings contained in the given
	 * collection.
	 */
  bool updateTypes(ref UpdatePairCollection collection)
  {
      bool updated = false;

      DSymbol** typeField = &type;
      while (*typeField !is null)
      {
          DSymbol* t = *typeField;

          bool replaced = false;
          foreach (it; collection[]) {
              if (t == it.oldSymbol || (t.name == it.oldSymbol.name && t.kind == it.oldSymbol.kind)) {
                  *typeField = it.newSymbol;
                  updated = true;
                  replaced = true;
                  break;
              }
          }
          if (replaced) break;

          if (t.type !is null &&
           		(t.name == ARRAY_SYMBOL_NAME || t.name == POINTER_SYMBOL_NAME ||
           		 t.qualifier == SymbolQualifier.array || t.qualifier == SymbolQualifier.pointer
           		)
           	)
              typeField = &((*typeField).type);
          else
              break;
      }

      foreach (part; parts[])
      {
	      if (part.updateTypes(collection))
	          updated = true;

      }

      return updated;
  }



	/**
	 * Symbols that compose this symbol, such as enum members, class variables,
	 * methods, parameters, etc.
	 */
	alias PartsAllocator = GCAllocator; // NOTE using `Mallocator` here fails when analysing Phobos
	alias Parts = TTree!(SymbolOwnership, PartsAllocator, true, "a < b");
	Parts parts;

	/**
	 * DSymbol's name
	 */
	istring name;

	/**
	 * Calltip to display if this is a function
	 */
	istring callTip;

	/**
	 * Kind-specific payload; the meaning is fixed by `kind` (and, for the
	 * `qualifier == func` type symbols, by that qualifier).  Null when the
	 * symbol has none.
	 *
	 * One payload kind exists today: a `Signature` for the symbols that carry
	 * one -- `functionName` (functions, constructors, destructors, function
	 * literals), the `qualifier == func` type symbols of `T function(Args)`
	 * types, and aggregates whose declaration has template parameters.  It is
	 * built while the module's AST is still alive and is immutable afterwards,
	 * so several symbols may share one (`instantiateSymbol` copies rather than
	 * mutates).  The payload is GC-allocated and so is not freed here.
	 *
	 * This is what `callTip` should have been for those symbols: the string
	 * flattened a signature that three different features wanted the parts of
	 * back.  Read it through `signature()`, never by casting `extra` at the
	 * call site.
	 */
	private void* extra;

	/**
	 * Returns: this symbol's structured signature, or null when it has none.
	 */
	Signature* signature() const nothrow @nogc
	{
		return cast(Signature*) extra;
	}

	/// ditto
	void setSignature(Signature* signature) nothrow @nogc @safe
	{
		extra = signature;
	}

	/**
	 * Used for storing information for selective renamed imports
	 */
	alias altFile = callTip;

	/**
	 * Module containing the symbol.
	 */
	istring symbolFile;

	/**
	 * Documentation for the symbol.
	 */
	DocString doc;

	/**
	 * The symbol that represents the type.
	 */
	// TODO: assert that the type is not a function
	DSymbol* type;

	/**
	 * Names of function arguments
	 */
	// TODO: remove since we have function arguments
	//UnrolledList!(istring) argNames;

	/**
	 * Function parameter symbols
	 */
	DSymbol*[] functionParameters;

	/**
	 * Used to resolve the type
	 */
	istring typeSymbolName;

	/**
	 * The string a manifest constant (`enum name = "bar"`) was initialized
	 * with, unquoted.  Only the single-literal shape is folded; anything else
	 * leaves this empty.  Used to resolve `__traits(getMember, T, name)` where
	 * the member name arrives through a constant instead of a literal.
	 */
	istring constantValue;

	/**
	 * For a symbol built by instantiating a template (`instantiateSymbol` in
	 * `dsymbol.conversion.second`): the generic symbol it was instantiated
	 * from, and the arguments it was instantiated with, in declaration order.
	 *
	 * An *instance* can need instantiating again.  `CTX(T) { TD!T data; }`
	 * resolves the member's declared type once, to the instance `TD!T`; a
	 * second instantiation with a mapping that substitutes that argument
	 * (`CTX!Rectf` binds `T -> Rectf`) rebuilds the member from these fields
	 * instead of reusing the instance whose argument is still the parameter.
	 */
	DSymbol* templateSource;
	DSymbol*[] templateArgs;

	/**
	 * The arguments as they were *written* (`T` for `TD!T`).  A template
	 * parameter of the enclosing declaration has no module-level scope of its
	 * own, so `templateArgs[i]` is often null while the name is what a later
	 * mapping has a binding for.
	 */
	istring[] templateArgNames;

	size_t location;
	size_t location_end;

	/**
	 * The kind of symbol
	 */
	CompletionKind kind;

	/**
	 * DSymbol qualifier
	 */
	SymbolQualifier qualifier;

	/**
	 * If true, this symbol owns its type and will free it on destruction
	 */
	// dfmt off

    align(1)
    struct Flags
    {
        bool ownType: 1;
        bool skipOver: 1;
        bool generated: 1;

        bool parameterIsRef: 1;
        bool parameterIsAutoRef: 1;
        bool parameterIsScope: 1;
        bool parameterIsReturn: 1;
        bool parameterIsLazy: 1;
        bool parameterIsOut: 1;
        bool parameterIsIn: 1;

        // `const int x` / `immutable int x` / ... written bare, as a
        // parameter *attribute* -- distinct from `const(int) x`, which is a
        // type constructor parsed into `Parameter.type` instead and never
        // reaches here (see `parseParameterAttribute`'s `peekIs(tok!"(")`
        // check). Only the bare form needs a flag: the type-constructor form
        // already shows up through the type itself wherever a type is
        // rendered from `formatNode` (a raw AST walk, e.g. a function's
        // `callTip`) -- it is only invisible in the *resolved* type graph
        // (`DSymbol.type`), which never tracked qualifiers to begin with.
        bool parameterIsConst: 1;
        bool parameterIsImmutable: 1;
        bool parameterIsShared: 1;
        bool parameterIsInout: 1;

	/**
	 * True while `instantiateSymbol` rebuilds this instance.  A template that
	 * mentions itself (`Node!T next;`) would otherwise rebuild forever: the
	 * member's type is the instance being rebuilt.
	 *
	 * A bit, not a field: as a `bool` member it sits between 16-byte-aligned
	 * fields and pads out to a whole 8-byte slot for 1 bit of information.
	 */
	bool instantiating: 1;

	bool deleted: 1;
    }
    Flags flags;
    //alias ownType = flags.ownType;
    //alias skipOver = flags.skipOver;
    //alias generated = flags.generated;
    //alias parameterIsRef = flags.parameterIsRef;
    //alias parameterIsAutoRef = flags.parameterIsAutoRef;
    //alias parameterIsScope = flags.parameterIsScope;
    //alias parameterIsReturn = flags.parameterIsReturn;
    //alias parameterIsLazy = flags.parameterIsLazy;
    //alias parameterIsOut = flags.parameterIsOut;
    //alias parameterIsIn = flags.parameterIsIn;
    alias this = flags;



	/// Protection level for this symbol
	IdType protection;

	string formatType(string suffix = "") const
	{
		if (kind == CompletionKind.functionName)
		{
			if (type) // try to give return type symbol
				return type.formatType();
			else // null if unresolved, user can manually pick .name or .callTip if needed
				return null;
		}
		else if (name == POINTER_SYMBOL_NAME)
		{
			if (!type)
				return "*" ~ suffix;
			else
				return type.formatType("*" ~ suffix);
		}
		else if (name == ARRAY_SYMBOL_NAME)
		{
			if (!type)
				return "[" ~ callTip ~ "]" ~ suffix;
			else
				return type.formatType("[" ~ callTip ~ "]" ~ suffix);
		}
		else if (name == ASSOC_ARRAY_SYMBOL_NAME)
		{
			string key = callTip.length ? callTip : "...";
			if (!type)
				return "[" ~ key ~ "]" ~ suffix;
			else
				return type.formatType("[" ~ key ~ "]" ~ suffix);
		}
		else if (qualifier == SymbolQualifier.func && signature() !is null)
		{
			// A `T function(Args)` / `T delegate(Args)` type -- not a function
			// declaration, which the branch above formats through its return
			// type. The suffix builder spells the whole type into the
			// signature, return type included.
			return renderSignature(signature()).label ~ suffix;
		}
		else
		{
			// TODO: include template parameters
			return name ~ suffix;
		}
	}
}

/**
 * A documentation comment. Just the resolved text: whether it was written as
 * "ditto" is settled while parsing (see `makeDocumentation`) and read
 * nowhere, so no flag is kept.
 */
struct DocString
{
	/// Creates a comment (already ditto-resolved by the caller).
	this(istring content)
	{
		this.content = content;
	}

	alias content this;

	/// Contains the documentation string associated with this symbol, resolves ditto to the previous comment with correct scope.
	istring content;
}

struct UpdatePair
{
	ptrdiff_t opCmp(ref const UpdatePair other) const pure nothrow @nogc @safe
	{
		return (cast(ptrdiff_t) other.oldSymbol) - (cast(ptrdiff_t) this.oldSymbol);
	}

	DSymbol* oldSymbol;
	DSymbol* newSymbol;
}

alias UpdatePairCollectionAllocator = Mallocator;
alias UpdatePairCollection = TTree!(UpdatePair, UpdatePairCollectionAllocator, false, "a < b");

void generateUpdatePairs(DSymbol* oldSymbol, DSymbol* newSymbol, ref UpdatePairCollection results)
{
    if (oldSymbol == newSymbol) return;

    //warning("insert: ", oldSymbol.name, "->", newSymbol.name);

	//foreach (oldPart; oldSymbol.parts[])
	//{
	//  warning("  oldPart: ", oldPart.name, " kind:", oldPart.kind, " type:", oldPart.type ? oldPart.type.name : "null");
	//}

    
    results.insert(UpdatePair(oldSymbol, newSymbol));

    // Iterate parts[] directly, not opSlice(), to avoid crossing
    // into publicly imported modules and generating wrong cross-module pairs
    foreach (oldPart; oldSymbol.parts[])
    {
        // Skip import symbols — their targets are handled by their
        // own module's re-cache cycle
        //if (oldPart.name == IMPORT_SYMBOL_NAME){
        //	warning("skip: ", oldSymbol.name, " t:", oldPart.type ? oldPart.type.name : "null");
        //    continue;
        //}

        DSymbol* r = null;
        foreach (newPart; newSymbol.parts[])
        {
            //if (newPart.name == IMPORT_SYMBOL_NAME)
            //    continue;
            if (cast(size_t) oldPart.ptr == cast(size_t) newPart.ptr)
            {
                r = newPart;
                break;
            }
            if (oldPart.name == newPart.name && oldPart.kind == newPart.kind)
            {
                r = newPart;
                break;
            }
        }
        if (r is null) continue;
        generateUpdatePairs(oldPart, r, results);
    }
}

/**
 * Inserts a self-pair for every symbol of the tree.
 *
 * Used when a module is re-cached from identical source: there are no new
 * symbol instances to point dependents at, but a dependent that still holds a
 * stale instance (a staggered parse, for example) can be re-pointed at the
 * live one, because updateTypes also matches by name and kind.
 *
 * Iterates parts[] directly for the same reason generateUpdatePairs does:
 * opSlice() would walk into publicly imported modules.
 */
void generateIdentityPairs(DSymbol* symbol, ref UpdatePairCollection results)
{
    if (symbol is null) return;

    results.insert(UpdatePair(symbol, symbol));

    foreach (part; symbol.parts[])
        generateIdentityPairs(part.ptr, results);
}

struct SymbolOwnership
{
	ptrdiff_t opCmp(ref const SymbolOwnership other) const @nogc
	{
		return this.ptr.opCmp(*other.ptr);
	}

	DSymbol* ptr;
	bool owned;
	alias ptr this;
}
