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

module dcd.server.autocomplete.util;

import std.algorithm;
import std.experimental.allocator;
import std.experimental.logger;
import std.range;
import std.string;
import std.typecons;

import dcd.common.messages;

import dparse.lexer;
import dparse.rollback_allocator;

import dsymbol.builtin.names;
import dsymbol.builtin.symbols;
import dsymbol.conversion;
import dsymbol.conversion.second : BinaryKind, binaryResultTypeName, hasTemplateParameters,
	instantiateWithArguments, promotedScalarName, typeSwap;
import dsymbol.modulecache;
import dsymbol.scope_;
import dsymbol.signature;
import dsymbol.string_interning;
import dsymbol.symbol;
//import dsymbol.ufcs;
import dsymbol.utils;

enum ImportKind : ubyte
{
	selective,
	normal,
	neither
}

struct SymbolStuff
{
	void destroy()
	{
		typeid(DSymbol).destroy(symbol);
		typeid(Scope).destroy(scope_);
	}

	DSymbol*[] symbols;
	DSymbol* symbol;
	Scope* scope_;
}

/**
 * Params:
 *     completionType = the completion type being requested
 *     kind = the kind of the current item in the completion chain
 *     current = the index of the current item in the symbol chain
 *     max = the number of items in the symbol chain
 * Returns:
 *     true if the symbol should be swapped with its type field
 */
bool shouldSwapWithType(CompletionType completionType, CompletionKind kind,
	size_t current, size_t max) pure nothrow @safe
{
	// packages (and modules, navigated the same way mid-chain) never have
	// types, so always return false
	if (kind == CompletionKind.packageName
		|| kind == CompletionKind.moduleName
		|| kind == CompletionKind.className
		|| kind == CompletionKind.structName
		|| kind == CompletionKind.interfaceName
		|| kind == CompletionKind.enumName
		|| kind == CompletionKind.unionName
		|| kind == CompletionKind.templateName
		|| kind == CompletionKind.keyword)
	{
		return false;
	}
	// Swap out every part of a chain with its type except the last part
	if (current < max)
		return true;
	// Only swap out types for these kinds
	immutable bool isInteresting =
		kind == CompletionKind.variableName
		|| kind == CompletionKind.memberVariableName
		|| kind == CompletionKind.importSymbol
		|| kind == CompletionKind.aliasName
		|| kind == CompletionKind.enumMember
		|| kind == CompletionKind.functionName;
	return isInteresting && (completionType == CompletionType.identifiers
		|| completionType == CompletionType.structMembers
		|| (completionType == completionType.calltips
			&& (kind == CompletionKind.variableName
				|| kind == CompletionKind.memberVariableName))) ;
}

istring stringToken()(auto ref const Token a)
{
	return internString(a.text is null ? str(a.type) : a.text);
}

/// `sym`'s `.type`, or `[]` when it has none (or points at itself). The
/// single place every "descend into this symbol's type instead of the
/// symbol itself" decision in `getSymbolsByTokenChain` funnels through, so
/// there is one definition of what swapping means, not several copies that
/// can drift apart.
DSymbol*[] swapForType(DSymbol* sym) pure nothrow @safe
{
	return sym.type is null || sym.type is sym ? [] : [sym.type];
}

/**
 * Params:
 *     sourceCode = the source code of the file being edited
 *     cursorPosition = the cursor position in bytes
 * Returns:
 *     a sorted range of tokens before the cursor position
 */
auto getTokensBeforeCursor(const(ubyte[]) sourceCode, size_t cursorPosition,
	ref StringCache cache, out const(Token)[] tokenArray)
{
	// A prior version of this patched a synthetic ';' into the source ahead
	// of the cursor (struct TTT{ Typ| } otherwise gets no completion) by
	// duplicating the buffer - the caller's is an open document served as a
	// `const` slice, so a completion must never leave a stray ';' in it for
	// later requests to parse. Left unimplemented rather than reintroduced
	// half-finished; revisit if that gap is worth the per-request copy.
	auto source = cast(ubyte[]) sourceCode;

	LexerConfig config;
	config.fileName = "";
	tokenArray = getTokensForParser(source, config, &cache);
	auto sortedTokens = assumeSorted(tokenArray);
	return sortedTokens.lowerBound(cast(size_t) cursorPosition);
}

/**
 * Params:
 *     request = the autocompletion request
 *     type = type the autocompletion type
 * Returns:
 *     all symbols that should be considered for the autocomplete list based on
 *     the request's source code, cursor position, and completion type.
 */
SymbolStuff getSymbolsForCompletion(const AutocompleteRequest request,
	const CompletionType type, RollbackAllocator* rba,
	ref StringCache cache, ref ModuleCache moduleCache)
{
	const(Token)[] tokenArray;
	size_t searchPos = request.cursorPosition;
	if (type == CompletionType.location)
		searchPos++;
	auto beforeTokens = getTokensBeforeCursor(request.sourceCode, searchPos, cache, tokenArray);
	ScopeSymbolPair pair = generateAutocompleteTrees(tokenArray, rba, request.cursorPosition, moduleCache);
	auto expression = getExpression(beforeTokens);
	auto symbols = getSymbolsByTokenChain(pair.scope_, expression, request.cursorPosition, type);
	//if (symbols.length == 0 && doUFCSSearch(stringToken(beforeTokens.front), stringToken(beforeTokens.back))) {
	//	// Let search for UFCS, since we got no hit
	//	symbols ~= getSymbolsByTokenChain(pair.scope_, getExpression([beforeTokens.back]), request.cursorPosition, type);
	//}
	return SymbolStuff(symbols, pair.symbol, pair.scope_);
}

bool isSliceExpression(T)(T tokens, size_t index)
{
	while (index < tokens.length) switch (tokens[index].type)
	{
	case tok!"[":
		tokens.skipParen(index, tok!"[", tok!"]");
		break;
	case tok!"(":
		tokens.skipParen(index, tok!"(", tok!")");
		break;
	case tok!"]":
	case tok!"}":
		return false;
	case tok!"..":
		return true;
	default:
		index++;
		break;
	}
	return false;
}

/**
 * Resolves the explicit template arguments that follow a `!` in a token chain
 * (`foo!Bar`, `foo!(Bar, Baz)`) to symbols.
 *
 * `index` must point at the `!`.  On success it is advanced to the last token
 * of the argument list and `args` holds one symbol per argument; `false` means
 * the shape is not modelled (no argument, a qualified or expression
 * argument), and the caller keeps the chain it has.
 */
bool resolveTemplateArguments(T)(T tokens, ref size_t index, Scope* completionScope,
	size_t cursorPosition, out DSymbol*[] args)
{
	args = null;
	if (index + 1 >= tokens.length)
		return false;

	size_t i = index + 1;
	size_t last;
	if (tokens[i].type == tok!"(")
	{
		// `foo!(A, B)` -- split the argument list on top-level commas
		size_t depth;
		size_t close = i;
		for (; close < tokens.length; ++close)
		{
			if (tokens[close].type == tok!"(")
				++depth;
			else if (tokens[close].type == tok!")")
			{
				--depth;
				if (depth == 0)
					break;
			}
		}
		if (close >= tokens.length)
			return false;

		size_t start = i + 1;
		depth = 0;
		for (size_t j = start; j <= close; ++j)
		{
			if (j < close)
			{
				if (tokens[j].type == tok!"(" || tokens[j].type == tok!"[")
					++depth;
				else if (tokens[j].type == tok!")" || tokens[j].type == tok!"]")
					--depth;
			}
			if (j == close || (depth == 0 && tokens[j].type == tok!","))
			{
				auto argument = resolveTemplateArgument(tokens[start .. j], completionScope, cursorPosition);
				if (argument is null)
					return false;
				args ~= argument;
				start = j + 1;
			}
		}
		last = close;
	}
	else
	{
		auto argument = resolveTemplateArgument(tokens[i .. i + 1], completionScope, cursorPosition);
		if (argument is null)
			return false;
		args ~= argument;
		last = i;
	}

	index = last;
	return true;
}

/// One explicit template argument: a builtin type name or a symbol name.
private DSymbol* resolveTemplateArgument(T)(T tokens, Scope* completionScope,
	size_t cursorPosition)
{
	if (tokens.length != 1)
		return null;
	auto token = tokens[0];
	if (token.type == tok!"identifier")
	{
		auto found = completionScope.getSymbolsByNameAndCursor(stringToken(token), cursorPosition);
		return found.length > 0 ? found[0] : null;
	}
	// Builtin type names (`int`, `string`, ...) live in `builtinSymbols`, so
	// consult that table before the scope.
	auto name = internString(str(token.type));
	foreach (candidate; builtinSymbols[])
		if (candidate.name == name)
			return cast(DSymbol*) candidate;
	return null;
}

/**
 * Resolves the arguments of a call -- whose `(` is at `index` -- to the types
 * they stand for, one symbol per argument in the order written.
 *
 * This is what `wrap(1)` needs: the call is the only place its parameter is
 * named, so the argument's type (`int`) is the binding.  `false` means an
 * argument is a shape this does not model, and the caller keeps the generic
 * symbol rather than guessing.
 */
private bool resolveCallArgumentTypes(T)(T tokens, size_t index, Scope* completionScope,
	size_t cursorPosition, out DSymbol*[] types)
{
	types = null;
	if (index >= tokens.length || tokens[index].type != tok!"(")
		return false;

	size_t close = index;
	tokens.skipParen(close, tok!"(", tok!")");
	// A call still being typed (`wrap(1`) runs off the end of the chain
	// instead of closing, and there is nothing yet to bind.
	if (close >= tokens.length || tokens[close].type != tok!")")
		return false;
	if (close == index + 1) // `wrap()`
		return false;

	// Split the argument list on its top-level commas, ignoring the ones
	// nested in a call or an index of an argument.
	size_t start = index + 1;
	size_t depth = 0;
	for (size_t j = start; j <= close; ++j)
	{
		if (j < close)
		{
			if (tokens[j].type == tok!"(" || tokens[j].type == tok!"[")
				++depth;
			else if (tokens[j].type == tok!")" || tokens[j].type == tok!"]")
				--depth;
		}
		if (j == close || (depth == 0 && tokens[j].type == tok!","))
		{
			auto argument = callArgumentType(tokens[start .. j], completionScope, cursorPosition);
			if (argument is null)
				return false;
			types ~= argument;
			start = j + 1;
		}
	}
	return types.length > 0;
}

/// The type one call argument stands for, or null for a shape not modelled.
private DSymbol* callArgumentType(T)(T tokens, Scope* completionScope, size_t cursorPosition)
{
	if (tokens.length == 0)
		return null;

	// A constant expression (`2 + 3`) folds to the type it produces; when it
	// is not one, the argument has to be a name chain standing for a value.
	auto folded = constantArgumentType(tokens, completionScope, cursorPosition);
	return folded !is null ? folded : chainArgumentType(tokens, completionScope, cursorPosition);
}

/// The type a chain-shaped argument stands for (`widget`, `a.b!c(x).d`), or
/// null when it is not a name chain at all.
private DSymbol* chainArgumentType(T)(T tokens, Scope* completionScope, size_t cursorPosition)
{
	if (tokens.length == 0)
		return null;

	// A lone literal is worth the builtin type of the same name: `1` is an
	// `int`, `1.0` a `double`, `"x"` a `string`.
	if (tokens.length == 1)
	{
		auto typeName = literalTypeName(tokens[0].type);
		if (typeName !is null)
			return typeNamed(typeName, completionScope, cursorPosition);
	}

	// The chain's symbol is swapped for the type it stands for.
	auto symbols = getSymbolsByTokenChain(completionScope, getExpression(tokens),
		cursorPosition, CompletionType.identifiers);
	if (symbols.length == 0)
		return null;
	auto symbol = symbols[0];
	if (symbol is null)
		return null;
	typeSwap(symbol);
	return symbol;
}

/**
 * Folds a constant expression written in an argument -- `2 + 3`, `1 << 0`,
 * `(a) * b`, `-x` -- to the type it produces, or returns null for a shape this
 * does not model.
 *
 * The operators are D's and bind the way D's do, so `1 == 2 + 3` is a `bool`
 * and `1 + 2L` a `long`; the types themselves come from
 * `binaryResultTypeName`, the same rule the initializer walk applies to an
 * expression's tree, so an argument and an `auto x = <expr>` cannot disagree.
 */
private DSymbol* constantArgumentType(T)(T tokens, Scope* completionScope, size_t cursorPosition)
{
	size_t index = 0;
	auto type = binaryExpressionType(tokens, index, tokens.length, 0,
		completionScope, cursorPosition);
	// A token left over is a shape the fold does not model (a cast, a
	// ternary, a call whose result it could not follow).
	if (type is null || index != tokens.length)
		return null;
	return type;
}

/// One binary expression, with `index` left on the first token after it.
private DSymbol* binaryExpressionType(T)(T tokens, ref size_t index, size_t end,
	int minPrecedence, Scope* completionScope, size_t cursorPosition)
{
	auto left = operandType(tokens, index, end, completionScope, cursorPosition);
	if (left is null)
		return null;

	while (index < end)
	{
		OperatorInfo op;
		if (!operatorInfo(tokens[index].type, op) || op.precedence < minPrecedence)
			break;

		index++;
		// Left associative: the right side takes only the operators binding
		// strictly tighter, so `a - b - c` folds as `(a - b) - c`.
		auto right = binaryExpressionType(tokens, index, end, op.precedence + 1,
			completionScope, cursorPosition);
		if (right is null)
			return null;

		auto name = binaryResultTypeName(op.kind, left, right);
		if (name is null)
			return null;
		left = typeNamed(name, completionScope, cursorPosition);
		if (left is null)
			return null;
	}
	return left;
}

/// One operand: a prefix, a parenthesised group, a literal or a name chain.
private DSymbol* operandType(T)(T tokens, ref size_t index, size_t end,
	Scope* completionScope, size_t cursorPosition)
{
	if (index >= end)
		return null;

	// The prefixes that keep the operand's own scalar type (`-x`, `~x`) or
	// turn it into a `bool` (`!x`).
	switch (tokens[index].type)
	{
	case tok!"-":
	case tok!"+":
	case tok!"~":
		index++;
		auto operand = operandType(tokens, index, end, completionScope, cursorPosition);
		if (operand is null)
			return null;
		auto promoted = promotedScalarName(operand.name.data);
		return promoted is null ? null : typeNamed(promoted, completionScope, cursorPosition);
	case tok!"!":
		index++;
		if (operandType(tokens, index, end, completionScope, cursorPosition) is null)
			return null;
		return typeNamed("bool", completionScope, cursorPosition);
	default:
		break;
	}

	// `(2 + 3)`: a group is an expression of its own.
	if (tokens[index].type == tok!"(")
	{
		auto close = matchingParen(tokens, index, end);
		if (close >= end)
			return null;
		auto inner = constantArgumentType(tokens[index + 1 .. close],
			completionScope, cursorPosition);
		if (inner is null)
			return null;
		index = close + 1;
		return inner;
	}

	// A literal is worth the builtin type of the same name.
	auto literal = literalTypeName(tokens[index].type);
	if (literal !is null)
	{
		index++;
		return typeNamed(literal, completionScope, cursorPosition);
	}

	// The rest is a name chain (`widget`, `a.b!c(x).d`) running up to the next
	// operator: it is the chain walk that knows what a call returns.
	auto stop = nextOperator(tokens, index, end);
	auto chain = chainArgumentType(tokens[index .. stop], completionScope, cursorPosition);
	if (chain is null)
		return null;
	index = stop;
	return chain;
}

/// The `)` matching the `(` at `index`, or `end` when the group never closes.
private size_t matchingParen(T)(T tokens, size_t index, size_t end)
{
	auto slice = tokens[index .. end];
	size_t local = 0;
	slice.skipParen(local, tok!"(", tok!")");
	if (local >= slice.length || slice[local].type != tok!")")
		return end;
	return index + local;
}

/// The first token at or after `index` that is an operator no group encloses:
/// where the chain an operand is made of has to stop.
private size_t nextOperator(T)(T tokens, size_t index, size_t end)
{
	size_t depth = 0;
	for (size_t i = index; i < end; i++)
	{
		auto type = tokens[i].type;
		if (type == tok!"(" || type == tok!"[" || type == tok!"{")
			depth++;
		else if (type == tok!")" || type == tok!"]" || type == tok!"}")
		{
			if (depth == 0)
				return i;
			depth--;
		}
		else if (depth == 0)
		{
			OperatorInfo ignored;
			if (operatorInfo(type, ignored))
				return i;
		}
	}
	return end;
}

/// A binary operator: what its result is made of, and how tightly it binds.
private struct OperatorInfo
{
	BinaryKind kind;
	int precedence;
}

/**
 * Whether a token is an operator the constant fold knows, and how it binds.
 *
 * The precedences are D's, lowest first, so a comparison sits below `+` and
 * `1 == 2 + 3` compares a `bool` against nothing rather than adding to one.
 */
private bool operatorInfo(IdType type, out OperatorInfo info)
{
	switch (type)
	{
	case tok!"^^": info = OperatorInfo(BinaryKind.arithmetic, 10); return true;
	case tok!"*":
	case tok!"/":
	case tok!"%": info = OperatorInfo(BinaryKind.arithmetic, 9); return true;
	case tok!"+":
	case tok!"-": info = OperatorInfo(BinaryKind.arithmetic, 8); return true;
	case tok!"~": info = OperatorInfo(BinaryKind.concatenation, 8); return true;
	case tok!"<<":
	case tok!">>":
	case tok!">>>": info = OperatorInfo(BinaryKind.shift, 7); return true;
	case tok!"&": info = OperatorInfo(BinaryKind.arithmetic, 6); return true;
	case tok!"^": info = OperatorInfo(BinaryKind.arithmetic, 5); return true;
	case tok!"|": info = OperatorInfo(BinaryKind.arithmetic, 4); return true;
	case tok!"==":
	case tok!"!=":
	case tok!"is": info = OperatorInfo(BinaryKind.comparison, 3); return true;
	case tok!"<":
	case tok!">":
	case tok!"<=":
	case tok!">=": info = OperatorInfo(BinaryKind.comparison, 2); return true;
	case tok!"&&": info = OperatorInfo(BinaryKind.logical, 1); return true;
	case tok!"||": info = OperatorInfo(BinaryKind.logical, 0); return true;
	default: return false;
	}
}

/**
 * The symbol a builtin type name stands for: the scalar types are in the
 * builtin table, while `string`, `wstring`, `dstring` and the like are aliases
 * declared in `object.d` and only reachable through the scope.
 */
private DSymbol* typeNamed(string name, Scope* completionScope, size_t cursorPosition)
{
	auto interned = internString(name);
	foreach (candidate; builtinSymbols[])
		if (candidate.name == interned)
			return cast(DSymbol*) candidate;
	auto found = completionScope.getSymbolsByNameAndCursor(interned, cursorPosition);
	return found.length > 0 ? found[0] : null;
}

/// The builtin type a literal token stands for, or null when it is not one.
private string literalTypeName(IdType type)
{
	switch (type)
	{
	case tok!"intLiteral": return "int";
	case tok!"uintLiteral": return "uint";
	case tok!"longLiteral": return "long";
	case tok!"ulongLiteral": return "ulong";
	case tok!"floatLiteral": return "float";
	case tok!"doubleLiteral": return "double";
	case tok!"realLiteral": return "real";
	case tok!"ifloatLiteral": return "ifloat";
	case tok!"idoubleLiteral": return "idouble";
	case tok!"irealLiteral": return "ireal";
	case tok!"characterLiteral": return "char";
	case tok!"stringLiteral": return "string";
	case tok!"wstringLiteral": return "wstring";
	case tok!"dstringLiteral": return "dstring";
	case tok!"true":
	case tok!"false": return "bool";
	default: return null;
	}
}

/**
 *
 */
DSymbol*[] getSymbolsByTokenChain(T)(Scope* completionScope,
	T tokens, size_t cursorPosition, CompletionType completionType)
{
	// Find the symbol corresponding to the beginning of the chain
	DSymbol*[] symbols;
	if (tokens.length == 0)
		return [];
	// Recurse in case the symbol chain starts with an expression in parens
	// e.g. (a.b!c).d
	if (tokens[0] == tok!"(")
	{
		size_t j;
		tokens.skipParen(j, tok!"(", tok!")");
		// An empty or unmatched group (`()`, `(`) has nothing to chain from -
		// falling through would otherwise look up a symbol literally named
		// "(".
		if (j <= 1)
			return [];
		symbols = getSymbolsByTokenChain(completionScope, tokens[1 .. j],
			cursorPosition, completionType);
		tokens = tokens[j + 1 .. $];
		if (tokens.length == 0) // workaround (#371)
			return [];
	}
	else if (tokens[0] == tok!".")
	{
		if (tokens.length == 1)
		{
			// Module Scope Operator
			auto s = completionScope.getScopeByCursor(1);
			return s.symbols.map!(a => a.ptr).filter!(a => a !is null).array;
		}
		else
		{
			tokens = tokens[1 .. $];
			symbols = completionScope.getSymbolsAtGlobalScope(stringToken(tokens[0]));
		}
	}
	else
		symbols = completionScope.getSymbolsByNameAndCursor(stringToken(tokens[0]), cursorPosition);

	if (symbols.length == 0)
	{
		//TODO: better bugfix for issue #368, see test case 52 or pull #371
		if (tokens.length)
			warning("Could not find declaration of ", stringToken(tokens[0]),
				" from position ", cursorPosition);
		else assert(0, "internal error");
		return [];
	}

	// If the `symbols` array contains functions, and one of them returns
	// void and the others do not, this is a property function. For the
	// purposes of chaining auto-complete we want to ignore the one that
	// returns void. This is a no-op if we are getting doc comments.
	void filterProperties() @nogc @safe
	{
		if (symbols.length == 0 || completionType == CompletionType.ddoc)
			return;
		if (symbols[0].kind == CompletionKind.functionName
			|| symbols[0].qualifier == SymbolQualifier.func)
		{
			int voidRets = 0;
			int nonVoidRets = 0;
			size_t firstNonVoidIndex = size_t.max;
			foreach (i, sym; symbols)
			{
				if (sym.type is null)
					return;
				if (sym.type.name == getBuiltinTypeName(tok!"void"))
					voidRets++;
				else
				{
					nonVoidRets++;
					firstNonVoidIndex = min(firstNonVoidIndex, i);
				}
			}
			if (voidRets > 0 && nonVoidRets > 0)
				symbols = symbols[firstNonVoidIndex .. $];
		}
	}

	filterProperties();

	// A template instance at the head of the chain -- `make!int(...)`.  The
	// explicit arguments bind the callee's parameters, so the rest of the
	// chain (and the swap below, which turns a function into its return type)
	// works on a concrete instance instead of the generic symbol.  It has to
	// happen *before* the swap, which would otherwise have replaced the
	// function with its still generic return type.
	size_t start = 1;
	if (tokens.length > 1 && tokens[1].type == tok!"!")
	{
		DSymbol*[] templateArguments;
		size_t end = 1;
		if (resolveTemplateArguments(tokens, end, completionScope, cursorPosition, templateArguments))
		{
			auto instantiated = instantiateWithArguments(symbols[0], templateArguments);
			if (instantiated !is null)
				symbols = [instantiated];
			start = end + 1;
		}
	}
	// A call with no explicit argument -- `wrap(1)`.  What is written at the
	// call site binds the callee's parameters just as `wrap!int(1)` does, so
	// the chain goes on as a concrete instance (`TD!int`) instead of the
	// generic symbol (`TD!T`), which is what `wrap(1).data` completes against.
	else if (symbols.length > 0 && tokens.length > 1 && tokens[1].type == tok!"("
		&& hasTemplateParameters(symbols[0]))
	{
		DSymbol*[] argumentTypes;
		if (resolveCallArgumentTypes(tokens, 1, completionScope, cursorPosition, argumentTypes))
		{
			auto instantiated = instantiateWithArguments(symbols[0], argumentTypes);
			if (instantiated !is null)
				symbols = [instantiated];
		}
	}

	if (shouldSwapWithType(completionType, symbols[0].kind, 0, tokens.length - 1))
	{
		// symbols is non-empty here: the length==0 case already returned above.
		if (symbols[0].type is null || symbols[0].type is symbols[0])
			return [];
		else if (symbols[0].type.kind == CompletionKind.functionName)
		{
			if (symbols[0].type.type is null)
				symbols = [];
			else
				symbols = [symbols[0].type.type];
		}
		else
			symbols = [symbols[0].type];
	}

	loop: for (size_t i = start; i < tokens.length; i++)
	{
		void skip(IdType open, IdType close)
		{
			tokens.skipParen(i, open, close);
		}

		switch (tokens[i].type)
		{
		case tok!"!":
			{
				// `expr.knownTemplated!Arg`: bind the arguments to the symbol
				// the chain resolved to so far.
				DSymbol*[] templateArguments;
				size_t end = i;
				if (symbols.length > 0
					&& resolveTemplateArguments(tokens, end, completionScope, cursorPosition, templateArguments))
				{
					auto instantiated = instantiateWithArguments(symbols[0], templateArguments);
					if (instantiated !is null)
						symbols = [instantiated];
					i = end;
				}
			}
			break;
		case tok!"int":
		case tok!"uint":
		case tok!"long":
		case tok!"ulong":
		case tok!"char":
		case tok!"wchar":
		case tok!"dchar":
		case tok!"bool":
		case tok!"byte":
		case tok!"ubyte":
		case tok!"short":
		case tok!"ushort":
		case tok!"cent":
		case tok!"ucent":
		case tok!"float":
		case tok!"ifloat":
		case tok!"cfloat":
		case tok!"idouble":
		case tok!"cdouble":
		case tok!"double":
		case tok!"real":
		case tok!"ireal":
		case tok!"creal":
		case tok!"this":
		case tok!"super":
			symbols = symbols[0].getPartsByName(internString(str(tokens[i].type)));
			if (symbols.length == 0)
				break loop;
			break;
		case tok!"identifier":
			filterProperties();

			if (symbols.length == 0)
				break loop;

			immutable identText = internString(tokens[i].text);

			// Use type instead of the symbol itself for certain symbol kinds.
			// Exception: a module that already holds `identText` as a direct
			// part - a qualified submodule import (`import pkg.sub;`
			// alongside a plain `import pkg;`) attaches `sub` straight onto
			// `pkg`'s own symbol - must be looked up on that symbol as-is;
			// redirecting through `.type` sends us into the imported
			// module's resolved scope instead, which has no member literally
			// named after the submodule, so the lookup below would find
			// nothing.
			while (symbols[0].qualifier == SymbolQualifier.func
				|| symbols[0].kind == CompletionKind.functionName
				|| (symbols[0].kind == CompletionKind.moduleName
					&& symbols[0].type !is null && symbols[0].type.kind == CompletionKind.importSymbol
					&& symbols[0].getPartsByName(identText).length == 0)
				|| symbols[0].kind == CompletionKind.importSymbol
				|| symbols[0].kind == CompletionKind.aliasName)
			{
				symbols = swapForType(symbols[0]);
				if (symbols.length == 0)
					break loop;
			}

			symbols = symbols[0].getPartsByName(identText);
			filterProperties();
			if (symbols.length == 0)
				break loop;
			if (shouldSwapWithType(completionType, symbols[0].kind, i, tokens.length - 1))
			{
				symbols = swapForType(symbols[0]);
				if (symbols.length == 0)
					break loop;
			}
			// As above: skip the redirect through .type when this symbol
			// already owns the next identifier as a direct part (a chained
			// submodule import) - there is nothing to gain by leaving its
			// own scope, and doing so loses that part.
			DSymbol*[] nextParts;
			if (i + 2 < tokens.length && tokens[i + 1].type == tok!"."
				&& tokens[i + 2].type == tok!"identifier")
				nextParts = symbols[0].getPartsByName(internString(tokens[i + 2].text));

			if ((symbols[0].kind == CompletionKind.aliasName
				|| symbols[0].kind == CompletionKind.moduleName)
				&& (completionType == CompletionType.identifiers
				|| i + 1 < tokens.length)
				&& nextParts.length == 0)
			{
				symbols = swapForType(symbols[0]);
			}
			if (symbols.length == 0)
				break loop;
			break;
		case tok!"(":
			skip(tok!"(", tok!")");
			break;
		case tok!"[":
			if (symbols.length == 0)
				break loop;
			if (symbols[0].qualifier == SymbolQualifier.array
				|| symbols[0].qualifier == SymbolQualifier.pointer)
			{
				skip(tok!"[", tok!"]");
				if (!isSliceExpression(tokens, i))
				{
					symbols = swapForType(symbols[0]);
					if (symbols.length == 0)
						break loop;
				}
			}
			else if (symbols[0].qualifier == SymbolQualifier.assocArray)
			{
				symbols = swapForType(symbols[0]);
				skip(tok!"[", tok!"]");
			}
			else
			{
				skip(tok!"[", tok!"]");
				DSymbol*[] overloads;
				if (isSliceExpression(tokens, i))
					overloads = symbols[0].getPartsByName(internString("opSlice"));
				else
					overloads = symbols[0].getPartsByName(internString("opIndex"));
				if (overloads.length > 0)
				{
					symbols = swapForType(overloads[0]);
				}
				else
					return [];
			}
			break;
		case tok!".":
			break;
		default:
			break loop;
		}
	}
	return symbols;
}

/**
 * Determines if an import is selective, whole-module, or neither.
 */
ImportKind determineImportKind(T)(T tokens)
{
	assert (tokens.length > 1);
	size_t i = tokens.length - 1;
	if (!(tokens[i] == tok!":" || tokens[i] == tok!"," || tokens[i] == tok!"."
			|| tokens[i] == tok!"identifier"))
		return ImportKind.neither;
	bool foundColon = false;
	while (true) switch (tokens[i].type)
	{
	case tok!":":
		foundColon = true;
		goto case;
	case tok!"identifier":
	case tok!"=":
	case tok!".":
	case tok!",":
		if (i == 0)
			return ImportKind.neither;
		else
			i--;
		break;
	case tok!"import":
		return foundColon ? ImportKind.selective : ImportKind.normal;
	default:
		return ImportKind.neither;
	}
	return ImportKind.neither;
}

unittest
{
	import std.stdio : writeln;

	Token[] t = [
		Token(tok!"import"), Token(tok!"identifier"), Token(tok!"."),
		Token(tok!"identifier"), Token(tok!":"), Token(tok!"identifier"), Token(tok!",")
	];
	assert(determineImportKind(t) == ImportKind.selective);
	Token[] t2;
	t2 ~= Token(tok!"else");
	t2 ~= Token(tok!":");
	assert(determineImportKind(t2) == ImportKind.neither);
	writeln("Unittest for determineImportKind() passed");
}

bool isUdaExpression(T)(ref T tokens)
{
	bool result;
	ptrdiff_t skip;
	auto i = cast(ptrdiff_t) tokens.length - 2;

	if (i < 1)
		return result;

	// skips the UDA ctor
	if (tokens[i].type == tok!")")
	{
		++skip;
		--i;
		while (i >= 2)
		{
			skip += tokens[i].type == tok!")";
			skip -= tokens[i].type == tok!"(";
			--i;
			if (skip == 0)
			{
				// @UDA!(TemplateParameters)(FunctionParameters)
				if (i > 3 && tokens[i].type == tok!"!" && tokens[i-1].type == tok!")")
				{
					skip = 1;
					i -= 2;
					continue;
				}
				else break;
			}
		}
	}

	if (skip == 0)
	{
		// @UDA!SingleTemplateParameter
		if (i > 2 && tokens[i].type == tok!"identifier" && tokens[i-1].type == tok!"!")
		{
			i -= 2;
		}

		// @UDA
		if (i > 0 && tokens[i].type == tok!"identifier" && tokens[i-1].type == tok!"@")
		{
			result = true;
		}
	}

	return result;
}

/// The storage classes a parameter symbol was declared with -- including a
/// bare `const`/`immutable`/`shared`/`inout` (`const int x`), which is a
/// parameter attribute distinct from the same words written as a type
/// constructor (`const(int) x`, part of the type instead; see
/// `parameterIsConst`'s doc in `symbol.d`) -- space-terminated so the result
/// can be prepended straight onto a formatted type. Empty for anything that
/// isn't a parameter: a plain local variable never sets these flags.
string parameterStorageClassPrefix(const DSymbol* symbol)
{
	string prefix;
	if (symbol.parameterIsShared)
		prefix ~= "shared ";
	// Mutually exclusive in the grammar (`parseParameterAttribute` is a
	// `switch`, one token consumed at a time, but D itself never allows
	// combining these on one parameter either).
	if (symbol.parameterIsImmutable)
		prefix ~= "immutable ";
	else if (symbol.parameterIsConst)
		prefix ~= "const ";
	else if (symbol.parameterIsInout)
		prefix ~= "inout ";
	if (symbol.parameterIsScope)
		prefix ~= "scope ";
	if (symbol.parameterIsReturn)
		prefix ~= "return ";
	if (symbol.parameterIsOut)
		prefix ~= "out ";
	else if (symbol.parameterIsAutoRef)
		prefix ~= "auto ref ";
	else if (symbol.parameterIsRef)
		prefix ~= "ref ";
	if (symbol.parameterIsLazy)
		prefix ~= "lazy ";
	return prefix;
}

AutocompleteResponse.Completion makeSymbolCompletionInfo(const DSymbol* symbol, char kind)
{
	auto ret = AutocompleteResponse.Completion(symbol.name, kind, null,
		symbol.symbolFile, symbol.location, symbol.doc);

	if (symbol.type)
	{
		import dsymbol.conversion.second : typeSwap;
		DSymbol* type = cast(DSymbol*) symbol.type;
		// Display the terminal type, not the next alias: `M value` where
		// `M => bar => int` completes as `int`. Only aliases are followed,
		// and only within the symbol's own file: a name imported from
		// another module (`string` from object.d, `File` from std.stdio) is
		// interface vocabulary and keeps its name. Every other kind formats
		// exactly as before.
		size_t aliasDepth = 0;
		while (type !is null && type.kind == CompletionKind.aliasName
			&& type.type !is null && aliasDepth++ < 16
			&& type.symbolFile.length > 0 && type.symbolFile == symbol.symbolFile)
			type = type.type;
		ret.typeOf = type is null ? "" : type.formatType;

		// only swap for inferred/complex types if the first format failed or we need to resolve members
		typeSwap(type);
		if (type && !ret.typeOf.length)
			ret.typeOf = type.formatType;

		if (ret.typeOf.length)
			ret.typeOf = parameterStorageClassPrefix(symbol) ~ ret.typeOf;
	}

	if ((kind == CompletionKind.variableName || kind == CompletionKind.memberVariableName) && symbol.type)
	{
		if (symbol.type.kind == CompletionKind.functionName && !ret.typeOf.length)
			ret.definition = symbol.type.name ~ ' ' ~ symbol.name;
		else
			ret.definition = ret.typeOf ~ ' ' ~ symbol.name;
	}
	else if (kind == CompletionKind.enumMember)
		ret.definition = symbol.name; // TODO: add enum value to definition string
	else if (kind == CompletionKind.structName || kind == CompletionKind.className
		|| kind == CompletionKind.unionName)
	{
		// `Name(Params)` for a templated aggregate - the parameter list as it
		// was declared, so a constrained (`T : Base`) or value (`int N`)
		// parameter comes out whole, in declaration order, without the
		// body.  A non-templated struct/union always has a `Signature` now
		// (unlike `className`, which stays templated-only - a class body was
		// never rendered in the first place), so its `.body` is what a
		// completion detail shows instead - explicitly here, not through the
		// generic `else` below, because `unionName` used to fall into that
		// branch and happened to only get the right answer by accident (a
		// non-templated union's `signature()` was null, so it fell back to
		// the old `callTip`; now that it's never null, the generic branch's
		// `renderSignature` call would wrongly render head-only).
		auto signature = symbol.signature();
		if (signature !is null && signature.templateParameters.length > 0)
			ret.definition = symbol.name.data ~ renderParenthesized(signature.templateParameters);
		else if (signature !is null)
			ret.definition = signature.body;
	}
	else
	{
		// A callable's `definition` is its signature, rendered from the parts
		// the old call tip had been joined from.
		auto signature = symbol.signature();
		if (signature !is null)
			ret.definition = renderSignature(signature).label;
	}

	// TODO: extend completion with more info such as class inheritance

	return ret;
}

bool doUFCSSearch(string beforeToken, string lastToken) pure
{
	// we do the search if they are different from eachother
	return beforeToken != lastToken;
}

// Check if we are doing an index operation calltip hint
package bool isIndexOperator(T)(T beforeTokens) pure {
	return beforeTokens.length >= 2 && beforeTokens[$ - 2] == tok!"identifier" && beforeTokens[$ - 1] == tok!"[";
}

// Check if we are doing "," calltip hint
package bool isComma(T)(T beforeTokens) pure {
	return beforeTokens.length >= 1 && beforeTokens[$ - 1] == tok!",";
}

// Check if we are doing "[" calltip hint
package bool isOpenSquareBracket(T)(T beforeTokens) pure {
	return beforeTokens.length >= 1 && beforeTokens[$ - 1] == tok!"[";
}

// Check if we are doing "(" calltip hint
package bool isOpenParen(T)(T beforeTokens) pure {
	return beforeTokens.length >= 1 && beforeTokens[$ - 1] == tok!"(";
}

// Check if we are doing a single "!" calltip hint
package bool isTemplateBang(T)(T beforeTokens) pure {
	return beforeTokens.length >= 2
		&& beforeTokens[$ - 2] == tok!"identifier"
		&& beforeTokens[$ - 1] == tok!"!";
}

// Check if we are doing "!(" calltip hint
package bool isTemplateBangParen(T)(T beforeTokens) pure {
	return beforeTokens.length >= 3
		&& beforeTokens[$ - 3] == tok!"identifier"
		&& beforeTokens[$ - 2] == tok!"!"
		&& beforeTokens[$ - 1] == tok!"(";
}
