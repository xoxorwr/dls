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
 * Initializer/expression-value inference: the `auto x = <expr>` pipeline.
 * Answers "what is the type of this initializer expression" -- a small
 * expression-evaluator, separate from `declared_type`'s AST-node-to-symbol
 * walker even though both ultimately produce a `DSymbol*` standing in for a
 * type.
 */
module dsymbol.conversion.second.initializer;

import dsymbol.conversion.second.declared_type : identifierName, resolveTypeNodeValue,
	TypeConstructorFlags;
import dsymbol.conversion.second.instantiate : instantiateFromNode, instantiateSymbol;
import dsymbol.symbol;
import dsymbol.scope_;
import dsymbol.string_interning;
import dsymbol.builtin.names;
import dsymbol.builtin.symbols : pointerSymbols;
import dsymbol.type_lookup;
import dsymbol.modulecache;
import std.experimental.allocator;
import std.experimental.allocator.gc_allocator : GCAllocator;
import std.experimental.logger;
import dparse.ast;
import dparse.lexer;

/**
 * The three outputs `resolveInitializerNode` used to thread through closure
 * capture: the resolved value, whether the shape was modelled at all, and any
 * declared-type qualifier the value's own declaration carried (only ever set
 * by the function-call branch of `evalInitializerExpr`, from the callee's own
 * flags -- see there).  Returned by value from every recursive call instead
 * of mutated in place, so an inner call's contribution can never silently
 * overwrite an outer one's (see `docs/refactor-second.md`: this is what made
 * the `get(Data())` qualifier-clobbering bug possible in the first place).
 */
private struct InitializerResolution
{
	DSymbol* value;
	bool handled;
	TypeConstructorFlags qualifiers;
}

/// Evaluates a name / template-instance reference (`TD`, `TD!int`) to the
/// symbol it stands for.  False only when the shape itself is not modelled
/// (no identifier at all); a name that fails to resolve still returns true
/// with a null value, exactly as the rest of the walker does.
private bool evalIoti(const(IdentifierOrTemplateInstance) ioti, DSymbol* symbol,
	Scope* moduleScope, ref ModuleCache cache, DSymbol*[string] mapping, out DSymbol* value)
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

/// The symbol of a builtin type name (`int`, `bool`, `string`), looked up
/// exactly the way a literal's type name is.
private DSymbol* builtinType(string name, DSymbol* symbol, Scope* moduleScope,
	DSymbol*[string] mapping)
{
	return name is null
		? null
		: lookupInitializerBase(internString(name), symbol, moduleScope, mapping);
}

/**
 * Resolves an initializer expression (or subexpression) to the symbol it
 * stands for.
 *
 * A name chain, prefix `&` / `*` / `!` / `-` / `+` / `~`, index expressions, a
 * call (worth what the callee returns), literals (as their built-in type
 * name), a ternary (its first non-`null` branch), `cast`/`new` (their type),
 * array initializers/literals (element then array) and the builtin operators
 * (see `evalBinary`; `1 << 0` is an `int`, `a == b` a `bool`).  `handled` is
 * false, and `value`/`qualifiers` left at their `.init`, for a shape it does
 * not model (a struct initializer, an operator over a user type, a function
 * literal, an unmodelled primary).
 *
 * `qualifiers` is set only by the function-call branch, from that call's own
 * callee -- every other branch returns `TypeConstructorFlags.init`.  A branch
 * that only needs a subexpression's *value* (an array literal's element, an
 * index step's base, a binary operand, a deduced call argument) reads
 * `.value`/`.handled` off the recursive call and leaves its own qualifiers at
 * `.init`; only a branch whose result really *is* a subexpression's result
 * unchanged (an initializer wrapper, a parenthesised expression, a ternary
 * branch, the comparison-class forwarding) returns that subexpression's
 * `InitializerResolution` as its own.
 */
private InitializerResolution evalInitializerExpr(const(BaseNode) e, DSymbol* symbol,
	Scope* moduleScope, ref ModuleCache cache, DSymbol*[string] mapping)
{
	if (e is null)
		return InitializerResolution.init;

	// `x = <initializer>`: unwrap to the expression, array or struct
	// initializer it holds.
	if (auto init = cast(const(Initializer)) e)
	{
		if (init.nonVoidInitializer is null)
			return InitializerResolution.init;
		return evalInitializerExpr(init.nonVoidInitializer, symbol, moduleScope, cache, mapping);
	}
	if (auto nvi = cast(const(NonVoidInitializer)) e)
	{
		if (nvi.assignExpression !is null)
			return evalInitializerExpr(nvi.assignExpression, symbol, moduleScope, cache, mapping);
		if (nvi.arrayInitializer !is null)
			return evalInitializerExpr(nvi.arrayInitializer, symbol, moduleScope, cache, mapping);
		// A struct initializer: the crumb walk's default traversal mixed
		// its members' crumbs, which never resolved to anything useful.
		return InitializerResolution.init;
	}
	// `[a, b]`: the element type is the first member's.
	if (auto ai = cast(const(ArrayInitializer)) e)
	{
		DSymbol* element;
		if (ai.arrayMemberInitializations.length > 0)
		{
			auto member = ai.arrayMemberInitializations[0];
			if (member is null)
				return InitializerResolution.init;
			if (member.assignExpression !is null)
			{
				auto sub = evalInitializerExpr(member.assignExpression, symbol, moduleScope,
					cache, mapping);
				if (!sub.handled)
					return InitializerResolution.init;
				element = sub.value;
			}
			else if (member.nonVoidInitializer !is null)
			{
				auto sub = evalInitializerExpr(member.nonVoidInitializer, symbol, moduleScope,
					cache, mapping);
				if (!sub.handled)
					return InitializerResolution.init;
				element = sub.value;
			}
			else
				return InitializerResolution.init;
		}
		else
			// An empty array literal: the crumb walk recorded the `void`.
			element = lookupInitializerBase(internString("void"), symbol, moduleScope, mapping);
		return InitializerResolution(arrayLiteralSymbol(element), true, TypeConstructorFlags.init);
	}
	// `(a, b)`: a comma expression is not a type.
	if (auto wrapper = cast(const(Expression)) e)
	{
		if (wrapper.items.length != 1)
			return InitializerResolution.init;
		return evalInitializerExpr(wrapper.items[0], symbol, moduleScope, cache, mapping);
	}
	// `cast(T) e`: the cast's *type* is what the expression stands for
	// (the crumb producer fed it through `addTypeToLookups`).
	if (auto castExpr = cast(const(CastExpression)) e)
	{
		if (castExpr.type is null)
			return InitializerResolution.init;
		bool ok;
		auto value = resolveTypeNodeValue(castExpr.type, symbol, moduleScope, cache, mapping, ok);
		return InitializerResolution(value, ok, TypeConstructorFlags.init);
	}
	// `new T(...)`: a value of `T`.
	if (auto ne = cast(const(NewExpression)) e)
	{
		if (ne.type is null || ne.newAnonClassExpression !is null)
			return InitializerResolution.init;
		bool ok;
		auto value = resolveTypeNodeValue(ne.type, symbol, moduleScope, cache, mapping, ok);
		return InitializerResolution(value, ok, TypeConstructorFlags.init);
	}
	// A comparison is wrapped: `CmpExpression` is what holds the one
	// (`<` -> `relExpression`, `==` -> `equalExpression`, ...), or the
	// plain expression when there is no comparison operator at all.
	if (auto cmp = cast(const(CmpExpression)) e)
	{
		if (cmp.shiftExpression !is null)
			return evalInitializerExpr(cmp.shiftExpression, symbol, moduleScope, cache, mapping);
		if (cmp.equalExpression !is null)
			return evalInitializerExpr(cmp.equalExpression, symbol, moduleScope, cache, mapping);
		if (cmp.identityExpression !is null)
			return evalInitializerExpr(cmp.identityExpression, symbol, moduleScope, cache, mapping);
		if (cmp.relExpression !is null)
			return evalInitializerExpr(cmp.relExpression, symbol, moduleScope, cache, mapping);
		if (cmp.inExpression !is null)
			return evalInitializerExpr(cmp.inExpression, symbol, moduleScope, cache, mapping);
		return InitializerResolution.init;
	}

	{
		DSymbol* binaryValue;
		if (evalBinary(e, symbol, moduleScope, cache, mapping, binaryValue))
			return InitializerResolution(binaryValue, true, TypeConstructorFlags.init);
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
				DSymbol* value;
				if (!evalIoti(ioti, symbol, moduleScope, cache, mapping, value))
					return InitializerResolution.init;
				return InitializerResolution(value, true, TypeConstructorFlags.init);
			}
			auto left = evalInitializerExpr(unary.unaryExpression, symbol, moduleScope, cache,
				mapping);
			if (!left.handled)
				return InitializerResolution.init;
			auto value = memberStep(left.value, identifierName(ioti), moduleScope);
			if (value !is null && ioti.templateInstance !is null)
				value = instantiateFromNode(value, ioti.templateInstance, ioti.tokens,
					symbol, moduleScope, cache, mapping);
			return InitializerResolution(value, true, TypeConstructorFlags.init);
		}
		if (unary.primaryExpression !is null)
		{
			// `TD` / `TD!int` as a primary expression.
			if (unary.primaryExpression.identifierOrTemplateInstance !is null)
			{
				DSymbol* value;
				if (!evalIoti(unary.primaryExpression.identifierOrTemplateInstance, symbol,
						moduleScope, cache, mapping, value))
					return InitializerResolution.init;
				return InitializerResolution(value, true, TypeConstructorFlags.init);
			}
			// A parenthesised expression (`(1 << 0)`) or an array literal
			// needs the primary node's own walk, not just its literal.
			return evalInitializerExpr(unary.primaryExpression, symbol, moduleScope, cache,
				mapping);
		}
		// `foo(...)`: worth what the callee returns.
		if (unary.functionCallExpression !is null)
		{
			auto calleeEval = evalInitializerExpr(unary.functionCallExpression.unaryExpression,
				symbol, moduleScope, cache, mapping);
			if (!calleeEval.handled)
				return InitializerResolution.init;
			DSymbol* callee = calleeEval.value;
			DSymbol* value = callee;
			TypeConstructorFlags resultQualifiers;
			if (value !is null)
			{
				// The callee's own declared-return-type qualifier
				// (`const(T**) get(T)()`) -- read before `typeSwap` below
				// collapses `value` from the function symbol to its return
				// type and the association is lost.  This call's own
				// return value unconditionally, regardless of what
				// `deduceTemplateArguments` below returns for its
				// arguments: an argument that is itself a call
				// (`get(Data())`) evaluates in its own
				// `evalInitializerExpr` call and returns its own
				// `InitializerResolution` with `Data`'s qualifiers, which
				// `deduceTemplateArguments` reads `.value` from and
				// discards -- there is no shared variable left for it to
				// clobber.
				resultQualifiers = TypeConstructorFlags(callee.flags.declaredTypeIsConst,
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
					unary.functionCallExpression.arguments, symbol, moduleScope, cache, mapping);
				typeSwap(value);
				if (deduced.length > 0)
					value = instantiateSymbol(value, moduleScope, cache, deduced);
			}
			return InitializerResolution(value, true, resultQualifiers);
		}
		// `a[i]`: one step down per index that is not a slice.
		if (unary.indexExpression !is null)
		{
			auto base = evalInitializerExpr(unary.indexExpression.unaryExpression, symbol,
				moduleScope, cache, mapping);
			if (!base.handled)
				return InitializerResolution.init;
			auto value = applyInitializerIndexes(base.value, unary.indexExpression.indexes,
				moduleScope);
			return InitializerResolution(value, true, TypeConstructorFlags.init);
		}
		// `cast(T) e`: the crumb producer encodes the cast's *type*
		// through `addTypeToLookups`, so the type is what the expression
		// stands for.
		if (unary.castExpression !is null)
			return evalInitializerExpr(unary.castExpression, symbol, moduleScope, cache, mapping);
		// `new T(...)`: a value of `T`.
		if (unary.newExpression !is null)
			return evalInitializerExpr(unary.newExpression, symbol, moduleScope, cache, mapping);
		// prefix `!` (a `bool`) and `-` / `+` / `~` (the promoted
		// operand type, through the builtin scalars only).
		if (unary.unaryExpression !is null
			&& (unary.prefix.type == tok!"!" || unary.prefix.type == tok!"-"
				|| unary.prefix.type == tok!"+" || unary.prefix.type == tok!"~"))
		{
			auto operandEval = evalInitializerExpr(unary.unaryExpression, symbol, moduleScope,
				cache, mapping);
			if (!operandEval.handled)
				return InitializerResolution.init;
			DSymbol* value;
			if (unary.prefix.type == tok!"!")
				value = builtinType("bool", symbol, moduleScope, mapping);
			else
			{
				auto operand = operandEval.value;
				typeSwap(operand, false);
				value = builtinType(promotedScalarName(operandTypeName(operand)), symbol,
					moduleScope, mapping);
			}
			return InitializerResolution(value, value !is null, TypeConstructorFlags.init);
		}
		// prefix `&` / `*`.
		if (unary.unaryExpression !is null)
		{
			auto baseEval = evalInitializerExpr(unary.unaryExpression, symbol, moduleScope,
				cache, mapping);
			if (!baseEval.handled)
				return InitializerResolution.init;
			DSymbol* base = baseEval.value;
			if (base !is null)
				typeSwap(base);
			if (base !is null)
			{
				if (unary.prefix.type == tok!"&")
					base = initializerPointerStep(base);
				else if (unary.prefix.type == tok!"*")
					base = initializerIndexStep(base, moduleScope);
				else
					return InitializerResolution.init;
			}
			return InitializerResolution(base, true, TypeConstructorFlags.init);
		}
		return InitializerResolution.init;
	}

	if (auto index = cast(const(IndexExpression)) e)
	{
		auto base = evalInitializerExpr(index.unaryExpression, symbol, moduleScope, cache, mapping);
		if (!base.handled)
			return InitializerResolution.init;
		auto value = applyInitializerIndexes(base.value, index.indexes, moduleScope);
		return InitializerResolution(value, true, TypeConstructorFlags.init);
	}

	if (auto ternary = cast(const(TernaryExpression)) e)
	{
		// The first branch that is not a bare `null`.
		if (ternary.expression !is null && !isNullLiteral(ternary.expression))
			return evalInitializerExpr(ternary.expression, symbol, moduleScope, cache, mapping);
		if (ternary.ternaryExpression !is null)
			return evalInitializerExpr(ternary.ternaryExpression, symbol, moduleScope, cache,
				mapping);
		return InitializerResolution.init;
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
				auto sub = evalInitializerExpr(al.argumentList.items[0], symbol, moduleScope,
					cache, mapping);
				if (!sub.handled)
					return InitializerResolution.init;
				element = sub.value;
			}
			else
				element = lookupInitializerBase(internString("void"), symbol, moduleScope,
					mapping);
			return InitializerResolution(arrayLiteralSymbol(element), true, TypeConstructorFlags.init);
		}
		// `(expr)`: the parser records the parenthesised expression (as
		// the one-item list the `Expression` node holds) in the primary.
		if (primary.expression !is null)
			return evalInitializerExpr(primary.expression, symbol, moduleScope, cache, mapping);
		DSymbol* value;
		auto ok = evalInitializerPrimary(primary, symbol, moduleScope, mapping, value);
		return InitializerResolution(value, ok, TypeConstructorFlags.init);
	}

	return InitializerResolution.init;
}

// The result of one binary operator over two operands.  `typeSwap(...,
// false)` keeps an alias name, so a `string` operand stays a `string`
// instead of becoming the array type.
private bool evalBinaryResult(BinaryKind kind, const(ExpressionNode) leftNode,
	const(ExpressionNode) rightNode, DSymbol* symbol, Scope* moduleScope, ref ModuleCache cache,
	DSymbol*[string] mapping, out DSymbol* result)
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
	{
		auto l = evalInitializerExpr(leftNode, symbol, moduleScope, cache, mapping);
		if (!l.handled)
			return false;
		leftOperand = l.value;
		typeSwap(leftOperand, false);
		break;
	}
	case BinaryKind.concatenation:
	case BinaryKind.arithmetic:
	{
		auto l = evalInitializerExpr(leftNode, symbol, moduleScope, cache, mapping);
		auto r = evalInitializerExpr(rightNode, symbol, moduleScope, cache, mapping);
		if (!l.handled || !r.handled)
			return false;
		leftOperand = l.value;
		rightOperand = r.value;
		typeSwap(leftOperand, false);
		typeSwap(rightOperand, false);
		break;
	}
	}
	auto name = binaryResultTypeName(kind, leftOperand, rightOperand);
	if (name is null)
		return false;
	result = builtinType(name, symbol, moduleScope, mapping);
	return result !is null;
}

// `a <op> b`: dparse has one class per operator (see the casts below),
// and the class says what the result is.  Anything else -- an
// overloaded `opBinary`, an enum member's base type -- stays
// unmodelled and leaves the symbol untyped.
private bool evalBinary(const(BaseNode) node, DSymbol* symbol, Scope* moduleScope,
	ref ModuleCache cache, DSymbol*[string] mapping, out DSymbol* result)
{
	result = null;
	if (auto binary = cast(const(AddExpression)) node)
		return evalBinaryResult(
			binary.operator == tok!"~" ? BinaryKind.concatenation
				: BinaryKind.arithmetic,
			binary.left, binary.right, symbol, moduleScope, cache, mapping, result);
	if (auto binary = cast(const(MulExpression)) node)
		return evalBinaryResult(BinaryKind.arithmetic, binary.left, binary.right, symbol,
			moduleScope, cache, mapping, result);
	if (auto binary = cast(const(ShiftExpression)) node)
		return evalBinaryResult(BinaryKind.shift, binary.left, binary.right, symbol, moduleScope,
			cache, mapping, result);
	if (auto binary = cast(const(AndExpression)) node)
		return evalBinaryResult(BinaryKind.arithmetic, binary.left, binary.right, symbol,
			moduleScope, cache, mapping, result);
	if (auto binary = cast(const(OrExpression)) node)
		return evalBinaryResult(BinaryKind.arithmetic, binary.left, binary.right, symbol,
			moduleScope, cache, mapping, result);
	if (auto binary = cast(const(XorExpression)) node)
		return evalBinaryResult(BinaryKind.arithmetic, binary.left, binary.right, symbol,
			moduleScope, cache, mapping, result);
	if (auto binary = cast(const(PowExpression)) node)
		return evalBinaryResult(BinaryKind.arithmetic, binary.left, binary.right, symbol,
			moduleScope, cache, mapping, result);
	if (auto binary = cast(const(EqualExpression)) node)
		return evalBinaryResult(BinaryKind.comparison, binary.left, binary.right, symbol,
			moduleScope, cache, mapping, result);
	if (auto binary = cast(const(RelExpression)) node)
		return evalBinaryResult(BinaryKind.comparison, binary.left, binary.right, symbol,
			moduleScope, cache, mapping, result);
	if (auto binary = cast(const(IdentityExpression)) node)
		return evalBinaryResult(BinaryKind.comparison, binary.left, binary.right, symbol,
			moduleScope, cache, mapping, result);
	if (auto binary = cast(const(AndAndExpression)) node)
		return evalBinaryResult(BinaryKind.logical, binary.left, binary.right, symbol, moduleScope,
			cache, mapping, result);
	if (auto binary = cast(const(OrOrExpression)) node)
		return evalBinaryResult(BinaryKind.logical, binary.left, binary.right, symbol, moduleScope,
			cache, mapping, result);
	return false;
}

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
private DSymbol*[string] deduceTemplateArguments(DSymbol* callee, const Arguments arguments,
	DSymbol* symbol, Scope* moduleScope, ref ModuleCache cache, DSymbol*[string] mapping)
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
		auto argEval = evalInitializerExpr(args[i].assignExpression, symbol, moduleScope, cache,
			mapping);
		if (!argEval.handled || argEval.value is null)
			continue;
		DSymbol* argType = argEval.value;
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

package void resolveInitializerNode(const(BaseNode) expression, DSymbol* symbol,
	TypeLookup* lookup, Scope* moduleScope, ref ModuleCache cache, DSymbol*[string] mapping,
	out bool handled, out DSymbol* result, out TypeConstructorFlags qualifiers)
{
	auto resolved = evalInitializerExpr(expression, symbol, moduleScope, cache, mapping);
	handled = resolved.handled;
	result = resolved.value;
	qualifiers = resolved.qualifiers;
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
package DSymbol* memberStep(DSymbol* current, istring name, Scope* moduleScope)
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

package void resolveTypeFromInitializer(DSymbol* symbol, TypeLookup* lookup,
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

public void typeSwap(ref DSymbol* currentSymbol, bool followAlias = true)
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
