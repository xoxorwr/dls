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
 * Declared-type AST walking: given a `Type` AST node (a `varOrFunType`
 * lookup's declared type, a `typeof(...)`, a `__traits(getMember, ...)`, a
 * `cast(T)`/`new T` operand), what `DSymbol` it denotes.
 */
module dsymbol.conversion.second.declared_type;

import dsymbol.conversion.second.initializer : memberStep, resolveInitializerNode, typeSwap;
import dsymbol.conversion.second.instantiate : instantiateFromNode;
import dsymbol.deferred : Imports;
import dsymbol.semantic : TypeLookups;
import dsymbol.symbol;
import dsymbol.scope_;
import dsymbol.signature;
import dsymbol.string_interning;
import dsymbol.builtin.names;
import dsymbol.builtin.symbols;
import dsymbol.type_lookup;
import dsymbol.modulecache;
import std.experimental.allocator;
import std.experimental.allocator.gc_allocator : GCAllocator;
import dparse.ast;
import dparse.lexer;

/// The identifier of one `TypeIdentifierPart` (a template instance's
/// identifier for `Foo!(int)`), or an empty string when there is none.
package istring identifierName(const TypeIdentifierPart tip)
{
	if (tip is null)
		return istring.init;
	return identifierName(tip.identifierOrTemplateInstance);
}

/// The name of `foo` / `foo!(int)`, or an empty string when there is none.
package istring identifierName(const(IdentifierOrTemplateInstance) ioti)
{
	if (ioti is null)
		return istring.init;
	if (ioti.identifier != tok!"")
		return internString(ioti.identifier.text);
	if (ioti.templateInstance !is null && ioti.templateInstance.identifier != tok!"")
		return internString(ioti.templateInstance.identifier.text);
	return istring.init;
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

/// Which type-constructor keywords (`const`/`immutable`/`shared`/`inout`)
/// appear anywhere in a `Type`'s constructor chain: `Type.typeConstructors`
/// for the bare `const T` form, `Type2.typeConstructor` for the parenthesized
/// `const(T)` form, at every nesting level reached through `Type2.type`
/// (`const(shared(T))`).
package struct TypeConstructorFlags
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
/// The recorded text is the initializer as written, quotes included, so it
/// has to be unquoted the same way a literal argument is.
private bool resolveConstantName(istring name, DSymbol* symbol, Scope* moduleScope,
	out istring memberName)
{
	memberName = istring.init;
	auto target = moduleScope.getFirstSymbolByNameAndCursor(name, symbol.location);
	if (target is null)
		return false;
	if (target.constantValue.length > 0)
		return unquoteTraitLiteral(target.constantValue, memberName);
	if (target.kind == CompletionKind.aliasName && target.type !is null
		&& target.type.constantValue.length > 0)
		return unquoteTraitLiteral(target.type.constantValue, memberName);
	return false;
}

/// Whether an alias still points at an operand that was unresolved when it
/// ran: null-typed variables, functions, enum members and aliases down the
/// chain (`alias T = typeof(x)` forwarding to `x` before `x` resolved).
/// Healthy aliases (`alias A = int`, `alias M = <resolved member>`) answer no.
package bool aliasNeedsRetry(DSymbol* symbol)
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
package DSymbol* resolveTypeNodeValue(const(Type) type, DSymbol* symbol, Scope* moduleScope,
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
			dim ~= t.text is null ? str(t.type) : t.text;
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
public void resolveTypeFromType(DSymbol* symbol, TypeLookup* lookup, Scope* moduleScope,
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
 * Whether a declared `Type` needs its static-array shape finished from the
 * initializer: an `auto` element type with array dims (`auto[$]`, `auto[3]`
 * -- the parser records `auto` as a TypeIdentifier, the way dmd spells it)
 * or any `$` dimension (`int[$]`).
 */
public bool typeNeedsStaticInference(const(Type) type)
{
	if (type is null || type.type2 is null)
		return false;
	auto tip = cast(TypeIdentifierPart) type.type2.typeIdentifierPart;
	if (tip !is null && tip.typeIdentifierPart is null
		&& tip.identifierOrTemplateInstance !is null
		&& tip.identifierOrTemplateInstance.templateInstance is null
		&& identifierName(tip) == "auto")
	{
		foreach (s; type.typeSuffixes)
			if (s.array)
				return true;
	}
	foreach (s; type.typeSuffixes)
		if (s.array && renderArrayDimension(cast(TypeSuffix) s) == "$")
			return true;
	for (auto part = tip; part !is null; part = part.typeIdentifierPart)
		if (part.indexer !is null && renderIndexerDimension(part.indexer) == "$")
			return true;
	return false;
}

/// One array-literal nesting level while inferring `$` lengths: the item
/// count and the node the next inner `$` descends into.
private struct InferredArrayLevel
{
	size_t length;
	BaseNode firstElement;
}

/// The length of one literal level and where the next inner level lives.
/// Both literal shapes occur: `[...] ` in initializer position is an
/// `ArrayInitializer`, while a nested `[...]` inside it is an `ArrayLiteral`.
private bool inferredArrayLevel(BaseNode node, out InferredArrayLevel level)
{
	if (auto ai = cast(ArrayInitializer) node)
	{
		BaseNode first = null;
		if (ai.arrayMemberInitializations.length > 0)
		{
			auto m = ai.arrayMemberInitializations[0];
			if (m !is null)
				first = m.assignExpression !is null
					? cast(BaseNode) m.assignExpression
					: cast(BaseNode) m.nonVoidInitializer;
		}
		level = InferredArrayLevel(ai.arrayMemberInitializations.length, first);
		return true;
	}
	if (auto al = cast(ArrayLiteral) node)
	{
		if (al.argumentList is null)
		{
			level = InferredArrayLevel(0, null);
			return true;
		}
		BaseNode first = al.argumentList.items.length > 0
			? cast(BaseNode) al.argumentList.items[0] : null;
		level = InferredArrayLevel(al.argumentList.items.length, first);
		return true;
	}
	return false;
}

/**
 * Walks single-child wrappers (the initializer around its expression, a
 * parenthesised/bare passthrough) down to the array literal itself. Anything
 * else -- a call, an index, a variable -- is not a literal level and ends
 * the walk with null.
 */
private BaseNode descendToArrayLiteral(BaseNode node)
{
	auto current = node;
	while (current !is null)
	{
		if (cast(ArrayInitializer) current || cast(ArrayLiteral) current)
			return current;
		if (auto init = cast(Initializer) current)
		{
			if (init.nonVoidInitializer is null)
				return null;
			current = cast(BaseNode) init.nonVoidInitializer;
		}
		else if (auto nvi = cast(NonVoidInitializer) current)
		{
			if (nvi.arrayInitializer !is null)
				return cast(BaseNode) nvi.arrayInitializer;
			if (nvi.assignExpression is null)
				return null;
			current = cast(BaseNode) nvi.assignExpression;
		}
		else if (auto ex = cast(Expression) current)
		{
			if (ex.items.length != 1)
				return null;
			current = cast(BaseNode) ex.items[0];
		}
		else if (auto u = cast(UnaryExpression) current)
		{
			if (u.primaryExpression is null)
				return null;
			current = cast(BaseNode) u.primaryExpression;
		}
		else if (auto pe = cast(PrimaryExpression) current)
		{
			if (pe.arrayLiteral is null)
				return null;
			return cast(BaseNode) pe.arrayLiteral;
		}
		else
			return null;
	}
	return null;
}

/**
 * Finishes an inferred static array (`auto[$]`, `auto[3]`, `int[$]`) from
 * its initializer: `$` lengths come from the literal nesting levels,
 * an `auto` element from the deepest first element, and an explicit base
 * (`int`) resolves the usual way.
 *
 * True when the type was set (nothing left for the normal loop to do).
 * False leaves everything untouched for the normal lookups to resolve.
 */
public bool tryResolveInferredStaticArray(DSymbol* symbol, ref TypeLookups lookups,
	Scope* moduleScope, ref ModuleCache cache, DSymbol*[string] mapping)
{
	Type declType = null;
	BaseNode initNode = null;
	foreach (lookup; lookups)
	{
		if (lookup.kind == TypeLookupKind.varOrFunType && declType is null)
		{
			auto t = cast(Type) lookup.astNode;
			if (t !is null && typeNeedsStaticInference(t))
				declType = t;
		}
		else if (lookup.kind == TypeLookupKind.initializer && initNode is null)
			initNode = cast(BaseNode) lookup.astNode;
	}
	if (declType is null || initNode is null || moduleScope is null)
		return false;
	// A head template instance (`T!int[$]`) is not modelled: resolving the
	// bare base would silently drop the arguments.
	if (headTemplateInstance(declType) !is null)
		return false;

	// Dimensions inner first: an indexer (as in `int[3]`) is innermost,
	// then the suffixes in source order (as in `auto[$][$]`).
	struct Dim
	{
		bool dollar;
		string text;
	}
	Dim[] dims;
	for (auto part = cast(TypeIdentifierPart) declType.type2.typeIdentifierPart;
		part !is null; part = part.typeIdentifierPart)
	{
		if (part.indexer is null)
			continue;
		auto rendered = renderIndexerDimension(part.indexer);
		if (rendered.length == 0)
			return false;
		dims ~= Dim(rendered == "$", rendered.data);
	}
	foreach (s; declType.typeSuffixes)
	{
		if (!s.array)
			return false;
		auto rendered = renderArrayDimension(s);
		if (rendered.length == 0)
		{
			dims ~= Dim(false, "");
			continue;
		}
		dims ~= Dim(rendered == "$", rendered.data);
	}
	if (dims.length == 0)
		return false;

	// Literal levels outer first.
	InferredArrayLevel[] levels;
	for (BaseNode at = descendToArrayLiteral(initNode); at !is null;)
	{
		InferredArrayLevel level;
		if (!inferredArrayLevel(at, level))
			break;
		levels ~= level;
		if (level.firstElement is null)
			break;
		at = descendToArrayLiteral(level.firstElement);
	}

	// Every `$` (counted from the outside in) needs a literal level there.
	const dimCount = dims.length;
	const levelCount = levels.length;
	for (size_t outer = 0; outer < dimCount; ++outer)
	{
		if (!dims[dimCount - 1 - outer].dollar)
			continue;
		if (outer >= levelCount)
			return false;
	}

	// The element: an `auto` base resolves the deepest level's first item
	// (`1` in `[1, 2]`); an explicit base (`int`) resolves the usual way.
	// Mismatched nesting is left for the normal path.
	auto tip = declType.type2.typeIdentifierPart;
	const bool baseIsAuto = tip !is null && identifierName(tip) == "auto";
	DSymbol* base = null;
	if (baseIsAuto)
	{
		if (dimCount != levelCount || levels[levelCount - 1].firstElement is null)
			return false;
		BaseNode elementNode = levels[levelCount - 1].firstElement;
		bool handled;
		DSymbol* value;
		TypeConstructorFlags unusedQualifiers;
		resolveInitializerNode(elementNode, symbol, null, moduleScope, cache, mapping,
			handled, value, unusedQualifiers);
		if (!handled || value is null)
			return false;
		typeSwap(value, false);
		if (value is null)
			return false;
		base = value;
	}
	else
	{
		DSymbol* resolved;
		istring missingName;
		if (resolveDeclaredType(declType, symbol, null, moduleScope, cache, mapping,
				resolved, missingName) != TypeNodeOutcome.resolved || resolved is null)
			return false;
		base = resolved;
	}

	DSymbol* current = base;
	for (size_t inner = 0; inner < dimCount; ++inner)
	{
		string dimText = dims[inner].text;
		if (dims[inner].dollar)
		{
			import std.conv : to;
			dimText = levels[levelCount - 1 - inner].length.to!string;
		}
		current = wrapTypeSymbol(ARRAY_SYMBOL_NAME, SymbolQualifier.array, current,
			dimText.length > 0 ? internString(dimText) : istring.init, arraySymbols[]);
		if (current is null)
			return false;
	}
	auto qualifiers = collectTypeConstructors(declType);
	symbol.flags.declaredTypeIsConst = qualifiers.isConst;
	symbol.flags.declaredTypeIsImmutable = qualifiers.isImmutable;
	symbol.flags.declaredTypeIsShared = qualifiers.isShared;
	symbol.flags.declaredTypeIsInout = qualifiers.isInout;
	symbol.type = current;
	symbol.ownType = true;
	return true;
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
			dim ~= t.text is null ? str(t.type) : t.text;
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
