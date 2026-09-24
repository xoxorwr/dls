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
import dsymbol.signature;
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

void secondPass(SemanticSymbol* rootModule, SemanticSymbol* currentSymbol, Scope* moduleScope, ref ModuleCache cache)
{
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
				acSymbol.symbolFile = acSymbol.altFile().path;
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
	if (dimension.length > 0)
		next.setRenderedText(GCAllocator.instance.make!RenderedText(dimension));
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
/// Which type-constructor keywords (`const`/`immutable`/`shared`/`inout`)
/// appear anywhere in a `Type`'s constructor chain: `Type.typeConstructors`
/// for the bare `const T` form, `Type2.typeConstructor` for the parenthesized
/// `const(T)` form, at every nesting level reached through `Type2.type`
/// (`const(shared(T))`).
private struct TypeConstructorFlags
{
	bool isConst, isImmutable, isShared, isInout;
}

private void applyTypeConstructor(ref TypeConstructorFlags flags, IdType tc)
{
	if (tc == tok!"const")
		flags.isConst = true;
	else if (tc == tok!"immutable")
		flags.isImmutable = true;
	else if (tc == tok!"shared")
		flags.isShared = true;
	else if (tc == tok!"inout")
		flags.isInout = true;
}

private void collectTypeConstructors(const(Type) type, ref TypeConstructorFlags result)
{
	if (type is null)
		return;
	foreach (tc; type.typeConstructors)
		applyTypeConstructor(result, tc);
	if (type.type2 !is null && type.type2.typeConstructor != tok!"")
		applyTypeConstructor(result, type.type2.typeConstructor);
	if (type.type2 !is null)
		collectTypeConstructors(type.type2.type, result);
}

private TypeConstructorFlags collectTypeConstructors(const(Type) type)
{
	TypeConstructorFlags result;
	collectTypeConstructors(type, result);
	return result;
}

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

		// Explicit assignment, not accumulation: a symbol retried through the
		// deferred path (`resolveDeferredTypes`/`checkMissingTypes`) must not
		// keep a stale `true` from an earlier partial resolution.
		auto qualifiers = collectTypeConstructors(type);
		// `P orig;` where `alias P = const(Data*);`: the written `Type` is
		// just the identifier `P`, with no `const(...)` token of its own for
		// `collectTypeConstructors` to find -- but for a single, unqualified
		// name (`resolveTypeIdentifierChain`'s `i == 0` branch), `base` is
		// `P`'s own alias symbol, not yet dereferenced to its target, so
		// `P`'s own `declaredTypeIs*` (set when *its* declaration was
		// resolved the same way) is read directly here. A `p.q` chain
		// (`i > 0` there) already dereferences through an alias before
		// reaching the final part, so this only ever fires for a bare name
		// -- exactly the shape that needs it.
		//
		// Restricted to a *same-file* alias, mirroring the exact condition
		// `dll.d`/`util.d`'s hover/completion rendering already uses to
		// decide whether to dereference an alias to its target at all
		// (`type.symbolFile == symbol.symbolFile`). Hover shows the target
		// (`Data*`) only for a same-file alias like `P`, so wrapping it in
		// the alias's own qualifier is meaningful there. A cross-file alias
		// like the builtin `string` (`immutable(char)[]`, from `object.d`)
		// keeps showing its own bare name, never dereferenced -- and that
		// name already *is* the qualified type by convention, so wrapping it
		// too would double up (`immutable(string)`, not `string`).
		if (!qualifiers.isConst && !qualifiers.isImmutable && !qualifiers.isShared
			&& !qualifiers.isInout && base !is null && base.kind == CompletionKind.aliasName
			&& base.symbolFile.length > 0 && base.symbolFile == symbol.symbolFile)
		{
			qualifiers = TypeConstructorFlags(base.flags.declaredTypeIsConst,
				base.flags.declaredTypeIsImmutable, base.flags.declaredTypeIsShared,
				base.flags.declaredTypeIsInout);
		}
		symbol.flags.declaredTypeIsConst = qualifiers.isConst;
		symbol.flags.declaredTypeIsImmutable = qualifiers.isImmutable;
		symbol.flags.declaredTypeIsShared = qualifiers.isShared;
		symbol.flags.declaredTypeIsInout = qualifiers.isInout;
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
		auto next = wrapTypeSuffix(current, suffix);
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
	TypeConstructorFlags unusedQualifiers;
	resolveInitializerNode(te.expression, symbol, lookup, moduleScope, cache, mapping,
		handled, value, unusedQualifiers);
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
		TypeConstructorFlags unusedQualifiers;
		resolveInitializerNode(arg0.assignExpression, symbol, lookup, moduleScope, cache,
			mapping, handled, base, unusedQualifiers);
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
		// `resolveDeclaredType` only ever resolves a base name -- suffixes
		// are the caller's job (`resolveTypeFromTypeNode` applies the outer
		// type's own suffixes once this returns). But the operand written
		// inside the parens is a full `Type` and may carry suffixes of its
		// own (`const(T**)`, `immutable(T[])`): `t2.type.typeSuffixes`,
		// never looked at otherwise, so `**`/`[]` inside a type constructor
		// was silently dropped along with the qualifier itself, not just the
		// qualifier -- `const(T**)` resolved as bare `T`, not `T**`.
		if (outcome == TypeNodeOutcome.resolved)
			foreach (suffix; t2.type.typeSuffixes)
				inner = wrapTypeSuffix(inner, suffix);
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
		current = wrapTypeSuffix(current, suffix);
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
	out bool handled, out DSymbol* result, out TypeConstructorFlags qualifiers)
{
	result = null;
	handled = false;
	qualifiers = TypeConstructorFlags.init;
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
			// Only the operands its kind actually reads are evaluated: a
			// comparison is a `bool` whatever it compares.
			DSymbol* leftOperand = null;
			DSymbol* rightOperand = null;
			final switch (kind)
			{
			case BinaryKind.comparison:
			case BinaryKind.logical:
				break;
			case BinaryKind.shift:
				if (!evalNode(leftNode, leftOperand))
					return false;
				typeSwap(leftOperand, false);
				break;
			case BinaryKind.concatenation:
			case BinaryKind.arithmetic:
				if (!evalNode(leftNode, leftOperand) || !evalNode(rightNode, rightOperand))
					return false;
				typeSwap(leftOperand, false);
				typeSwap(rightOperand, false);
				break;
			}
			auto name = binaryResultTypeName(kind, leftOperand, rightOperand);
			if (name is null)
				return false;
			result = builtinType(name);
			return result !is null;
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

		// Positional IFTI: for each of `callee`'s parameters whose declared
		// type resolves, once any array/pointer/assoc-array wrapping is
		// peeled off both sides in lockstep, to one of the callee's own
		// `typeTmpParam` children (`T data` inside `T get(T)(T data)`, or
		// `T[] arr` inside `T first(T)(T[] arr)`), the type the argument
		// written at that position has under the same wrapping is what the
		// parameter stands for. A parameter built out of a template
		// parameter some other way (`const(T)`) is left unresolved, same as
		// an argument whose own type could not be evaluated, or one wrapped
		// differently than the parameter (`first(3)` against `T[]`).
		DSymbol*[string] deduceTemplateArguments(DSymbol* callee, const Arguments arguments)
		{
			DSymbol*[string] deduced;
			if (callee is null || arguments is null || arguments.namedArgumentList is null)
				return deduced;
			auto args = arguments.namedArgumentList.items;
			auto params = callee.functionParameters;
			foreach (i, param; params)
			{
				if (param is null || param.type is null)
					continue;
				if (i >= args.length || args[i] is null || args[i].assignExpression is null)
					continue;
				DSymbol* argType;
				if (!evalNode(args[i].assignExpression, argType) || argType is null)
					continue;
				// `false`: keep an alias (`string`) as itself, the same way
				// `evalBinaryResult` does -- otherwise `wrap("hi")` would
				// deduce `T` as `char[]`, `string`'s aliased-to type, not
				// `string` itself.
				typeSwap(argType, false);

				DSymbol* paramType = param.type;
				while (paramType !is null && argType !is null
					&& paramType.kind == CompletionKind.dummy)
				{
					// An array literal (`[1, 2, 3]`) is marked
					// `ARRAY_LITERAL_SYMBOL_NAME`, not the `ARRAY_SYMBOL_NAME`
					// a declared `T[]` parameter wraps with -- same shape,
					// different marker, so `T[] arr` deduces against a
					// literal argument too, not only a variable already of
					// array type.
					bool matches = paramType.name == ARRAY_SYMBOL_NAME
						? (argType.name == ARRAY_SYMBOL_NAME
							|| argType.name == ARRAY_LITERAL_SYMBOL_NAME)
						: paramType.name == argType.name
							&& (paramType.name == POINTER_SYMBOL_NAME
								|| paramType.name == ASSOC_ARRAY_SYMBOL_NAME);
					if (!matches)
						break;
					paramType = paramType.type;
					argType = argType.type;
				}
				if (paramType is null || argType is null
					|| paramType.kind != CompletionKind.typeTmpParam)
					continue;
				if (paramType.name in deduced)
					continue;
				deduced[paramType.name] = argType;
			}
			return deduced;
		}

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
				{
					// The callee's own declared-return-type qualifier
					// (`const(T**) get(T)()`) -- snapshotted into a local
					// here, before `typeSwap` below collapses `value` from
					// the function symbol to its return type and the
					// association is lost.  Kept in a local, not written to
					// the shared `qualifiers` yet: an argument that is
					// itself a call (`get(Data())`) recurses back into this
					// same branch through `deduceTemplateArguments`'s own
					// type evaluation below, and would otherwise clobber
					// this call's qualifier with its argument's (`Data`'s,
					// always none) on the way back out.
					auto calleeQualifiers = TypeConstructorFlags(callee.flags.declaredTypeIsConst,
						callee.flags.declaredTypeIsImmutable, callee.flags.declaredTypeIsShared,
						callee.flags.declaredTypeIsInout);
					// IFTI (`get(Data())` calling `T get(T)(T data)`, no
					// explicit `!(...)`): deduce what each of the callee's
					// type parameters stands for from the arguments actually
					// written, positionally, before resolving what it
					// returns -- otherwise the return type is left as the
					// parameter symbol itself (`T`), not the argument's type
					// (`Data`).
					auto deduced = deduceTemplateArguments(callee,
						unary.functionCallExpression.arguments);
					typeSwap(value);
					if (deduced.length > 0)
						value = instantiateSymbol(value, moduleScope, cache, deduced);
					// Applied last, after argument evaluation above had its
					// chance to (wrongly) overwrite the shared `qualifiers`:
					// this call's own callee is what should win for this
					// call's result. An outer call around this one still
					// overwrites it again on the way further back up the
					// recursion, which is correct -- the outermost call's
					// callee is the expression's actual final type.
					qualifiers = calleeQualifiers;
				}
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
/// `resolveInitializerNode` and `binaryResultTypeName` below.
public enum BinaryKind : ubyte
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
public string promotedScalarName(string name)
{
	ScalarType type;
	if (!scalarTypeNamed(name, type))
		return null;
	// Everything narrower than `int` -- including `bool` and the character
	// types -- promotes to `int` before an operator sees it.
	return type.rank < 3 ? "int" : name;
}

/**
 * The type name two operands of one binary operator produce -- the single
 * place D's promotion rules for `+`, `<<`, `==` and `~` are written.
 *
 * Both callers come here so that they cannot drift apart: the initializer
 * walk, whose operands are AST nodes, and the completion path that folds the
 * values written at a call site (`wrap(2 + 3)`), whose operands come off the
 * token chain.
 *
 * Only the left operand is read for a shift (`byte << 1` is an `int`).  Null
 * means the shape is not modelled: an operator over a user type, or a `~` of
 * two different string types.
 */
public string binaryResultTypeName(BinaryKind kind, const(DSymbol)* left, const(DSymbol)* right)
{
	final switch (kind)
	{
	case BinaryKind.comparison:
	case BinaryKind.logical:
		// `a == b` / `a && b`: a `bool`, whatever the operands are.
		return "bool";
	case BinaryKind.shift:
		return promotedScalarName(operandTypeName(left));
	case BinaryKind.concatenation:
		// `a ~ b` of two equal string types is that string type; `string ~
		// char` and arrays are not modelled.
		auto name = operandTypeName(left);
		if (!isStringTypeName(name) || name != operandTypeName(right))
			return null;
		return name;
	case BinaryKind.arithmetic:
		return commonScalarName(operandTypeName(left), operandTypeName(right));
	}
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
	TypeConstructorFlags qualifiers;
	resolveInitializerNode(lookup.astNode, symbol, lookup, moduleScope, cache, mapping,
		handled, currentSymbol, qualifiers);
	if (!handled)
		return;
	bool isForeachElement = lookup.kind == TypeLookupKind.foreachElement;
	if (isForeachElement && currentSymbol !is null)
		currentSymbol = foreachElementStep(currentSymbol);
	if (currentSymbol is null)
		return;

	// Neither fallback below applies to an alias reference (`auto x = str;`
	// where `str`'s type is the `string` alias): an alias's own name is
	// already a complete, self-contained type name that may itself encode a
	// qualifier (`string` is `immutable(char)[]`) -- wrapping it in another
	// `immutable(...)` would double up, turning `string x` into the wrong,
	// redundant `immutable(string) x`. `typeSwap(..., false)` (used both here
	// and by IFTI deduction) deliberately keeps an alias as its name instead
	// of unwrapping to the target for exactly this reason; these fallbacks
	// must respect that same boundary.
	bool canFallBackToCurrentSymbol = !isForeachElement
		&& currentSymbol.kind != CompletionKind.aliasName;

	// `auto x = getDoublePtr!(Data);` (an instantiated template referenced,
	// not called -- no `functionCallExpression` node, so the capture inside
	// `resolveInitializerNode`'s call branch never ran): `currentSymbol` here
	// is still the function/variable symbol itself, not yet collapsed by the
	// `typeSwap` below, so its own `declaredTypeIs*` flags (set when *its*
	// declared type was resolved) are read directly as a fallback.
	if (canFallBackToCurrentSymbol && !qualifiers.isConst && !qualifiers.isImmutable
		&& !qualifiers.isShared && !qualifiers.isInout)
	{
		qualifiers = TypeConstructorFlags(currentSymbol.flags.declaredTypeIsConst,
			currentSymbol.flags.declaredTypeIsImmutable, currentSymbol.flags.declaredTypeIsShared,
			currentSymbol.flags.declaredTypeIsInout);
	}

	// `void f(const int a) { auto c = a; }`: D's `const`/`immutable`/`shared`
	// are transitive -- a bare-const *parameter*'s own type already is
	// `const(int)`, not `int` with a separate attribute, so copying it into
	// an `auto` local should carry the qualifier too. `parameterIsConst`
	// etc. are a different flag family (the bare-attribute AST shape, not a
	// type constructor -- see `symbol.d`'s comment on them), so they are not
	// covered by the `declaredTypeIs*` read above; read as a second fallback,
	// only once that one found nothing. `parameterIsInout` is deliberately
	// not included: `inout` on a parameter is a per-call wildcard, not a
	// concrete qualifier there is anything meaningful to copy.
	if (canFallBackToCurrentSymbol && !qualifiers.isConst && !qualifiers.isImmutable
		&& !qualifiers.isShared && !qualifiers.isInout)
	{
		qualifiers = TypeConstructorFlags(currentSymbol.flags.parameterIsConst,
			currentSymbol.flags.parameterIsImmutable, currentSymbol.flags.parameterIsShared, false);
	}

	typeSwap(currentSymbol, false);
	symbol.type = currentSymbol;
	symbol.ownType = false;

	// `auto f = get!(Data);` from `const(T**) get(T)();`: the callee's own
	// declared-return-type qualifier, captured by `resolveInitializerNode`
	// before its internal `typeSwap` lost the association -- everything else
	// that reaches here (a plain literal, a member access, an operator
	// result) leaves `qualifiers` at its `.init` (all false), which is
	// correct: there is no declared-type qualifier to attribute in those
	// cases.  Not applied for a `foreach` element: the qualifier belonged to
	// the range expression's own type, not to each element's.
	if (!isForeachElement)
	{
		symbol.flags.declaredTypeIsConst = qualifiers.isConst;
		symbol.flags.declaredTypeIsImmutable = qualifiers.isImmutable;
		symbol.flags.declaredTypeIsShared = qualifiers.isShared;
		symbol.flags.declaredTypeIsInout = qualifiers.isInout;
	}

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
 * qualifier, same children, same signature.
 */
private DSymbol* wrapTypeSuffix(DSymbol* inner, const(TypeSuffix) suffix)
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
		next.setSignature(makeFunctionTypeSignature(inner, suffix));
		return next;
	}
	// An unmodelled suffix (`[Type]` selected out of a template argument list,
	// ...): keep the base type rather than inventing one.
	return inner;
}

/**
 * Builds the signature of a `T function(Args)` / `T delegate(Args)` type.
 *
 * `inner` is the symbol the type's preceding pieces built, so its rendering
 * *is* the return type; the suffix supplies the `function`/`delegate` keyword
 * and the value parameter list.  This used to be the whole type re-rendered
 * from the AST into one string (`renderNode(wholeType)`) which signature help
 * then split apart again to find the parameters of a call through a function
 * pointer.
 */
private Signature* makeFunctionTypeSignature(DSymbol* inner, const(TypeSuffix) suffix)
{
	auto signature = GCAllocator.instance.make!Signature();
	signature.shape = SignatureShape.functionType;
	signature.functionKind = internString(suffix.delegateOrFunction.text.length > 0
		? suffix.delegateOrFunction.text : str(suffix.delegateOrFunction.type));
	if (inner !is null)
	{
		auto text = inner.formatType();
		if (text.length > 0)
			signature.returnType = internString(text);
	}
	if (suffix.parameters !is null)
	{
		foreach (const Parameter p; suffix.parameters.parameters)
			signature.parameters ~= renderNode(p);
		if (suffix.parameters.hasVarargs)
			signature.parameters ~= internString("...");
	}
	return signature;
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
// `public` on purpose: this file's helpers are behind a `private:` label, and
// the completion path asks this before binding a call's arguments.
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
private Signature* substituteSignatureReturnType(const Signature* signature,
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
