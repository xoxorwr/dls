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

/**
 * Template instantiation: given a generic symbol (an aggregate or a function)
 * and a set of bound type arguments, builds the instantiated copy -- members
 * and return type substituted, an instance name built for display.
 *
 * Used by both the declared-type walker (an explicit `Foo!(int)`) and the
 * initializer inferencer (IFTI deduction from a call), so this module is
 * extracted first (see `docs/refactor-second.md`): the other two import a
 * stable, already-moved module instead of each other's still-in-flux code.
 */
module dsymbol.conversion.second.instantiate;

import dsymbol.conversion.second : identifierName, resolveTypeNodeValue;
import dsymbol.symbol;
import dsymbol.scope_;
import dsymbol.signature;
import dsymbol.string_interning;
import dsymbol.builtin.names;
import dsymbol.builtin.symbols : builtinSymbols;
import dsymbol.modulecache;
import std.experimental.allocator;
import std.experimental.allocator.gc_allocator : GCAllocator;
import dparse.ast;
import dparse.lexer;

/// The first identifier of a declared type (`a.b` -> `a`), for recording how a
/// template argument was *written* (see `DSymbol.templateArgNames`).
private istring firstTypeIdentifierName(const(Type) type)
{
	auto t2 = type.type2;
	if (t2 is null)
		return istring.init;
	if (t2.type !is null)
		return firstTypeIdentifierName(t2.type);
	if (t2.typeIdentifierPart !is null)
		return identifierName(t2.typeIdentifierPart);
	if (t2.builtinType !is tok!"")
		return getBuiltinTypeName(t2.builtinType);
	return istring.init;
}

/// Resolves a template argument written as a bare name (`TD!int`, `TD!T`): the
/// mapping first, then the built-ins, then the scope -- the order the old
/// template-argument capture used.
private DSymbol* lookupTemplateArgument(istring name, Scope* moduleScope,
	DSymbol*[string] mapping)
{
	if (name.length == 0)
		return null;
	if (name.data in mapping)
		return mapping[name.data];
	foreach (candidate; builtinSymbols[])
		if (candidate.name == name)
			return cast(DSymbol*) candidate;
	if (moduleScope is null)
		return null;
	auto symbols = moduleScope.getSymbolsByNameAndCursor(name, 0);
	return symbols.length > 0 ? symbols[0] : null;
}

/// The spelling of a template instance as written (`TD!int`,
/// `TD!(int, int*)`), which is what the instance is named.
private istring renderInstanceCalltip(const(Token)[] tokens)
{
	string calltip;
	foreach (tk; tokens)
	{
		if (tk == tok!"!") calltip ~= "!";
		else if (tk == tok!"(") calltip ~= "(";
		else if (tk == tok!")") calltip ~= ")";
		else if (tk == tok!"[") calltip ~= "[";
		else if (tk == tok!"]") calltip ~= "]";
		else if (tk == tok!",") calltip ~= ", ";
		else if (tk == tok!"*") calltip ~= "*";
		else if (tk == tok!"") calltip ~= " ";
		else
		{
			if (tk.text.length > 0)
				calltip ~= tk.text;
			else
			{
				auto bt = tryGetBuiltinTypeName(tk.type);
				if (bt.length > 0)
					calltip ~= bt;
			}
		}
	}
	return calltip.length > 0 ? internString(calltip) : istring.init;
}

/**
 * Instantiates `base` with the template arguments written at `instance`
 * (`TD!int`, `TD!(int, int*)`).
 *
 * The arguments come from the `TemplateInstance` node: a named argument is a
 * `Type` node, resolved by `resolveTypeNodeValue`, so an argument's own type
 * suffixes are part of what it resolves to (`HashMap!(int, int*)` binds `V` to
 * `int*`); a single-token argument (`TD!int`) is looked up by name.  `tokens`
 * is the instance's source spelling and becomes the instance's name.
 */
package DSymbol* instantiateFromNode(DSymbol* base, const(TemplateInstance) instance,
	const(Token)[] tokens, DSymbol* symbol, Scope* moduleScope, ref ModuleCache cache,
	DSymbol*[string] mapping)
{
	if (base is null || instance is null)
		return base;
	// Only an aggregate carries template parameters; the old
	// `instantiateSymbol` checked the same kinds before instantiating.
	switch (base.kind)
	{
	case CompletionKind.structName:
	case CompletionKind.className:
	case CompletionKind.interfaceName:
	case CompletionKind.templateName:
	case CompletionKind.functionName:
		break;
	default:
		return base;
	}

	DSymbol*[] args;
	istring[] argNames;
	bool unresolved;

	auto targs = instance.templateArguments;
	if (targs !is null && targs.namedTemplateArgumentList !is null)
	{
		foreach (targ; targs.namedTemplateArgumentList.items)
		{
			DSymbol* argSymbol;
			istring written;
			if (targ !is null && targ.type !is null)
			{
				bool ok;
				argSymbol = resolveTypeNodeValue(targ.type, symbol, moduleScope, cache,
					mapping, ok, true);
				written = firstTypeIdentifierName(targ.type);
			}
			args ~= argSymbol;
			argNames ~= written;
			if (argSymbol is null)
				unresolved = true;
		}
	}
	else if (targs !is null && targs.templateSingleArgument !is null)
	{
		auto token = targs.templateSingleArgument.token;
		auto written = token.text.length > 0 ? token.text : str(token.type);
		DSymbol* argSymbol;
		if (written.length > 0)
			argSymbol = lookupTemplateArgument(internString(written), moduleScope, mapping);
		args ~= argSymbol;
		argNames ~= internString(written);
		if (argSymbol is null)
			unresolved = true;
	}

	if (args.length == 0)
		return base;
	// The written names are only needed for an argument that could not be
	// resolved (a template parameter of the enclosing declaration); recording
	// them otherwise costs an array per instance.
	if (!unresolved)
		argNames = null;
	return instantiateAggregate(base, args, argNames, moduleScope, cache, mapping,
		renderInstanceCalltip(tokens), true);
}

package DSymbol* instantiateSymbol(DSymbol* s, Scope* moduleScope, ref ModuleCache cache,
	DSymbol*[string] mapping = null)
{
	if (s is null) return null;

	// 1. If it's a template parameter, resolve it from the mapping
	if (s.kind == CompletionKind.typeTmpParam || s.kind == CompletionKind.variadicTmpParam)
	{
		if (s.name in mapping)
			return mapping[s.name];
		return s;
	}

	// 2. If it's a pointer or array, instantiate the underlying type
	if (s.name == POINTER_SYMBOL_NAME || s.name == ARRAY_SYMBOL_NAME || s.name == ASSOC_ARRAY_SYMBOL_NAME)
	{
		auto instantiatedType = instantiateSymbol(s.type, moduleScope, cache, mapping);
		if (instantiatedType == s.type) return s;

		auto next = GCAllocator.instance.make!DSymbol(s.name, s.kind, instantiatedType);
		next.qualifier = s.qualifier;
		next.ownType = false;
		// `RenderedText` is immutable once built, same as `Signature` -- share
		// the pointer rather than copy the string. Null for a pointer wrapper
		// (its dimension is always empty, so one was never allocated).
		next.setRenderedText(s.renderedText());
		next.addChildren(s.opSlice(), false);
		return next;
	}

	// 2b. An *instance* whose recorded arguments this mapping substitutes.
	// `CTX(T) { TD!T data; }` resolved the member's declared type once, to the
	// instance `TD!T`, built with the argument `T`.  Instantiating `CTX!Rectf`
	// has to rebuild that member as `TD!Rectf`: reusing the instance would
	// leave every member of `data` reporting the parameter `T`.
	// `templateSource` points into the module that declared the template; if
	// that module was re-cached since, the whole old tree was disposed (every
	// symbol's destructor sets `deleted`), and rebuilding from it is not an
	// option -- the instance is reused exactly as it was before.
	if (s.templateSource !is null && !s.templateSource.deleted
		&& s.templateArgs.length > 0 && mapping.length > 0 && !s.instantiating)
	{
		// Only an argument the mapping has a binding for can change, and most
		// instances carry concrete arguments (`TD!int`): checking that first
		// keeps the common case from allocating a substituted copy at all.
		bool affected;
		foreach (i, arg; s.templateArgs)
		{
			auto name = i < s.templateArgNames.length ? s.templateArgNames[i] : istring.init;
			if (argumentIsAffected(arg, name, mapping, 0))
			{
				affected = true;
				break;
			}
		}
		if (!affected)
			return s;

		DSymbol*[] substituted = new DSymbol*[s.templateArgs.length];
		bool changed = false;
		foreach (i, arg; s.templateArgs)
		{
			DSymbol* newArg = arg;
			if (newArg is null)
			{
				// The argument was written as a name this scope could not
				// resolve (`TD!T` inside `CTX(T)`: `T` is a template
				// parameter, not a module-level symbol); the new mapping may
				// have a binding for that name.
				if (i < s.templateArgNames.length && s.templateArgNames[i].length > 0
					&& s.templateArgNames[i].data in mapping)
					newArg = mapping[s.templateArgNames[i].data];
			}
			else
				newArg = instantiateSymbol(newArg, moduleScope, cache, mapping);
			substituted[i] = newArg;
			if (substituted[i] !is arg)
				changed = true;
		}
		if (changed)
		{
			// A self-referential template (`Node!T next;`) reaches this same
			// instance again through the member it is rebuilding.
			s.instantiating = true;
			scope(exit) s.instantiating = false;
			// `force`: the substituted argument is already in the mapping, so
			// "nothing changed" is true by construction; the instance still
			// has to be built (the source is the *generic* symbol).
			return instantiateAggregate(s.templateSource, substituted,
				null, moduleScope, cache, mapping, istring.init, true);
		}
	}

	return s;
}

/**
 * Whether `symbol` declares template parameters of its own (`TD(T)`), in
 * which case an instance built from it can have members still spelled with
 * those parameters.
 */
// `public` on purpose: `dsymbol.conversion.second` re-exports it, and the
// completion path asks this before binding a call's arguments.
public bool hasTemplateParameters(const DSymbol* symbol)
{
	if (symbol is null)
		return false;
	foreach (part; symbol.parts[])
		if (part.ptr.kind == CompletionKind.typeTmpParam
			|| part.ptr.kind == CompletionKind.variadicTmpParam)
			return true;
	return false;
}

/**
 * Whether `mapping` binds something an instance's recorded argument would be
 * substituted through -- the argument itself when it is a template parameter
 * (or an unresolved name), or one of its own arguments when it is a nested
 * instance.  Used to skip rebuilding instances that cannot change; the depth
 * bound is there because a template may mention itself.
 */
private bool argumentIsAffected(DSymbol* arg, istring name, DSymbol*[string] mapping, uint depth)
{
	if (depth > 8)
		return false;
	if (arg is null)
		return name.length > 0 && name.data in mapping;
	if ((arg.kind == CompletionKind.typeTmpParam || arg.kind == CompletionKind.variadicTmpParam)
		&& arg.name in mapping)
		return true;
	if (arg.templateSource is null || arg.templateSource.deleted)
		return false;
	foreach (i, nested; arg.templateArgs)
	{
		auto nestedName = i < arg.templateArgNames.length ? arg.templateArgNames[i] : istring.init;
		if (argumentIsAffected(nested, nestedName, mapping, depth + 1))
			return true;
	}
	return false;
}

/**
 * Builds an instance of the aggregate `s` with the template arguments `args`,
 * matching them to `s`'s template parameters in declaration order and
 * substituting them in every member type and in the return type.
 *
 * `calltip`, when set, is the spelling of the arguments (`TD!(int)`) and is
 * used as the instance's name; otherwise one is built from `args`.  `force`
 * keeps the behaviour of an explicit instantiation: with no argument (and a
 * mapping that adds nothing) the original symbol could be returned instead,
 * but an instance requested by name is always made.
 */
package DSymbol* instantiateAggregate(DSymbol* s, DSymbol*[] args, istring[] argNames,
	Scope* moduleScope, ref ModuleCache cache, DSymbol*[string] mapping,
	istring calltip, bool force)
{
	DSymbol*[string] nextMapping;
	// Inherit outer mapping
	foreach (k, v; mapping) nextMapping[k] = v;

	// If we have new arguments, match parameters to arguments
	if (args.length > 0)
	{
		// Find all template parameters of s
		DSymbol*[] params;
		// The symbol's own parameters only: 'opSlice' would also hand over the
		// parameters of every template an import child reaches (a mixin
		// template's `U` next to this symbol's `T`), and matching those
		// against the arguments shifts every binding by one.
		foreach (ownership; s.parts[])
			if (ownership.ptr.kind == CompletionKind.typeTmpParam
				|| ownership.ptr.kind == CompletionKind.variadicTmpParam)
				params ~= ownership.ptr;

		import std.algorithm.sorting : sort;
		sort!((a, b) => a.location < b.location)(params);

		foreach (i, p; params)
		{
			if (i < args.length && args[i] !is null)
				nextMapping[p.name] = args[i];
		}
	}

	// If nothing changed in the mapping, no need to instantiate
	if (nextMapping.length == mapping.length)
	{
		bool changed = false;
		foreach (k, v; nextMapping)
			if (k !in mapping || mapping[k] != v) { changed = true; break; }
		if (!changed && !force) return s;
	}

	// The generic symbol the instance stands for; an instance built from
	// another instance keeps the original.
	DSymbol* source = s.templateSource !is null ? s.templateSource : s;

	// Create the instantiated symbol
	// Recursively instantiate the type field (e.g. function return type)
	DSymbol* instantiatedType = s.type;
	if (s.type !is null && s.type !is s)
		instantiatedType = instantiateSymbol(s.type, moduleScope, cache, nextMapping);

	auto instantiated = GCAllocator.instance.make!DSymbol(s.name, s.kind, instantiatedType);
	instantiated.qualifier = s.qualifier;
	instantiated.protection = s.protection;
	instantiated.symbolFile = s.symbolFile;
	instantiated.location = s.location;
	instantiated.location_end = s.location_end;
	instantiated.doc = s.doc;
	instantiated.setSignature(s.signature());
	instantiated.flags = s.flags;

	// Remember what this instance stands for, so a later instantiation can
	// substitute its arguments (see case 2b of `instantiateSymbol`).
	if (args.length > 0)
	{
		instantiated.templateSource = source;
		instantiated.templateArgs = args;
		if (argNames.length == args.length)
			instantiated.templateArgNames = argNames;
		else
		{
			// No names were carried over (a rebuilt instance).  An argument
			// that *is* a symbol is matched by its symbol later, so names are
			// only recorded when something could not be resolved.
			bool unresolved;
			foreach (arg; args)
				if (arg is null)
				{
					unresolved = true;
					break;
				}
			if (unresolved)
				foreach (arg; args)
					instantiated.templateArgNames ~= arg is null ? istring.init : arg.name;
		}
		// If it's a templated type with arguments, update name to include
		// calltip for better display
		if (calltip.length > 0)
			instantiated.name = calltip;
		else if (s.kind != CompletionKind.functionName)
			instantiated.name = buildInstanceName(source, args);
	}

	// Populate members, instantiating them if they use template parameters.
	// The symbol's own children are walked rather than 'opSlice', which
	// flattens imports into the member list: an `import` child is what carries
	// a base class, an `alias this` or a mixin template, and its *type* is
	// what the mapping has to be applied to.  Copying the flattened members
	// instead loses everything an import reaches through a template parameter
	// (`alias value this;` in `Maybe(T)` has to follow `value` to the
	// instantiated `User`).
	foreach (ownership; s.parts[])
	{
		auto part = ownership.ptr;
		if (part.kind == CompletionKind.importSymbol)
		{
			auto importType = instantiateSymbol(part.type, moduleScope, cache, nextMapping);
			// The child can still point at a *generic* aggregate: a base class
			// or mixin template written without arguments (`class D(T) :
			// Base`) reaches the template itself, not an instance.  Its
			// members have to follow this instance's mapping too, or its
			// parameters leak into the member list (`T` offered as a member of
			// `D!int`) and its members keep reporting `T`.
			if (importType !is null && hasTemplateParameters(importType))
				importType = instantiateAggregate(importType, null, null, moduleScope, cache,
					nextMapping, istring.init, true);
			if (importType is null)
				continue;

			auto newImport = GCAllocator.instance.make!DSymbol(part.name, part.kind, importType);
			newImport.qualifier = part.qualifier;
			newImport.protection = part.protection;
			newImport.symbolFile = part.symbolFile;
			newImport.location = part.location;
			newImport.location_end = part.location_end;
			newImport.flags = part.flags;
			// The type is shared with the symbol this instance was built from.
			newImport.ownType = false;
			instantiated.addChild(newImport, true);
			continue;
		}
		if (part.kind == CompletionKind.typeTmpParam || part.kind == CompletionKind.variadicTmpParam) continue;

		// If type is null and it's a variable, it might have typeSymbolName that needs resolution
		DSymbol* partType = part.type;
		if (partType is null && part.typeSymbolName.length > 0)
		{
			// Try to resolve the type name using the mapping
			if (part.typeSymbolName in nextMapping)
				partType = nextMapping[part.typeSymbolName];
		}

		auto newPartType = instantiateSymbol(partType, moduleScope, cache, nextMapping);
		if (newPartType != part.type)
		{
			auto newPart = GCAllocator.instance.make!DSymbol(part.name, part.kind, newPartType);
			newPart.qualifier = part.qualifier;
			newPart.protection = part.protection;
			newPart.symbolFile = part.symbolFile;
			newPart.location = part.location;
			newPart.location_end = part.location_end;
			newPart.doc = part.doc;
			newPart.flags = part.flags;
			// The signature was built while parsing, from the *generic*
			// declaration (`V get(K key)`); now that this copy's return type
			// is concrete, its leading type has to follow.
			if (part.kind == CompletionKind.functionName)
				newPart.setSignature(substituteSignatureReturnType(part.signature(),
					part.type, newPartType));
			else
				newPart.setSignature(part.signature());
			instantiated.addChild(newPart, true);
		}
		else
		{
			instantiated.addChild(cast(DSymbol*)part, false);
		}
	}
	return instantiated;
}

/**
 * Instantiates `symbol` (a template or a templated function) with explicit
 * template arguments, the way `foo!Bar` does: `symbol`'s template parameters
 * are matched to `args` in declaration order and its members and return type
 * are instantiated with the resulting mapping.
 *
 * This is what a *call* needs (`make!int().member`): without it the return
 * type stays the unbound instance `TD!T`, because the mapping from the
 * function's parameters to the call's explicit arguments is never built.
 *
 * Instantiation walks the symbol's own parts only, so the scratch cache is
 * never touched -- the internal entry point takes one by reference.
 */
// `public` on purpose: `dsymbol.conversion.second` re-exports it, and the
// completion path (dcd.server.autocomplete.util) has to call this one.
public DSymbol* instantiateWithArguments(DSymbol* symbol, DSymbol*[] args)
{
	if (symbol is null || args.length == 0)
		return symbol;
	final switch (symbol.kind)
	{
	case CompletionKind.structName:
	case CompletionKind.className:
	case CompletionKind.templateName:
	case CompletionKind.functionName:
		break;
	case CompletionKind.interfaceName:
	case CompletionKind.unionName:
	case CompletionKind.enumName:
	case CompletionKind.variableName:
	case CompletionKind.memberVariableName:
	case CompletionKind.importSymbol:
	case CompletionKind.packageName:
	case CompletionKind.moduleName:
	case CompletionKind.keyword:
	case CompletionKind.enumMember:
	case CompletionKind.aliasName:
	case CompletionKind.withSymbol:
	case CompletionKind.ufcsName:
	case CompletionKind.typeTmpParam:
	case CompletionKind.variadicTmpParam:
	case CompletionKind.mixinTemplateName:
	case CompletionKind.dummy:
		return symbol;
	}
	ModuleCache scratch;
	return instantiateAggregate(symbol, args, null, null, scratch, null, istring.init, false);
}

/// `TD!Rectf` / `TD!(Rectf, int)` -- the name of a rebuilt instance.
private istring buildInstanceName(const DSymbol* source, DSymbol*[] args)
{
	import std.array : appender;
	auto app = appender!string();
	app.put(source.name.data);
	if (args.length == 1)
	{
		app.put('!');
		app.put(argumentName(args[0]));
	}
	else
	{
		app.put("!(");
		foreach (i, arg; args)
		{
			if (i > 0) app.put(", ");
			app.put(argumentName(arg));
		}
		app.put(')');
	}
	return istring(app.data);
}

private string argumentName(const DSymbol* arg)
{
	if (arg is null)
		return "?";
	auto formatted = arg.formatType();
	return formatted.length > 0 ? formatted : arg.name.data;
}

/**
 * Returns a copy of a signature whose return type is replaced.
 *
 * The signature was built from the *generic* declaration (`V get(K key)`), so
 * a completion description or signature hint built from it would keep
 * advertising the parameter of an instance whose return type is concrete.
 * Only the return type is replaced, and only when it really is the old type's
 * rendering; the parameter lists are left as written.
 *
 * The original is not mutated: `signature` may be shared with the symbol it
 * came from (the generic declaration, or another instance).
 */
package Signature* substituteSignatureReturnType(const Signature* signature,
	const DSymbol* oldType, const DSymbol* newType)
{
	auto unchanged = cast(Signature*) signature;
	if (signature is null || signature.returnType.length == 0
		|| oldType is null || newType is null)
		return unchanged;
	auto written = oldType.formatType();
	auto replacement = newType.formatType();
	if (written.length == 0 || replacement.length == 0 || written == replacement)
		return unchanged;
	if (signature.returnType.data != written)
		return unchanged;
	auto substituted = GCAllocator.instance.make!Signature();
	*substituted = *cast(Signature*) signature;
	substituted.returnType = internString(replacement);
	return substituted;
}
