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

module dsymbol.conversion.second;

import dsymbol.semantic;
import dsymbol.string_interning;
import dsymbol.symbol;
import dsymbol.scope_;
import dsymbol.builtin.names;
import dsymbol.builtin.symbols : builtinSymbols;
import dsymbol.builtin.symbols;
import dsymbol.type_lookup;
import dsymbol.deferred;
import dsymbol.import_;
import dsymbol.modulecache;
import std.experimental.allocator;
import std.experimental.allocator.gc_allocator : GCAllocator;
import std.experimental.logger;
import dparse.ast;
import dparse.lexer;
import std.algorithm : filter;
import std.range;
import io = std.stdio;

void DBG(F, A...)(F f, A args)
{
    //debug io.writeln(f, args);
}
package void writeln(F, A...)(F f, A args)
{
    //debug io.writeln(f, args);
}

package void write(F, A...)(F f, A args)
{
    //debug io.write(f, args);
}

void print_tab(int index)
{
    //debug index +=1;
    //debug enum C = 4;
    //debug for(int i =0; i < index*4; i++) io.write(" ");
}

void secondPass(SemanticSymbol* rootModule, SemanticSymbol* currentSymbol, Scope* moduleScope, ref ModuleCache cache)
{
    writeln("-- second pass: begin");
	with (CompletionKind) final switch (currentSymbol.acSymbol.kind)
	{
	case className:
	case interfaceName:
		resolveInheritance(currentSymbol.acSymbol, currentSymbol.typeLookups,
			moduleScope, cache);
		break;
	case withSymbol:
	case variableName:
	case memberVariableName:
	case functionName:
	case ufcsName:
	case aliasName:
		// type may not be null in the case of a renamed import
		if (currentSymbol.acSymbol.type is null)
		{
			resolveType(currentSymbol.acSymbol, currentSymbol.typeLookups,
				moduleScope, cache);
		}
		break;
	case importSymbol:
		if (currentSymbol.acSymbol.type is null)
			resolveImport(rootModule.acSymbol, currentSymbol.acSymbol, currentSymbol.typeLookups, cache);

		//warning("root: ", rootModule.acSymbol.symbolFile, " >import> ", currentSymbol.acSymbol.symbolFile, " public:", currentSymbol.acSymbol.skipOver == false);

		//auto importedFromSym = GCAllocator.instance.make!DSymbol("*public_imported*", CompletionKind.dummy, rootModule.acSymbol);
		//currentSymbol.acSymbol.addChild(importedFromSym, true);

		break;
	case variadicTmpParam:
		currentSymbol.acSymbol.type = variadicTmpParamSymbol;
		break;
	case typeTmpParam:
		currentSymbol.acSymbol.type = typeTmpParamSymbol;
		break;
	case structName:
	case unionName:
	case enumName:
	case keyword:
	case enumMember:
	case packageName:
	case moduleName:
	case dummy:
	case templateName:
	case mixinTemplateName:
		break;
	}

	// let's be methodic about the way we traverse symbols
	// so that childs have access to resolved symbols
	// functions should be last, because inside, there might be symbols that references
	// code from the parent not yet resolved (templates)
    if (currentSymbol && currentSymbol.children.length)
	foreach (child; currentSymbol.children)
		if (child.acSymbol.kind != CompletionKind.variableName && child.acSymbol.kind != CompletionKind.functionName)
			secondPass(rootModule, child, moduleScope, cache);

	foreach (child; currentSymbol.children)
		if (child.acSymbol.kind == CompletionKind.variableName)
			secondPass(rootModule, child, moduleScope, cache);

	foreach (child; currentSymbol.children)
		if (child.acSymbol.kind == CompletionKind.functionName)
			secondPass(rootModule, child, moduleScope, cache);

	// `alias T = typeof(x)` / `alias M = __traits(getMember, T, n)` resolve in
	// the first loop above, before the variables they name (second loop), so a
	// first attempt can forward to an as-yet-unresolved operand.  Retry the
	// suspicious ones now that every sibling resolved: idempotent for healthy
	// aliases, and a bounded fixpoint so `alias M` after `alias T` settles too.
	foreach (i; 0 .. 4)
	{
		bool progressed = false;
		foreach (child; currentSymbol.children)
		{
			if (child.acSymbol.kind != CompletionKind.aliasName
				|| !aliasNeedsRetry(child.acSymbol))
				continue;
			resolveType(child.acSymbol, child.typeLookups, moduleScope, cache);
			if (!aliasNeedsRetry(child.acSymbol))
				progressed = true;
		}
		if (!progressed)
			break;
	}


	// Alias this and mixin templates are resolved after child nodes are
	// resolved so that the correct symbol information will be available.
	with (CompletionKind) switch (currentSymbol.acSymbol.kind)
	{
	case className:
	case interfaceName:
	case structName:
	case unionName:
		resolveAliasThis(currentSymbol.acSymbol, currentSymbol.typeLookups, moduleScope, cache);
		resolveMixinTemplates(currentSymbol.acSymbol, currentSymbol.typeLookups,
			moduleScope, cache);
		break;
	default:
		break;
	}

    writeln("-- second pass: end");
    writeln("");
    writeln("");
    writeln("");
    writeln("");
}
void resolveImport(DSymbol* rootModule, DSymbol* acSymbol, ref TypeLookups typeLookups,
	ref ModuleCache cache)
in
{
	assert(acSymbol.kind == CompletionKind.importSymbol);
	assert(acSymbol.symbolFile !is null);
}
do
{

	DSymbol* moduleSymbol = cache.cacheModule(acSymbol.symbolFile);


	if (acSymbol.qualifier == SymbolQualifier.selectiveImport)
	{
		if (moduleSymbol is null)
		{
		tryAgain:
			DeferredSymbol* deferred = DeferredSymbolsAllocator.instance.make!DeferredSymbol(acSymbol);
			deferred.typeLookups.insert(typeLookups[]);
			// Get rid of the old references to the lookups, this new deferred
			// symbol owns them now
			typeLookups.clear();
			cache.deferredSymbols.insert(deferred);
		}
		else
		{
			// The bind's data, recorded by the producer: `import m : a;` binds
			// `a`, `import m : b = c;` binds `c` under the alias `b`.  It is
			// interned data rather than the `ImportBind` node because a
			// deferred import outlives the importing module's tree.
			immutable bool renamed = typeLookups.empty
				? false : typeLookups.front.selectiveImportRenamed;
			istring symbolName = typeLookups.empty
				? istring.init : typeLookups.front.selectiveImportName;
			DSymbol* selected = symbolName.length > 0
				? moduleSymbol.getFirstPartNamed(symbolName) : null;
			if (selected is null)
				goto tryAgain;
			acSymbol.type = selected;
			acSymbol.ownType = false;

			if (renamed)
			{
				acSymbol.kind = CompletionKind.aliasName;
				acSymbol.symbolFile = acSymbol.altFile;
			}

			// The bind's data has been used: the symbol points at the
			// declaration it binds now.  Keeping the lookup makes later
			// passes read this alias as something with a type expression of
			// its own (`resolveType` is handed every alias whose operand is
			// still unresolved), and a selective import has none - it used to
			// end in `resolveType`'s "How did this happen?" assertion, taking
			// the server down for any module that renamed a still-unresolved
			// symbol (`import std.traits : CoreUnconst = Unconst;`).
			typeLookups.clear();
		}
	}
	else
	{
		if (moduleSymbol is null)
		{
			DeferredSymbol* deferred = DeferredSymbolsAllocator.instance.make!DeferredSymbol(
				acSymbol);
			cache.deferredSymbols.insert(deferred);
		}
		else
		{
			acSymbol.type = moduleSymbol;
			acSymbol.ownType = false;
		}
	}
}

/// The symbol a type suffix builds (array, associative array, pointer), shared
/// by the declared-type walker and the template-argument walker: same marker,
/// same qualifier, same children.
private DSymbol* wrapTypeSymbol(R)(istring marker, SymbolQualifier qualifier, DSymbol* inner,
	istring dimension, R children)
{
	auto next = GCAllocator.instance.make!DSymbol(marker, CompletionKind.dummy, inner);
	next.qualifier = qualifier;
	next.ownType = false;
	next.callTip = dimension;
	next.addChildren(children, false);
	return next;
}

/**
 * How a declared-type node resolved: the base name is a symbol, the base name
 * is not in scope here (the name-based retry takes over), or the node is a
 * shape this walker does not model (the type is left unset).
 */
private enum TypeNodeOutcome : ubyte
{
	resolved,
	unresolved,
	unmodelled,
}

/// The identifier of one `TypeIdentifierPart` (a template instance's
/// identifier for `Foo!(int)`), or an empty string when there is none.
private istring identifierName(const TypeIdentifierPart tip)
{
	if (tip is null)
		return istring.init;
	return identifierName(tip.identifierOrTemplateInstance);
}

/// The name of `foo` / `foo!(int)`, or an empty string when there is none.
private istring identifierName(const(IdentifierOrTemplateInstance) ioti)
{
	if (ioti is null)
		return istring.init;
	if (ioti.identifier != tok!"")
		return internString(ioti.identifier.text);
	if (ioti.templateInstance !is null && ioti.templateInstance.identifier != tok!"")
		return internString(ioti.templateInstance.identifier.text);
	return istring.init;
}

/**
 * Resolves a *declared type* (a `varOrFunType` lookup) from its AST node.
 *
 * The base name chain, the captured template arguments (`lookup.ctx`), then
 * the type suffixes in source order, each built by the same `wrapTypeSuffix`
 * the argument walker uses -- so `typeSwap` / `getParts` / `formatType` see
 * the same graph the old crumb encoding produced.
 *
 * Returns false, leaving `symbol` untouched, for a node shape the walker does
 * not model (`typeof`, `__vector`, a type selected out of a template argument
 * list) and when there is no scope to resolve names in.  The null-scope case
 * is the deferred retry, and it is the one path where a node could outlive the
 * tree it points into (see PLAN2.md section 5), so this walker only runs while
 * the tree is alive.
 */
private bool resolveTypeFromTypeNode(const(Type) type, DSymbol* symbol, TypeLookup* lookup,
	Scope* moduleScope, ref ModuleCache cache, DSymbol*[string] mapping, out DSymbol* result)
{
	if (type is null || type.type2 is null || moduleScope is null)
		return false;

	DSymbol* base;
	istring missingName;
	auto outcome = resolveDeclaredType(type, symbol, lookup, moduleScope, cache, mapping,
		base, missingName);
	if (outcome == TypeNodeOutcome.unmodelled)
		return false;
	// `TD!int`: apply the instance written at the head of the type to what the
	// name chain resolved to, before the suffixes wrap it.
	if (outcome == TypeNodeOutcome.resolved)
	{
		auto ioti = headTemplateInstance(type);
		if (ioti !is null && lookup.applyTypeInstance)
			base = instantiateFromNode(base, ioti.templateInstance, ioti.tokens, symbol,
				moduleScope, cache, mapping);
	}

	if (type.typeSuffixes.length == 0)
	{
		if (outcome == TypeNodeOutcome.resolved)
		{
			symbol.type = base;
			symbol.ownType = false;
			result = base;
		}
		else
		{
			// The base name is not in scope here: record it for the name-based
			// retry, exactly as the crumb walk's first step does.
			if (missingName.length > 0)
				symbol.typeSymbolName = missingName;
			result = null;
		}
		return true;
	}

	// Suffixes: built inner (source order) to outer, matching the crumb walk's
	// `foreach_reverse` over its popped suffix list.  A base that could not be
	// resolved leaves the deferred name on the innermost suffix, which is where
	// the crumb walk leaves it too.
	istring deferredName = outcome == TypeNodeOutcome.resolved ? istring.init : missingName;
	DSymbol* current = base;
	foreach (suffix; type.typeSuffixes)
	{
		auto next = wrapTypeSuffix(current, suffix, type);
		if (current is null && deferredName.length > 0)
		{
			next.typeSymbolName = deferredName;
			deferredName = istring.init;
		}
		current = next;
	}
	symbol.type = current;
	symbol.ownType = true;
	result = current;
	return true;
}

/// `typeof(expr)`: the type of what the expression stands for, evaluated with
/// the same walker an initializer uses (`typeof(foo)` for `foo` of type
/// `Foo!int` is the instance).  Anything the initializer walker does not
/// model leaves the outcome unmodelled, exactly as before.
private TypeNodeOutcome resolveTypeofExpression(const(TypeofExpression) te, DSymbol* symbol,
	TypeLookup* lookup, Scope* moduleScope, ref ModuleCache cache, DSymbol*[string] mapping,
	out DSymbol* current, out istring missingName)
{
	current = null;
	missingName = istring.init;
	if (te is null || te.expression is null)
		return TypeNodeOutcome.unmodelled;
	DSymbol* value;
	bool handled;
	resolveInitializerNode(te.expression, symbol, lookup, moduleScope, cache, mapping,
		handled, value);
	if (!handled || value is null)
		return TypeNodeOutcome.unmodelled;
	typeSwap(value);
	if (value is null)
		return TypeNodeOutcome.unresolved;
	// Forwarding to an operand that has not resolved yet (`alias T =
	// typeof(x)` running before `x`) would freeze the alias at the operand
	// itself.  Leave the type unset instead: the alias retry pass in
	// `secondPass` re-runs once the siblings resolved.
	if ((value.kind == CompletionKind.variableName
			|| value.kind == CompletionKind.memberVariableName
			|| value.kind == CompletionKind.functionName
			|| value.kind == CompletionKind.enumMember
			|| value.kind == CompletionKind.aliasName)
		&& value.type is null)
		return TypeNodeOutcome.unresolved;
	current = value;
	return TypeNodeOutcome.resolved;
}

/// `__traits(getMember, Base, name)`: the member of `Base` called `name`.
/// Only this trait is modelled, and `name` must fold to a string: either a
/// literal or a manifest constant (`enum name = "bar"`) recorded by the first
/// pass.  Anything else stays unmodelled.
private TypeNodeOutcome resolveTraitsExpression(const(TraitsExpression) tr, DSymbol* symbol,
	TypeLookup* lookup, Scope* moduleScope, ref ModuleCache cache, DSymbol*[string] mapping,
	out DSymbol* current, out istring missingName)
{
	current = null;
	missingName = istring.init;
	if (tr is null || tr.identifier.text != "getMember"
		|| tr.templateArgumentList is null
		|| tr.templateArgumentList.items.length != 2)
		return TypeNodeOutcome.unmodelled;

	DSymbol* base;
	auto arg0 = cast() tr.templateArgumentList.items[0];
	if (arg0 is null)
		return TypeNodeOutcome.unmodelled;
	if (arg0.type !is null)
	{
		bool ok;
		base = resolveTypeNodeValue(arg0.type, symbol, moduleScope, cache, mapping, ok, true);
		if (!ok)
			return TypeNodeOutcome.unmodelled;
	}
	else if (arg0.assignExpression !is null)
	{
		bool handled;
		resolveInitializerNode(arg0.assignExpression, symbol, lookup, moduleScope, cache,
			mapping, handled, base);
		if (!handled)
			return TypeNodeOutcome.unmodelled;
		typeSwap(base);
	}
	else
		return TypeNodeOutcome.unmodelled;
	if (base is null)
		return TypeNodeOutcome.unresolved;

	istring memberName;
	if (!foldTraitMemberName(cast() tr.templateArgumentList.items[1], symbol, moduleScope,
			memberName) || memberName.length == 0)
		return TypeNodeOutcome.unmodelled;

	current = memberStep(base, memberName, moduleScope);
	if (current is null)
		return TypeNodeOutcome.unresolved;
	return TypeNodeOutcome.resolved;
}

/// Folds the member-name argument of `__traits(getMember, ...)`: a plain
/// `"literal"`, or an identifier bound to a manifest string constant.
///
/// A bare identifier parses as a *type* (`name` in `getMember(T, name)`), so
/// both shapes are handled: an expression (literals) and a single-part type
/// (identifier constants).
private bool foldTraitMemberName(const(TemplateArgument) arg, DSymbol* symbol,
	Scope* moduleScope, out istring memberName)
{
	memberName = istring.init;
	if (arg is null)
		return false;
	if (arg.assignExpression !is null)
	{
		auto tokens = arg.assignExpression.tokens;
		if (tokens.length != 1)
			return false;
		auto t = tokens[0];
		if (t.type == tok!"stringLiteral" || t.type == tok!"wstringLiteral"
			|| t.type == tok!"dstringLiteral")
			return unquoteTraitLiteral(t.text, memberName);
		if (t.type == tok!"identifier")
			return resolveConstantName(internString(t.text), symbol, moduleScope,
				memberName);
		return false;
	}
	if (arg.type !is null)
	{
		auto t2 = arg.type.type2;
		if (t2 is null || t2.typeIdentifierPart is null
			|| arg.type.typeSuffixes.length > 0)
			return false;
		auto tip = t2.typeIdentifierPart;
		if (tip.typeIdentifierPart !is null)
			return false;
		auto ioti = tip.identifierOrTemplateInstance;
		if (ioti is null || ioti.templateInstance !is null
			|| ioti.identifier == tok!"")
			return false;
		return resolveConstantName(internString(ioti.identifier.text), symbol,
			moduleScope, memberName);
	}
	return false;
}

/// Unquotes a plain `"literal"` trait argument; anything else (q{}, prefixed
/// strings) is left unfolded.
private bool unquoteTraitLiteral(string text, out istring memberName)
{
	memberName = istring.init;
	if (text.length < 2)
		return false;
	immutable char q = text[0];
	if ((q != '"' && q != '\'' && q != '`') || text[$ - 1] != q)
		return false;
	memberName = internString(text[1 .. $ - 1]);
	return true;
}

/// Follows an identifier to the manifest string constant it names
/// (`enum name = "bar"`, recorded by the first pass), through one alias hop.
private bool resolveConstantName(istring name, DSymbol* symbol, Scope* moduleScope,
	out istring memberName)
{
	memberName = istring.init;
	auto target = moduleScope.getFirstSymbolByNameAndCursor(name, symbol.location);
	if (target is null)
		return false;
	if (target.constantValue.length > 0)
	{
		memberName = target.constantValue;
		return true;
	}
	if (target.kind == CompletionKind.aliasName && target.type !is null
		&& target.type.constantValue.length > 0)
	{
		memberName = target.type.constantValue;
		return true;
	}
	return false;
}

/// Whether an alias still points at an operand that was unresolved when it
/// ran: null-typed variables, functions, enum members and aliases down the
/// chain (`alias T = typeof(x)` forwarding to `x` before `x` resolved).
/// Healthy aliases (`alias A = int`, `alias M = <resolved member>`) answer no.
private bool aliasNeedsRetry(DSymbol* symbol)
{
	if (symbol is null || symbol.type is null)
		return true;
	DSymbol* t = symbol.type;
	size_t n = 0;
	while (t !is null && n++ < 10)
	{
		if (t.type is null)
			return t.kind == CompletionKind.variableName
				|| t.kind == CompletionKind.memberVariableName
				|| t.kind == CompletionKind.functionName
				|| t.kind == CompletionKind.enumMember
				|| t.kind == CompletionKind.aliasName;
		t = t.type;
	}
	return false;
}

/// Resolves everything up to a declared type's suffixes: the operand of a type
/// constructor (`const(T)`) fully, or the base name chain with the lookup's
/// template arguments applied.
private TypeNodeOutcome resolveDeclaredType(const(Type) type, DSymbol* symbol, TypeLookup* lookup,
	Scope* moduleScope, ref ModuleCache cache, DSymbol*[string] mapping,
	out DSymbol* current, out istring missingName)
{
	auto t2 = type.type2;
	current = null;
	missingName = istring.init;
	if (t2 is null)
		return TypeNodeOutcome.unmodelled;

	if (t2.type !is null)
	{
		// A type constructor wraps its operand (`const(T)`, `immutable(T)`):
		// the crumb producer recurses into it, so the operand is what the type
		// is.
		DSymbol* inner;
		istring innerMissing;
		auto outcome = resolveDeclaredType(t2.type, symbol, lookup, moduleScope, cache, mapping,
			inner, innerMissing);
		if (outcome == TypeNodeOutcome.unmodelled)
			return TypeNodeOutcome.unmodelled;
		current = inner;
		missingName = innerMissing;
		// The operand's own resolution already applied `lookup.ctx` where it
		// belongs (a type constructor never carries template arguments of its
		// own -- `addTypeWithContext` only captures them for a `typeIdentifierPart`).
		return outcome;
	}

	istring name;
	if (t2.superOrThis is tok!"this")
		name = internString("this");
	else if (t2.superOrThis is tok!"super")
		name = internString("super");
	else if (t2.builtinType !is tok!"")
		name = getBuiltinTypeName(t2.builtinType);
	else if (t2.typeIdentifierPart !is null)
		return resolveTypeIdentifierChain(t2.typeIdentifierPart, symbol, lookup,
			moduleScope, cache, mapping, current, missingName);
	else if (t2.typeofExpression !is null)
		return resolveTypeofExpression(t2.typeofExpression, symbol, lookup,
			moduleScope, cache, mapping, current, missingName);
	else if (t2.traitsExpression !is null)
		return resolveTraitsExpression(t2.traitsExpression, symbol, lookup,
			moduleScope, cache, mapping, current, missingName);
	else
	{
		// `__vector` or a mixin type: the crumb walk does not model them
		// either.
		return TypeNodeOutcome.unmodelled;
	}

	if (name.length == 0)
		return TypeNodeOutcome.unmodelled;
	if (name.data in mapping)
		current = mapping[name.data];
	else
	{
		auto symbols = moduleScope.getSymbolsByNameAndCursor(name, symbol.location);
		if (symbols.length == 0)
		{
			missingName = name;
			return TypeNodeOutcome.unresolved;
		}
		current = symbols[0];
	}
	return current is null ? TypeNodeOutcome.unresolved : TypeNodeOutcome.resolved;
}

/// Resolves the identifier chain of a `TypeIdentifierPart` (`a.b.c`), the way
/// the crumb walk's name-chain loop does.
private TypeNodeOutcome resolveTypeIdentifierChain(const TypeIdentifierPart tip, DSymbol* symbol,
	TypeLookup* lookup, Scope* moduleScope, ref ModuleCache cache, DSymbol*[string] mapping,
	out DSymbol* current, out istring missingName)
{
	current = null;
	missingName = istring.init;
	size_t i = 0;
	for (auto part = cast(TypeIdentifierPart) tip; part !is null; part = part.typeIdentifierPart)
	{
		auto name = identifierName(part);
		if (name.length == 0)
			return TypeNodeOutcome.unmodelled;

		if (i == 0)
		{
			if (name.data in mapping)
				current = mapping[name.data];
			else
			{
				auto symbols = moduleScope.getSymbolsByNameAndCursor(name, symbol.location);
				if (symbols.length == 0)
				{
					missingName = name;
					return TypeNodeOutcome.unresolved;
				}
				current = symbols[0];
			}
		}
		else
		{
			if (current.kind == CompletionKind.aliasName)
				current = current.type;
			if (current is null)
				return TypeNodeOutcome.unresolved;
			if (current.kind == CompletionKind.moduleName && current.type !is null)
				current = current.type;
			if (current is null)
				return TypeNodeOutcome.unresolved;
			if (current.kind == CompletionKind.importSymbol)
				current = current.type;
			if (current is null)
				return TypeNodeOutcome.unresolved;
			current = current.getFirstPartNamed(name);
			if (current is null)
				return TypeNodeOutcome.unresolved;
		}

		// `TypeIdentifierPart.indexer` is a static array dimension (or a type
		// selected out of a type list).  The crumb producer inserts an array
		// crumb with the dimension here, so apply it the same way.
		if (part.indexer !is null)
		{
			current = wrapTypeSymbol(ARRAY_SYMBOL_NAME, SymbolQualifier.array, current,
				renderIndexerDimension(part.indexer), arraySymbols[]);
		}
		++i;
	}
	return current is null ? TypeNodeOutcome.unresolved : TypeNodeOutcome.resolved;
}

/// Resolves a declared `Type` node to the symbol it denotes, suffixes
/// included, without touching any symbol's `type`/`typeSymbolName` -- used by
/// the initializer walker for `cast(T)` and `new T(...)`, which say what the
/// expression is by naming a type.  `handled` is false for a shape the
/// declared-type walker does not model.
private DSymbol* resolveTypeNodeValue(const(Type) type, DSymbol* symbol, Scope* moduleScope,
	ref ModuleCache cache, DSymbol*[string] mapping, out bool handled,
	bool instantiateInstance = false)
{
	handled = false;
	if (type is null || type.type2 is null || moduleScope is null)
		return null;

	DSymbol* base;
	istring missingName;
	auto outcome = resolveDeclaredType(type, symbol, null, moduleScope, cache, mapping,
		base, missingName);
	if (outcome == TypeNodeOutcome.unmodelled)
		return null;
	handled = true;

	// `TD!int` written as an argument: same head instance the old capture
	// applied.
	DSymbol* current = base;
	auto ioti = headTemplateInstance(type);
	if (current !is null && ioti !is null && instantiateInstance)
		current = instantiateFromNode(current, ioti.templateInstance, ioti.tokens,
			symbol, moduleScope, cache, mapping);
	foreach (suffix; type.typeSuffixes)
	{
		if (current is null)
			break;
		current = wrapTypeSuffix(current, suffix, type);
	}
	return current;
}

/// The `[n]` of a `TypeIdentifierPart` indexer: the dimension of the array
/// symbol it builds.
private istring renderIndexerDimension(const(ExpressionNode) indexer)
{
	string dim;
	if (indexer.tokens.length > 0)
		foreach (t; indexer.tokens)
			dim ~= t.text;
	else
		dim = renderText(indexer);
	return dim.length > 0 ? internString(dim) : istring.init;
}

/**
 * Resolves a declared type (`varOrFunType` lookup) from the AST node its
 * producer recorded (`first.d`'s `addTypeWithContext` / `addTypeToLookups`).
 *
 * There is no crumb walk here anymore: `resolveTypeFromTypeNode` walks the
 * tree, and a shape it does not model (`typeof`, `__vector`, a trait, a mixin
 * type) leaves the symbol's type unset -- the crumb producer never modelled
 * those either, so the outcome is the same.  The `imports` parameter is kept
 * for `resolveDeferredTypes`, which shares this entry point; the deferred
 * retry runs with a null scope, which the node walker declines (see
 * `PLAN2.md` section 5), but no `varOrFunType` lookup is ever deferred.
 */
void resolveTypeFromType(DSymbol* symbol, TypeLookup* lookup, Scope* moduleScope,
	ref ModuleCache cache, Imports* imports, DSymbol*[string] mapping = null)
in
{
	if (imports !is null)
		foreach (i; imports.opSlice())
			assert(i.kind == CompletionKind.importSymbol);
}
do
{
	auto astType = lookup.astNode is null ? null : cast(const(Type)) lookup.astNode;
	if (astType is null)
		return;
	DSymbol* nodeResult;
	resolveTypeFromTypeNode(astType, symbol, lookup, moduleScope, cache, mapping, nodeResult);
}


/**
 * Resolves an initializer expression from its AST node.
 *
 * A name chain, prefix `&` / `*` / `!` / `-` / `+` / `~`, index expressions, a
 * call (worth what the callee returns), literals (as their built-in type
 * name), a ternary (its first non-`null` branch), `cast`/`new` (their type),
 * array initializers/literals (element then array) and the builtin operators
 * (see `evalBinary`; `1 << 0` is an `int`, `a == b` a `bool`).  Returns
 * false, leaving the symbol's type unset, for a shape it does not model (a
 * struct initializer, an operator over a user type, a function literal, an
 * unmodelled primary).
 */
private void resolveInitializerNode(const(BaseNode) expression, DSymbol* symbol,
	TypeLookup* lookup, Scope* moduleScope, ref ModuleCache cache, DSymbol*[string] mapping,
	out bool handled, out DSymbol* result)
{
	result = null;
	handled = false;
	if (expression is null)
		return;

	// Evaluate an expression (or an initializer wrapper) to the symbol it
	// stands for.  Returns false when the *shape* is not modelled.
	bool evalIoti(const(IdentifierOrTemplateInstance) ioti, out DSymbol* value)
	{
		value = null;
		auto name = identifierName(ioti);
		if (name.length == 0)
			return false;
		value = lookupInitializerBase(name, symbol, moduleScope, mapping);
		// `TD!int`: instantiate with the arguments written at the node.
		if (value !is null && ioti.templateInstance !is null)
			value = instantiateFromNode(value, ioti.templateInstance, ioti.tokens, symbol,
				moduleScope, cache, mapping);
		return true;
	}

	// The symbol of a builtin type name (`int`, `bool`, `string`), looked up
	// exactly the way a literal's type name is.
	DSymbol* builtinType(string name)
	{
		return name is null
			? null
			: lookupInitializerBase(internString(name), symbol, moduleScope, mapping);
	}

	bool evalNode(const(BaseNode) e, out DSymbol* value)
	{
		value = null;
		if (e is null)
			return false;

		// `x = <initializer>`: unwrap to the expression, array or struct
		// initializer it holds.
		if (auto init = cast(const(Initializer)) e)
		{
			if (init.nonVoidInitializer is null)
				return false;
			return evalNode(init.nonVoidInitializer, value);
		}
		if (auto nvi = cast(const(NonVoidInitializer)) e)
		{
			if (nvi.assignExpression !is null)
				return evalNode(nvi.assignExpression, value);
			if (nvi.arrayInitializer !is null)
				return evalNode(nvi.arrayInitializer, value);
			// A struct initializer: the crumb walk's default traversal mixed
			// its members' crumbs, which never resolved to anything useful.
			return false;
		}
		// `[a, b]`: the element type is the first member's.
		if (auto ai = cast(const(ArrayInitializer)) e)
		{
			DSymbol* element;
			if (ai.arrayMemberInitializations.length > 0)
			{
				auto member = ai.arrayMemberInitializations[0];
				if (member is null)
					return false;
				if (member.assignExpression !is null)
				{
					if (!evalNode(member.assignExpression, element))
						return false;
				}
				else if (member.nonVoidInitializer !is null)
				{
					if (!evalNode(member.nonVoidInitializer, element))
						return false;
				}
				else
					return false;
			}
			else
				// An empty array literal: the crumb walk recorded the `void`.
				element = lookupInitializerBase(internString("void"), symbol,
					moduleScope, mapping);
			value = arrayLiteralSymbol(element);
			return true;
		}
		// `(a, b)`: a comma expression is not a type.
		if (auto wrapper = cast(const(Expression)) e)
		{
			if (wrapper.items.length != 1)
				return false;
			return evalNode(wrapper.items[0], value);
		}
		// `cast(T) e`: the cast's *type* is what the expression stands for
		// (the crumb producer fed it through `addTypeToLookups`).
		if (auto castExpr = cast(const(CastExpression)) e)
		{
			if (castExpr.type is null)
				return false;
			bool ok;
			value = resolveTypeNodeValue(castExpr.type, symbol, moduleScope, cache, mapping, ok);
			return ok;
		}
		// `new T(...)`: a value of `T`.
		if (auto ne = cast(const(NewExpression)) e)
		{
			if (ne.type is null || ne.newAnonClassExpression !is null)
				return false;
			bool ok;
			value = resolveTypeNodeValue(ne.type, symbol, moduleScope, cache, mapping, ok);
			return ok;
		}
		// A comparison is wrapped: `CmpExpression` is what holds the one
		// (`<` -> `relExpression`, `==` -> `equalExpression`, ...), or the
		// plain expression when there is no comparison operator at all.
		if (auto cmp = cast(const(CmpExpression)) e)
		{
			if (cmp.shiftExpression !is null)
				return evalNode(cmp.shiftExpression, value);
			if (cmp.equalExpression !is null)
				return evalNode(cmp.equalExpression, value);
			if (cmp.identityExpression !is null)
				return evalNode(cmp.identityExpression, value);
			if (cmp.relExpression !is null)
				return evalNode(cmp.relExpression, value);
			if (cmp.inExpression !is null)
				return evalNode(cmp.inExpression, value);
			return false;
		}

		// The result of one binary operator over two operands.  `typeSwap(...,
		// false)` keeps an alias name, so a `string` operand stays a `string`
		// instead of becoming the array type.
		bool evalBinaryResult(BinaryKind kind, const(ExpressionNode) leftNode,
			const(ExpressionNode) rightNode, out DSymbol* result)
		{
			result = null;
			with (BinaryKind) final switch (kind)
			{
			case comparison:
			case logical:
				// `a == b` / `a && b`: a `bool`, whatever the operands are.
				result = builtinType("bool");
				return result !is null;
			case shift:
				// The promoted left operand: `byte << 1` is an `int`.
				DSymbol* operand;
				if (!evalNode(leftNode, operand))
					return false;
				typeSwap(operand, false);
				result = builtinType(promotedScalarName(operandTypeName(operand)));
				return result !is null;
			case concatenation:
				// `a ~ b` of two equal string types is that string type;
				// `string ~ char` and arrays are not modelled.
				DSymbol* leftString;
				DSymbol* rightString;
				if (!evalNode(leftNode, leftString) || !evalNode(rightNode, rightString))
					return false;
				typeSwap(leftString, false);
				typeSwap(rightString, false);
				auto name = operandTypeName(leftString);
				if (!isStringTypeName(name) || name != operandTypeName(rightString))
					return false;
				result = builtinType(name);
				return result !is null;
			case arithmetic:
				DSymbol* leftOperand;
				DSymbol* rightOperand;
				if (!evalNode(leftNode, leftOperand) || !evalNode(rightNode, rightOperand))
					return false;
				typeSwap(leftOperand, false);
				typeSwap(rightOperand, false);
				result = builtinType(commonScalarName(operandTypeName(leftOperand),
					operandTypeName(rightOperand)));
				return result !is null;
			}
		}

		// `a <op> b`: dparse has one class per operator (see the casts below),
		// and the class says what the result is.  Anything else -- an
		// overloaded `opBinary`, an enum member's base type -- stays
		// unmodelled and leaves the symbol untyped.
		bool evalBinary(const(BaseNode) node, out DSymbol* result)
		{
			result = null;
			if (auto binary = cast(const(AddExpression)) node)
				return evalBinaryResult(
					binary.operator == tok!"~" ? BinaryKind.concatenation
						: BinaryKind.arithmetic,
					binary.left, binary.right, result);
			if (auto binary = cast(const(MulExpression)) node)
				return evalBinaryResult(BinaryKind.arithmetic, binary.left, binary.right,
					result);
			if (auto binary = cast(const(ShiftExpression)) node)
				return evalBinaryResult(BinaryKind.shift, binary.left, binary.right, result);
			if (auto binary = cast(const(AndExpression)) node)
				return evalBinaryResult(BinaryKind.arithmetic, binary.left, binary.right,
					result);
			if (auto binary = cast(const(OrExpression)) node)
				return evalBinaryResult(BinaryKind.arithmetic, binary.left, binary.right,
					result);
			if (auto binary = cast(const(XorExpression)) node)
				return evalBinaryResult(BinaryKind.arithmetic, binary.left, binary.right,
					result);
			if (auto binary = cast(const(PowExpression)) node)
				return evalBinaryResult(BinaryKind.arithmetic, binary.left, binary.right,
					result);
			if (auto binary = cast(const(EqualExpression)) node)
				return evalBinaryResult(BinaryKind.comparison, binary.left, binary.right,
					result);
			if (auto binary = cast(const(RelExpression)) node)
				return evalBinaryResult(BinaryKind.comparison, binary.left, binary.right,
					result);
			if (auto binary = cast(const(IdentityExpression)) node)
				return evalBinaryResult(BinaryKind.comparison, binary.left, binary.right,
					result);
			if (auto binary = cast(const(AndAndExpression)) node)
				return evalBinaryResult(BinaryKind.logical, binary.left, binary.right, result);
			if (auto binary = cast(const(OrOrExpression)) node)
				return evalBinaryResult(BinaryKind.logical, binary.left, binary.right, result);
			return false;
		}

		if (evalBinary(e, value))
			return true;

		if (auto unary = cast(const(UnaryExpression)) e)
		{
			// `a.b` / `a.b!(int)`: a member of what is on the left.
			if (unary.identifierOrTemplateInstance !is null)
			{
				auto ioti = unary.identifierOrTemplateInstance;
				if (unary.unaryExpression is null)
				{
					// `TD` / `TD!int` with nothing to the left of it.
					if (!evalIoti(ioti, value))
						return false;
					return true;
				}
				DSymbol* left;
				if (!evalNode(unary.unaryExpression, left))
					return false;
				value = memberStep(left, identifierName(ioti), moduleScope);
				if (value !is null && ioti.templateInstance !is null)
					value = instantiateFromNode(value, ioti.templateInstance, ioti.tokens,
						symbol, moduleScope, cache, mapping);
				return true;
			}
			if (unary.primaryExpression !is null)
			{
				// `TD` / `TD!int` as a primary expression.
				if (unary.primaryExpression.identifierOrTemplateInstance !is null)
				{
					if (!evalIoti(unary.primaryExpression.identifierOrTemplateInstance, value))
						return false;
					return true;
				}
				// A parenthesised expression (`(1 << 0)`) or an array literal
				// needs the primary node's own walk, not just its literal.
				return evalNode(unary.primaryExpression, value);
			}
			// `foo(...)`: worth what the callee returns.
			if (unary.functionCallExpression !is null)
			{
				DSymbol* callee;
				if (!evalNode(unary.functionCallExpression.unaryExpression, callee))
					return false;
				value = callee;
				if (value !is null)
					typeSwap(value);
				return true;
			}
			// `a[i]`: one step down per index that is not a slice.
			if (unary.indexExpression !is null)
			{
				DSymbol* base;
				if (!evalNode(unary.indexExpression.unaryExpression, base))
					return false;
				value = applyInitializerIndexes(base, unary.indexExpression.indexes, moduleScope);
				return true;
			}
			// `cast(T) e`: the crumb producer encodes the cast's *type*
			// through `addTypeToLookups`, so the type is what the expression
			// stands for.
			if (unary.castExpression !is null)
				return evalNode(unary.castExpression, value);
			// `new T(...)`: a value of `T`.
			if (unary.newExpression !is null)
				return evalNode(unary.newExpression, value);
			// prefix `!` (a `bool`) and `-` / `+` / `~` (the promoted
			// operand type, through the builtin scalars only).
			if (unary.unaryExpression !is null
				&& (unary.prefix.type == tok!"!" || unary.prefix.type == tok!"-"
					|| unary.prefix.type == tok!"+" || unary.prefix.type == tok!"~"))
			{
				DSymbol* operand;
				if (!evalNode(unary.unaryExpression, operand))
					return false;
				if (unary.prefix.type == tok!"!")
					value = builtinType("bool");
				else
				{
					typeSwap(operand, false);
					value = builtinType(promotedScalarName(operandTypeName(operand)));
				}
				return value !is null;
			}
			// prefix `&` / `*`.
			if (unary.unaryExpression !is null)
			{
				DSymbol* base;
				if (!evalNode(unary.unaryExpression, base))
					return false;
				if (base !is null)
					typeSwap(base);
				if (base !is null)
				{
					if (unary.prefix.type == tok!"&")
						base = initializerPointerStep(base);
					else if (unary.prefix.type == tok!"*")
						base = initializerIndexStep(base, moduleScope);
					else
						return false;
				}
				value = base;
				return true;
			}
			return false;
		}

		if (auto index = cast(const(IndexExpression)) e)
		{
			DSymbol* base;
			if (!evalNode(index.unaryExpression, base))
				return false;
			value = applyInitializerIndexes(base, index.indexes, moduleScope);
			return true;
		}

		if (auto ternary = cast(const(TernaryExpression)) e)
		{
			// The first branch that is not a bare `null`.
			if (ternary.expression !is null && !isNullLiteral(ternary.expression))
				return evalNode(ternary.expression, value);
			if (ternary.ternaryExpression !is null)
				return evalNode(ternary.ternaryExpression, value);
			return false;
		}

		if (auto primary = cast(const(PrimaryExpression)) e)
		{
			// `[a, b]` in expression position (`f([1,2])`, `[1,2].length`).
			if (primary.arrayLiteral !is null)
			{
				auto al = primary.arrayLiteral;
				DSymbol* element;
				if (al.argumentList !is null && al.argumentList.items.length > 0)
				{
					if (!evalNode(al.argumentList.items[0], element))
						return false;
				}
				else
					element = lookupInitializerBase(internString("void"),
						symbol, moduleScope, mapping);
				value = arrayLiteralSymbol(element);
				return true;
			}
			// `(expr)`: the parser records the parenthesised expression (as
			// the one-item list the `Expression` node holds) in the primary.
			if (primary.expression !is null)
				return evalNode(primary.expression, value);
			return evalInitializerPrimary(primary, symbol, moduleScope, mapping, value);
		}

		return false;
	}

	handled = evalNode(expression, result);
}

/// Resolves a primary expression: an identifier / template instance, a builtin
/// type, or a literal (through its built-in type name).
private bool evalInitializerPrimary(const(PrimaryExpression) primary, DSymbol* symbol,
	Scope* moduleScope, DSymbol*[string] mapping, out DSymbol* result)
{
	result = null;
	if (primary is null)
		return false;

	// A literal value's type: looked up under the built-in type name.  The old
	// crumb alphabet needed a `*int` marker to tell `10.abc` from `int.abc`;
	// the node says which it is, so the name is used directly.
	istring name;
	if (primary.identifierOrTemplateInstance !is null)
		name = identifierName(primary.identifierOrTemplateInstance);
	else if (primary.basicType != tok!"")
		name = internString(str(primary.basicType.type));
	else
	{
		switch (primary.primary.type)
		{
		case tok!"identifier": name = internString(primary.primary.text); break;
		case tok!"doubleLiteral": name = internString("double"); break;
		case tok!"floatLiteral": name = internString("float"); break;
		case tok!"idoubleLiteral": name = internString("idouble"); break;
		case tok!"ifloatLiteral": name = internString("ifloat"); break;
		case tok!"intLiteral": name = internString("int"); break;
		case tok!"longLiteral": name = internString("long"); break;
		case tok!"realLiteral": name = internString("real"); break;
		case tok!"irealLiteral": name = internString("ireal"); break;
		case tok!"uintLiteral": name = internString("uint"); break;
		case tok!"ulongLiteral": name = internString("ulong"); break;
		case tok!"characterLiteral": name = internString("char"); break;
		case tok!"dstringLiteral": name = internString("dstring"); break;
		case tok!"stringLiteral": name = internString("string"); break;
		case tok!"wstringLiteral": name = internString("wstring"); break;
		case tok!"false":
		case tok!"true": name = internString("bool"); break;
		case tok!"null": name = internString("void"); break;
		default: return false;
		}
	}
	if (name is null || name.length == 0)
		return false;
	result = lookupInitializerBase(name, symbol, moduleScope, mapping);
	return true;
}

/// The base symbol of an initializer path: the mapping first, then the scope at
/// the declaration's cursor (exactly the crumb walk's first-crumb step).
private DSymbol* lookupInitializerBase(istring name, DSymbol* symbol, Scope* moduleScope,
	DSymbol*[string] mapping)
{
	if (name.length == 0)
		return null;
	if (name.data in mapping)
		return mapping[name.data];
	return moduleScope.getFirstSymbolByNameAndCursor(name, symbol.location);
}

/// One member step (`a.b`): the `typeSwap` / `type` fallback the crumb walk's
/// generic-crumb branch performs.
private DSymbol* memberStep(DSymbol* current, istring name, Scope* moduleScope)
{
	if (current is null || name.length == 0)
		return null;
	typeSwap(current);
	if (current is null)
		return null;
	auto type = current.type;
	auto found = current.getFirstPartNamed(name);
	// TODO: hack because of templates, perhaps we copy/assign the type to a part?
	if (found is null && type !is null)
		found = type.getFirstPartNamed(name);
	if (found !is null && found.type is null && found.typeSymbolName.length > 0)
	{
		auto resolved = moduleScope.getFirstSymbolByNameAndCursor(found.typeSymbolName,
			found.location);
		if (resolved !is null)
			found.type = resolved;
	}
	return found;
}

/// One index step (`a[i]`) -- the crumb walk's `ARRAY_SYMBOL_NAME` branch.
private DSymbol* initializerIndexStep(DSymbol* current, Scope* moduleScope)
{
	typeSwap(current);
	if (current is null)
		return null;
	// Index expressions can be on a pointer, an array or an AA.
	if (current.qualifier == SymbolQualifier.array
		|| current.qualifier == SymbolQualifier.assocArray
		|| current.qualifier == SymbolQualifier.pointer
		|| current.kind == CompletionKind.aliasName)
		return current.type;
	auto opIndex = current.getFirstPartNamed(internString("opIndex"));
	// The crumb walk keeps the symbol when there is no `opIndex` (`continue`).
	return opIndex !is null ? opIndex.type : current;
}

/// The symbol an array literal stands for -- the crumb walk's
/// `ARRAY_LITERAL_SYMBOL_NAME` branch: an array whose element type is the
/// child, with no property children (exactly what the crumb walk built).
private DSymbol* arrayLiteralSymbol(DSymbol* element)
{
	auto arr = GCAllocator.instance.make!DSymbol(ARRAY_LITERAL_SYMBOL_NAME,
		CompletionKind.dummy, element);
	arr.qualifier = SymbolQualifier.array;
	return arr;
}

/// The address-of step (`&x`) -- the crumb walk's `POINTER_SYMBOL_NAME` branch.
private DSymbol* initializerPointerStep(DSymbol* current)
{
	typeSwap(current);
	if (current is null)
		return null;
	auto ptr = GCAllocator.instance.make!DSymbol(POINTER_SYMBOL_NAME, CompletionKind.dummy, current);
	ptr.qualifier = SymbolQualifier.pointer;
	ptr.ownType = false;
	ptr.addChildren(pointerSymbols[], false);
	return ptr;
}

/// Applies the index steps of one `IndexExpression`, in source order.  A slice
/// (`a[i..j]`, `high !is null`) keeps the array.
private DSymbol* applyInitializerIndexes(DSymbol* base, const(Index)[] indexes,
	Scope* moduleScope)
{
	if (indexes is null)
		return base;
	foreach (index; indexes)
	{
		if (index is null || index.high !is null)
			continue;
		if (base is null)
			return null;
		base = initializerIndexStep(base, moduleScope);
	}
	return base;
}

/// The element type of a `foreach` aggregate -- the crumb walk's `foreach`
/// step: `.front` / `.opApply` / the element type of an array or AA.
private DSymbol* foreachElementStep(DSymbol* current)
{
	typeSwap(current);
	if (current is null)
		return null;
	if (current.qualifier == SymbolQualifier.array
		|| current.qualifier == SymbolQualifier.assocArray)
		return current.type;
	auto front = current.getFirstPartNamed(internString("front"));
	if (front !is null)
		return front.type;
	auto opApply = current.getFirstPartNamed(internString("opApply"));
	if (opApply !is null)
		return opApply.type;
	return current;
}

private bool isNullLiteral(const(ExpressionNode) n)
{
	if (auto pe = cast(const(PrimaryExpression)) n)
		return pe.primary.type == tok!"null";
	return false;
}

/// What a binary expression's type is made of -- see `evalBinary` in
/// `resolveInitializerNode`.
private enum BinaryKind : ubyte
{
	/// `==`, `!=`, `<`, `<=`, `>`, `>=`, `is`, `!is`: a `bool`.
	comparison,
	/// `&&`, `||`: a `bool`.
	logical,
	/// `<<`, `>>`, `>>>`: the promoted left operand.
	shift,
	/// `+`, `-`, `*`, `/`, `%`, `&`, `|`, `^`, `^^`: the common type.
	arithmetic,
	/// `~`: the string type of the two operands.
	concatenation,
}

/// A builtin scalar type: the name D writes it with, where the usual arithmetic
/// conversions rank it, and whether it is unsigned.
private struct ScalarType
{
	string name;
	int rank;
	bool isUnsigned;
}

/**
 * The builtin scalar types, in promotion order: everything ranking below
 * `int` promotes to `int`, and the floats sit above the integrals.
 */
private immutable ScalarType[] scalarTypes = [
	ScalarType("bool", 0, true),
	ScalarType("byte", 1, false),
	ScalarType("ubyte", 1, true),
	ScalarType("short", 2, false),
	ScalarType("ushort", 2, true),
	ScalarType("char", 2, true),
	ScalarType("wchar", 2, true),
	ScalarType("dchar", 2, true),
	ScalarType("int", 3, false),
	ScalarType("uint", 3, true),
	ScalarType("long", 4, false),
	ScalarType("ulong", 4, true),
	ScalarType("float", 5, false),
	ScalarType("double", 6, false),
	ScalarType("real", 7, false),
];

/// Looks a builtin scalar type up by name; false when `name` is not one.
private bool scalarTypeNamed(string name, out ScalarType type)
{
	foreach (candidate; scalarTypes)
		if (candidate.name == name)
		{
			type = candidate;
			return true;
		}
	return false;
}

/**
 * D's integral promotion of a builtin type name, or null when the name is not
 * a builtin scalar (`string`, a struct, an enum).
 */
private string promotedScalarName(string name)
{
	ScalarType type;
	if (!scalarTypeNamed(name, type))
		return null;
	// Everything narrower than `int` -- including `bool` and the character
	// types -- promotes to `int` before an operator sees it.
	return type.rank < 3 ? "int" : name;
}

/**
 * The common type of two builtin scalars, i.e. D's usual arithmetic
 * conversions: `1 + 2L` is a `long`, `1 + 1.0` a `double`, `1u + 1` a `uint`
 * and `true + true` an `int`.  Null when either name is not a builtin scalar.
 */
private string commonScalarName(string left, string right)
{
	auto promotedLeft = promotedScalarName(left);
	auto promotedRight = promotedScalarName(right);
	if (promotedLeft is null || promotedRight is null)
		return null;
	if (promotedLeft == promotedRight)
		return promotedLeft;
	ScalarType leftType;
	ScalarType rightType;
	scalarTypeNamed(promotedLeft, leftType);
	scalarTypeNamed(promotedRight, rightType);
	if (leftType.rank != rightType.rank)
		return leftType.rank > rightType.rank ? promotedLeft : promotedRight;
	// The same rank with a different sign: the unsigned one is the common type
	// (`1u + 1` is a `uint`).
	return leftType.isUnsigned ? promotedLeft : promotedRight;
}

/// Whether a type name is one of D's three string aliases.
private bool isStringTypeName(string name)
{
	return name == "string" || name == "wstring" || name == "dstring";
}

/// The type name an operand was written with (an alias stays an alias), or
/// null when the operand has no type.
private string operandTypeName(const(DSymbol)* operand)
{
	return operand is null ? null : operand.name.data;
}

void resolveTypeFromInitializer(DSymbol* symbol, TypeLookup* lookup,
	Scope* moduleScope, ref ModuleCache cache, DSymbol*[string] mapping = null)
{
	// Resolve from the AST node the producer recorded
	// (`populateInitializer`).  There is no crumb walk here anymore; a shape
	// the node walker does not model (a struct initializer, a binary
	// expression, a function literal) leaves the type unset, which is the
	// deliberate cost recorded in PLAN2.md.
	if (lookup.astNode is null || moduleScope is null)
		return;

	DSymbol* currentSymbol = null;
	bool handled;
	resolveInitializerNode(lookup.astNode, symbol, lookup, moduleScope, cache, mapping,
		handled, currentSymbol);
	if (!handled)
		return;
	if (lookup.kind == TypeLookupKind.foreachElement && currentSymbol !is null)
		currentSymbol = foreachElementStep(currentSymbol);
	if (currentSymbol is null)
		return;

	typeSwap(currentSymbol, false);
	symbol.type = currentSymbol;
	symbol.ownType = false;

	if (currentSymbol){
		//warning(">> type:   ", currentSymbol.name);
	}
}

void typeSwap(ref DSymbol* currentSymbol, bool followAlias = true)
{
	size_t iterations = 0;
	while (currentSymbol !is null && currentSymbol.type !is null && currentSymbol.type !is currentSymbol
		&& (currentSymbol.kind == CompletionKind.variableName
			|| currentSymbol.kind == CompletionKind.memberVariableName
			|| currentSymbol.kind == CompletionKind.importSymbol
			|| currentSymbol.kind == CompletionKind.withSymbol
			|| (followAlias && currentSymbol.kind == CompletionKind.aliasName)
			|| currentSymbol.kind == CompletionKind.functionName
			|| currentSymbol.kind == CompletionKind.ufcsName
			|| currentSymbol.kind == CompletionKind.enumMember
			)
		){

		currentSymbol = currentSymbol.type;
		if (++iterations > 500)
		{
			warning("Cycle detected in typeSwap for symbol: ", currentSymbol.name, " (", currentSymbol.kind, ")");
			break;
		}
	}
}

private:

void resolveInheritance(DSymbol* symbol, ref TypeLookups typeLookups,
	Scope* moduleScope, ref ModuleCache cache, DSymbol*[string] mapping = null)
{
	outer: foreach (TypeLookup* lookup; typeLookups[])
	{
		if (lookup.kind != TypeLookupKind.inherit)
			continue;
		// The base class name chain comes from the `BaseClass` node the
		// producer recorded (`writeIotcTo` used to spell it into crumbs).
		auto bc = cast(const(BaseClass)) lookup.astNode;
		if (bc is null || bc.type2 is null || bc.type2.typeIdentifierPart is null)
			continue;

		// TODO: Delayed type lookup
		auto symbolScope = moduleScope.getScopeByCursor(
			symbol.location + symbol.name.length);

		DSymbol* baseClass;
		bool first = true;
		for (TypeIdentifierPart part = cast() bc.type2.typeIdentifierPart; part !is null;
			part = part.typeIdentifierPart)
		{
			auto name = identifierName(part);
			if (name.length == 0)
				continue outer;
			if (first)
			{
				if (name.data in mapping)
					baseClass = mapping[name.data];
				else
				{
					auto symbols = moduleScope.getSymbolsByNameAndCursor(name,
						symbol.location);
					if (symbols.length == 0)
						continue outer;
					baseClass = symbols[0];
				}
				first = false;
			}
			else
			{
				auto symbols = baseClass.getPartsByName(name);
				if (symbols.length == 0)
					continue outer;
				baseClass = symbols[0];
			}

			// `class Derived(T) : Base!T` -- the arguments written at the
			// inheritance site, applied the same way a declared type applies
			// its head instance.  Without them the child would import the
			// generic `Base` and the base's members would keep the parameter.
			if (part.identifierOrTemplateInstance !is null
				&& part.identifierOrTemplateInstance.templateInstance !is null)
				baseClass = instantiateFromNode(baseClass,
					part.identifierOrTemplateInstance.templateInstance,
					part.identifierOrTemplateInstance.tokens, symbol, moduleScope, cache,
					mapping);
		}
		if (baseClass is null)
			continue;

		DSymbol* imp = GCAllocator.instance.make!DSymbol(IMPORT_SYMBOL_NAME,
			CompletionKind.importSymbol, baseClass);
		symbol.addChild(imp, true);
		symbolScope.addSymbol(imp, false);
		if (baseClass.kind == CompletionKind.className)
		{
			auto s = GCAllocator.instance.make!DSymbol(SUPER_SYMBOL_NAME,
				CompletionKind.variableName, baseClass);
			symbolScope.addSymbol(s, true);
		}
	}
}

void resolveAliasThis(DSymbol* symbol,
	ref TypeLookups typeLookups, Scope* moduleScope, ref ModuleCache cache, DSymbol*[string] mapping = null)
{
	foreach (aliasThis; typeLookups[].filter!(a => a.kind == TypeLookupKind.aliasThis))
	{
		auto dec = cast(const(AliasThisDeclaration)) aliasThis.astNode;
		if (dec is null || dec.identifier == tok!"")
			continue;
		auto parts = symbol.getPartsByName(internString(dec.identifier.text));
		if (parts.length == 0 || parts[0].type is null)
			continue;

		DSymbol* s = GCAllocator.instance.make!DSymbol(IMPORT_SYMBOL_NAME,
			CompletionKind.importSymbol, parts[0].type);
		symbol.addChild(s, true);
		auto symbolScope = moduleScope.getScopeByCursor(s.location);
		if (symbolScope !is null)
			symbolScope.addSymbol(s, false);
	}
}

void resolveMixinTemplates(DSymbol* symbol,
	ref TypeLookups typeLookups, Scope* moduleScope, ref ModuleCache cache, DSymbol*[string] mapping = null)
{
	foreach (mix; typeLookups[].filter!(a => a.kind == TypeLookupKind.mixinTemplate))
	{
		// The mixin template's name chain comes from the node the producer
		// recorded (`writeIotcTo` used to spell it into crumbs).
		auto chain = cast(const(IdentifierOrTemplateChain)) mix.astNode;
		if (chain is null || chain.identifiersOrTemplateInstances.length == 0)
			continue;

		DSymbol* currentSymbol;
		bool first = true;
		foreach (ioti; chain.identifiersOrTemplateInstances)
		{
			auto name = identifierName(ioti);
			if (name.length == 0)
			{
				currentSymbol = null;
				break;
			}
			if (first)
			{
				if (name.data in mapping)
					currentSymbol = mapping[name.data];
				else
				{
					auto symbols = moduleScope.getSymbolsByNameAndCursor(name,
						symbol.location);
					if (symbols.length == 0)
					{
						currentSymbol = null;
						break;
					}
					currentSymbol = symbols[0];
				}
				first = false;
			}
			else
			{
				auto s = currentSymbol.getPartsByName(name);
				if (s.length == 0)
				{
					currentSymbol = null;
					break;
				}
				currentSymbol = s[0];
			}

			// `mixin Extra!T;` -- the mixin template's own arguments, so the
			// symbols it contributes follow this declaration's parameters.
			if (currentSymbol !is null && ioti.templateInstance !is null)
				currentSymbol = instantiateFromNode(currentSymbol, ioti.templateInstance,
					ioti.tokens, symbol, moduleScope, cache, mapping);
		}
		if (currentSymbol !is null)
		{
			auto i = GCAllocator.instance.make!DSymbol(IMPORT_SYMBOL_NAME,
				CompletionKind.importSymbol, currentSymbol);
			i.ownType = false;
			symbol.addChild(i, true);
		}
	}
}

void resolveType(DSymbol* symbol, ref TypeLookups typeLookups,
	Scope* moduleScope, ref ModuleCache cache, DSymbol*[string] mapping = null)
{
	// going through the lookups
	foreach(lookup; typeLookups) {
		if (lookup.kind == TypeLookupKind.varOrFunType)
			resolveTypeFromType(symbol, lookup, moduleScope, cache, null, mapping);
		else if (lookup.kind == TypeLookupKind.initializer
			|| lookup.kind == TypeLookupKind.foreachElement)
			resolveTypeFromInitializer(symbol, lookup, moduleScope, cache, mapping);
		// issue 94
		else if (lookup.kind == TypeLookupKind.inherit)
			resolveInheritance(symbol, typeLookups, moduleScope, cache, mapping);
		else
		{
			// A lookup kind with nothing to do here (a selective import is
			// resolved by `resolveImport`, an `alias this` by
			// `resolveAliasThis`).  It used to be an assertion, which turned
			// any such symbol into a dead language server - the log line is
			// the useful half of that.
			warning("unhandled lookup kind ", lookup.kind, " on symbol ",
				symbol.name, " (kind ", symbol.kind, ", ", symbol.symbolFile, ")");
			continue;
		}
		}
}


/**
 * Builds the suffix symbol for one `TypeSuffix`, the way the crumb walk
 * builds it (`resolveTypeFromType`'s suffix branch): same marker, same
 * qualifier, same children, same call tip.  `wholeType` is the sum of the
 * current type and its suffixes -- it is the spelling a `delegate`/`function`
 * suffix renders as its call tip.
 */
private DSymbol* wrapTypeSuffix(DSymbol* inner, const(TypeSuffix) suffix, const(Type) wholeType)
{
	if (suffix.type !is null)
		return wrapTypeSymbol(ASSOC_ARRAY_SYMBOL_NAME, SymbolQualifier.assocArray, inner,
			renderSuffixKey(suffix.type), assocArraySymbols[]);
	if (suffix.array)
		return wrapTypeSymbol(ARRAY_SYMBOL_NAME, SymbolQualifier.array, inner,
			renderArrayDimension(suffix), arraySymbols[]);
	if (suffix.star != tok!"")
		return wrapTypeSymbol(POINTER_SYMBOL_NAME, SymbolQualifier.pointer, inner,
			istring.init, pointerSymbols[]);
	if (suffix.delegateOrFunction != tok!"")
	{
		auto next = GCAllocator.instance.make!DSymbol(FUNCTION_SYMBOL_NAME,
			CompletionKind.dummy, inner);
		next.qualifier = SymbolQualifier.func;
		next.ownType = false;
		next.callTip = renderNode(wholeType);
		return next;
	}
	// An unmodelled suffix (`[Type]` selected out of a template argument list,
	// ...): keep the base type rather than inventing one.
	return inner;
}

/// The `[K]` of an associative array suffix, spelled the way `addTypeToLookups`
/// spells it (token text when the key has tokens, the formatter otherwise).
private istring renderSuffixKey(const(Type) key)
{
	string text;
	if (key.tokens.length > 0)
		foreach (t; key.tokens)
			text ~= t.text;
	else
		text = renderText(key);
	return text.length > 0 ? internString(text) : istring.init;
}

/// The `[n]` of a static array suffix, or an empty string for `[]`.
private istring renderArrayDimension(const(TypeSuffix) suffix)
{
	string dim;
	if (suffix.tokens.length > 2)
	{
		foreach (t; suffix.tokens[1 .. $ - 1])
			dim ~= t.text;
	}
	else if (suffix.low !is null)
		dim = renderText(suffix.low);
	return dim.length > 0 ? internString(dim) : istring.init;
}

/// Renders a node back to source-ish text, for call tips and dimensions.
private string renderText(T)(const T node)
{
	if (node is null)
		return "";
	import std.array : appender;
	import dparse.formatter : Formatter;
	auto app = appender!string();
	scope formatter = new Formatter!(typeof(&app))(&app);
	formatter.format(node);
	return app.data;
}

private istring renderNode(T)(const T node)
{
	auto text = renderText(node);
	return text.length > 0 ? internString(text) : istring.init;
}

/// The template instance written at the *head* of a declared type
/// (`TD!int` in `TD!int x`), or null -- the one the old capture recorded (a
/// type constructor's operand, and a chain's later parts, were not captured).
private const(IdentifierOrTemplateInstance) headTemplateInstance(const(Type) type)
{
	if (type is null || type.type2 is null || type.type2.type !is null)
		return null;
	auto tip = type.type2.typeIdentifierPart;
	if (tip is null || tip.identifierOrTemplateInstance is null)
		return null;
	if (tip.identifierOrTemplateInstance.templateInstance is null)
		return null;
	return tip.identifierOrTemplateInstance;
}

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
private DSymbol* instantiateFromNode(DSymbol* base, const(TemplateInstance) instance,
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

private DSymbol* instantiateSymbol(DSymbol* s, Scope* moduleScope, ref ModuleCache cache,
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
		next.callTip = s.callTip;
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
private bool hasTemplateParameters(const DSymbol* symbol)
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
private DSymbol* instantiateAggregate(DSymbol* s, DSymbol*[] args, istring[] argNames,
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
	instantiated.callTip = s.callTip;
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
			newPart.callTip = part.callTip;
			newPart.flags = part.flags;
			// The call tip is display text built while parsing, from the
			// *generic* declaration (`V get(K key)`); now that this copy's
			// return type is concrete, its leading type has to follow.
			if (part.kind == CompletionKind.functionName)
				newPart.callTip = substituteCallTipReturnType(part.callTip, part.type, newPartType);
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
// `public` on purpose: this file's helpers are behind a `private:` label, and
// the completion path (dcd.server.autocomplete.util) has to call this one.
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
 * Replaces the return type at the head of a call tip.
 *
 * `formatCallTip` renders a call tip from the *generic* declaration
 * (`V get(K key)`), so a completion description built from it would keep
 * advertising the parameter of an instance whose return type is concrete.
 * Only the leading type is replaced, and only when the call tip really starts
 * with the old type's rendering; the parameter list is left as written.
 */
private istring substituteCallTipReturnType(istring callTip, const DSymbol* oldType,
	const DSymbol* newType)
{
	if (callTip.length == 0 || oldType is null || newType is null)
		return callTip;
	auto written = oldType.formatType();
	auto replacement = newType.formatType();
	if (written.length == 0 || replacement.length == 0 || written == replacement)
		return callTip;
	auto text = callTip.data;
	if (text.length <= written.length || text[written.length] != ' '
		|| text[0 .. written.length] != written)
		return callTip;
	return istring(replacement ~ text[written.length .. $]);
}
