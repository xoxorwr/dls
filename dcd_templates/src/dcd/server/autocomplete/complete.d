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

module dcd.server.autocomplete.complete;

import std.stdio;
import std.algorithm;
import std.array;
import std.conv;
import std.experimental.allocator;
import std.experimental.logger;
import std.file;
import std.path;
import std.range : assumeSorted;
import std.string;
import std.typecons;
import std.exception : enforce;

import dcd.server.autocomplete.util;

import dparse.ast : ExpressionNode, FunctionCallExpression,
	IdentifierOrTemplateInstance, Module, PrimaryExpression, UnaryExpression;
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

enum CalltipHint {
	none, // asserts false if passed into setCompletion with CompletionType.calltips
	regularArguments,
	templateArguments,
	indexOperator,
}

/**
 * Handles autocompletion
 * Params:
 *     request = the autocompletion request
 * Returns:
 *     the autocompletion response
 */
public AutocompleteResponse complete(const AutocompleteRequest request, ref ModuleCache moduleCache)
{
	import std.stdio;
	import core.memory: GC;
	scope(exit) {
		GC.collect();
		GC.minimize();
	}
	//writeln("\n\n-----");
	//scope (exit)
	//writeln("-----\n\n\n");

	warning("# complete");

	const(Token)[] tokenArray;
	auto stringCache = StringCache(request.sourceCode.length.optimalBucketCount);
	auto beforeTokens = getTokensBeforeCursor(request.sourceCode,
		request.cursorPosition, stringCache, tokenArray);

	// allows to get completion on keyword, typically "is"
	if (beforeTokens.length &&
		(isKeyword(beforeTokens[$-1].type) || isBasicType(beforeTokens[$-1].type)))
	{
		Token* fakeIdent = cast(Token*) (&beforeTokens[$-1]);
		fakeIdent.text = str(fakeIdent.type);
		fakeIdent.type = tok!"identifier";
	}

	const bool dotId = beforeTokens.length >= 2 &&
		beforeTokens[$-1] == tok!"identifier" && beforeTokens[$-2] == tok!".";

	// detects if the completion request uses the current module `ModuleDeclaration`
	// as access chain. In this case removes this access chain, and just keep the dot
	// because within a module semantic is the same (`myModule.stuff` -> `.stuff`).
	if (tokenArray.length >= 3 && tokenArray[0] == tok!"module" && beforeTokens.length &&
		(beforeTokens[$-1] == tok!"." || dotId))
	{
		const moduleDeclEndIndex = tokenArray.countUntil!(a => a.type == tok!";");
		bool beginsWithModuleName;
		// enough room for the module decl and the fqn...
		if (moduleDeclEndIndex != -1 && beforeTokens.length >= moduleDeclEndIndex * 2)
			foreach (immutable i; 0 .. moduleDeclEndIndex)
		{
			const expectIdt = bool(i & 1);
			const expectDot = !expectIdt;
			const j = beforeTokens.length - moduleDeclEndIndex + i - 1 - ubyte(dotId);

			// verify that the chain is well located after an expr or a decl
			if (i == 0)
			{
				if (!beforeTokens[j].type.among(tok!"{", tok!"}", tok!";",
					tok!"[", tok!"(", tok!",",  tok!":"))
						break;
			}
			// then compare the end of the "before tokens" (access chain)
			// with the firsts (ModuleDeclaration)
			else
			{
				// even index : must be a dot
				if (expectDot &&
					(tokenArray[i].type != tok!"." || beforeTokens[j].type != tok!"."))
						break;
				// odd index : identifiers must match
				else if (expectIdt &&
					(tokenArray[i].type != tok!"identifier" || beforeTokens[j].type != tok!"identifier" ||
					tokenArray[i].text != beforeTokens[j].text))
						break;
			}
			if (i == moduleDeclEndIndex - 1)
				beginsWithModuleName = true;
		}


		// replace the "before tokens" with a pattern making the remaining
		// parts of the completion process think that it's a "Module Scope Operator".
		if (beginsWithModuleName)
		{
			if (dotId)
				beforeTokens = assumeSorted([const Token(tok!"{"), const Token(tok!"."),
					cast(const) beforeTokens[$-1]]);
			else
				beforeTokens = assumeSorted([const Token(tok!"{"), const Token(tok!".")]);
		}
	}

	size_t parenIndex;
	auto calltipHint = getCalltipHint(beforeTokens, parenIndex);

	final switch (calltipHint) with (CalltipHint) {
		case regularArguments, templateArguments, indexOperator:

			auto result =  calltipCompletion(beforeTokens[0 .. parenIndex], tokenArray,
				request.cursorPosition, moduleCache, calltipHint);
			return result;
		case none:
			// could be import or dot completion
			if (beforeTokens.length < 2){
				break;
			}

			ImportKind kind = determineImportKind(beforeTokens);
			if (kind == ImportKind.neither)
			{
				if (beforeTokens.isUdaExpression)
					beforeTokens = beforeTokens[$ - 1 .. $];
				return dotCompletion(beforeTokens, tokenArray, request.cursorPosition,
					moduleCache);
			}
			return importCompletion(beforeTokens, kind, moduleCache);
	}
	return dotCompletion(beforeTokens, tokenArray, request.cursorPosition, moduleCache);
}

size_t findEnclosingBrace(T)(T tokens, size_t i) {
    while (i < tokens.length && i != size_t.max) {
        switch (tokens[i].type) {
            case tok!"}": i = skipParenReverseBefore(tokens, i, tok!"}", tok!"{"); break;
            case tok!")": i = skipParenReverseBefore(tokens, i, tok!")", tok!"("); break;
            case tok!"]": i = skipParenReverseBefore(tokens, i, tok!"]", tok!"["); break;
            case tok!"{": return i;
            case tok!"(":
            case tok!"[":
            case tok!";": return size_t.max;
            default:
                if (i == 0) return size_t.max;
                i--;
                break;
        }
    }
    return size_t.max;
}

auto getStructInitializerTokenChain(T)(T tokens) {
    if (tokens.length == 0)
        return (const(Token)[]).init;

    // Only suggest fields if we are at a position where a field name is expected
    if (tokens[$ - 1].type != tok!"{" && tokens[$ - 1].type != tok!",")
        return (const(Token)[]).init;

    const(Token)[][] fragments;
    
    size_t i = tokens.length - 1;
    
    while (i != size_t.max) {
        size_t braceIndex = findEnclosingBrace(tokens, i);
        if (braceIndex == size_t.max || braceIndex == 0) break;
        
        size_t prev = braceIndex - 1;
        if (tokens[prev].type == tok!"=") {
            auto expr = getExpression(tokens[0 .. prev]);
            if (expr.length > 0) {
                fragments ~= expr.release();
                const(Token)[] result;
                for (size_t j = fragments.length; j > 0; j--) {
                    result ~= fragments[j - 1];
                }
                return result;
            }
            break;
        } else if (tokens[prev].type == tok!":") {
            if (prev > 0 && tokens[prev - 1].type == tok!"identifier") {
                fragments ~= [Token(tok!"."), tokens[prev - 1]];
                i = prev - 1;
                if (i == 0) break;
                i--;
            } else {
                break;
            }
        } else {
            break;
        }
    }
    
    return (const(Token)[]).init;
}

/**
 * Handles dot completion for identifiers and types.
 * Params:
 *     beforeTokens = the tokens before the cursor
 *     tokenArray = all tokens in the file
 *     cursorPosition = the cursor position in bytes
 * Returns:
 *     the autocompletion response
 */
AutocompleteResponse dotCompletion(T)(T beforeTokens, const(Token)[] tokenArray, size_t cursorPosition, ref ModuleCache moduleCache)
{


    warning("# dotComplete");

	AutocompleteResponse response;

	// Partial symbol name appearing after the dot character and before the
	// cursor.
	string partial;

	// Type of the token before the dot, or identifier if the cursor was at
	// an identifier.
	IdType significantTokenType;

	const(Token)[] structChain;
	if (beforeTokens.length >= 1 && beforeTokens[$ - 1] == tok!"identifier")
	{
		// Set partial to the slice of the identifier between the beginning
		// of the identifier and the cursor. This improves the completion
		// responses when the cursor is in the middle of an identifier instead
		// of at the end
		auto t = beforeTokens[$ - 1];
		if (cursorPosition - t.index >= 0 && cursorPosition - t.index <= t.text.length)
		{
			partial = t.text[0 .. cursorPosition - t.index];
			// issue 442 - prevent `partial` to start in the middle of a MBC
			// since later there's a non-nothrow call to `toUpper`
			import std.utf : validate, UTFException;
			try validate(partial);
			catch (UTFException)
			{
				import std.experimental.logger : warning;
				warning("cursor positioned within a UTF sequence");
				partial = "";
			}
		}
		significantTokenType = partial.length > 0 ? tok!"identifier" : tok!"";
		beforeTokens = beforeTokens[0 .. $ - 1];

		// Dot-shorthand detection: if after stripping the partial identifier,
		// beforeTokens ends with [ ..., context_tok, . ] where context_tok is
		// =, ==, !=, (, or ,  — then we're in a dot-shorthand enum context.
		// Override significantTokenType so we enter the enum completion path.
		if (partial.length > 0 && beforeTokens.length >= 2 && beforeTokens[$ - 1] == tok!".")
		{
			auto preDoTok = beforeTokens[$ - 2].type;
			if (preDoTok == tok!"=" || preDoTok == tok!"=="
				|| preDoTok == tok!"!=" || preDoTok == tok!"("
				|| preDoTok == tok!",")
			{
				significantTokenType = preDoTok;
			}
		}
	}
	else if (beforeTokens.length >= 2 && beforeTokens[$ - 1] == tok!".")
		significantTokenType = beforeTokens[$ - 2].type;
	else
	{
		structChain = getStructInitializerTokenChain(beforeTokens);
		if (structChain.length > 0)
		{
			significantTokenType = structChain[$ - 1].type;
		}
		else
			return response;
	}
	switch (significantTokenType)
	{
	mixin(STRING_LITERAL_CASES);
		foreach (symbol; arraySymbols)
			response.completions ~= makeSymbolCompletionInfo(symbol, symbol.kind);
		goto case;
	mixin(TYPE_IDENT_CASES);
	case tok!")":
	case tok!"]":
		RollbackAllocator rba;

		ScopeSymbolPair pair = generateAutocompleteTrees(tokenArray, &rba, cursorPosition, moduleCache);
		scope(exit) pair.destroy();

		if (structChain.length == 0)
			structChain = getStructInitializerTokenChain(beforeTokens);

		auto expression = structChain.length > 0 ? structChain : getExpression(beforeTokens).release();
		auto type = structChain.length > 0 ? CompletionType.structMembers : CompletionType.identifiers;

		response.setCompletions(moduleCache, pair.scope_, expression, cursorPosition, type, CalltipHint.none, partial);
		break;
	// Dot-shorthand enum completion: when a dot is preceded by `=`, `==`, `!=`,
	// `(`, or `,`, try to infer the expected enum type from context and return
	// its members. Falls through to module scope operator if not an enum context.
	case tok!"=":
	case tok!"==":
	case tok!"!=":
	case tok!"(":
	case tok!",":
		{
			RollbackAllocator rba;
			ScopeSymbolPair pair = generateAutocompleteTrees(tokenArray, &rba, cursorPosition, moduleCache);
			scope(exit) pair.destroy();

			// The request's own tree says which construct the cursor is in;
			// see docs/breadcrumb-replacement.md.
			auto enumType = tryResolveExpectedEnumType(pair.syntaxTree, pair.scope_, cursorPosition, beforeTokens);
			if (enumType !is null)
			{
				warning("dot-shorthand: resolved expected enum type '", enumType.name, "'");
				foreach (sym; enumType.opSlice())
				{
					if (sym.name !is null && sym.name.length > 0
						&& sym.kind == CompletionKind.enumMember
						&& (partial is null || sym.name.data.startsWith(partial))
						&& sym.name[0] != '*')
					{
						response.completions ~= makeSymbolCompletionInfo(sym, sym.kind);
					}
				}
				response.completionType = CompletionType.identifiers;
				break;
			}
		}
		// Fall through to module scope operator if not an enum context
		goto moduleScopeOperator;
	//  these tokens before a "." mean "Module Scope Operator"
	case tok!":":
	case tok!"[":
	case tok!"{":
	case tok!";":
	case tok!"}":
	moduleScopeOperator:
		RollbackAllocator rba;
		ScopeSymbolPair pair = generateAutocompleteTrees(tokenArray, &rba, 1, moduleCache);
		scope(exit) pair.destroy();
		response.setCompletions(moduleCache, pair.scope_, getExpression(beforeTokens).release(),
			1, CompletionType.identifiers, CalltipHint.none, partial);
		break;
	default:
		break;
	}
	return response;
}

/**
 * Attempts to infer the expected enum type from the context surrounding a
 * dot-shorthand expression (`.MEMBER`).
 *
 * The *structure* comes from the request's syntax tree: which construct the
 * cursor sits in, and which expression's type is expected.  The expression is
 * then resolved by walking that expression node directly, falling back to the
 * token chain for node shapes the walker does not model yet.
 *
 * The function-argument case still reads the token window.  A call at
 * statement level is parsed as a declaration (`paint(.Bl)` hits D's `a(b);`
 * ambiguity) or dropped outright, so the tree holds no call node to read --
 * that is the remaining piece of this replacement, see
 * docs/breadcrumb-replacement.md.
 *
 * Params:
 *     syntaxTree = the request's tree, from generateAutocompleteTrees
 *     completionScope = the scope at the cursor position
 *     cursorPosition = byte offset of the cursor
 *     beforeTokens = tokens before the cursor, ending with [ ..., context_tok, . ]
 *
 * Returns: the DSymbol* for the enum type, or null if the context is not an enum.
 */
const(DSymbol)* tryResolveExpectedEnumType(T)(const Module syntaxTree, Scope* completionScope,
	size_t cursorPosition, T beforeTokens)
{
	import dsymbol.ast_path : CursorContextKind, findCursorContext;

	auto context = findCursorContext(syntaxTree, cursorPosition);
	final switch (context.kind)
	{
	case CursorContextKind.none:
		// Nothing in the tree at the cursor: a call statement is parsed as a
		// declaration (`paint(.Bl)`, D's `a(b);` ambiguity) or dropped
		// outright when its expression does not parse (`c = .`).  Keep the
		// token window for those shapes until the parser keeps them; see
		// docs/breadcrumb-replacement.md.
		warning("dot-shorthand: no tree node at the cursor, token fallback");
		return enumFromTokenWindow(beforeTokens, completionScope, cursorPosition);
	case CursorContextKind.assignmentRhs:
	case CursorContextKind.comparisonRhs:
		warning("dot-shorthand: expected type from the tree (", context.kind, ")");
		return enumFromExpectedExpression(context.expected, completionScope, cursorPosition);
	case CursorContextKind.callArgument:
		{
			warning("dot-shorthand: call argument from the tree");
			auto symbol = enumFromCallArgument(context.call, context.argumentIndex,
				completionScope, cursorPosition);
			if (symbol !is null)
				return symbol;
			return enumFromTokenWindow(beforeTokens, completionScope, cursorPosition);
		}
	}
}

/**
 * Resolves the expression whose type the cursor is expected to produce, and
 * returns it when that type is an enum.
 */
private const(DSymbol)* enumFromExpectedExpression(ExpressionNode expected,
	Scope* completionScope, size_t cursorPosition)
{
	import dsymbol.conversion.second : typeSwap;

	if (expected is null)
		return null;

	DSymbol* symbol = resolveExpressionSymbol(expected, completionScope, cursorPosition);
	if (symbol is null)
	{
		// A shape the node walker does not model (`a[i] = .`, `&x`, ...): the
		// structure still came from the tree, only its resolution falls back to
		// the token chain.
		warning("dot-shorthand: shape not resolved from the tree node, token chain");
		auto symbols = getSymbolsByTokenChain(completionScope, getExpression(expected.tokens),
			cursorPosition, CompletionType.identifiers);
		if (symbols.length == 0)
			return null;
		symbol = symbols[0];
	}

	typeSwap(symbol);
	if (symbol !is null && symbol.kind == CompletionKind.enumName)
		return symbol;
	return null;
}

/**
 * Resolves `lhs` tokens to a symbol and returns it when its type is an enum.
 */
private const(DSymbol)* enumFromTokenChain(T)(T lhsTokens, Scope* completionScope,
	size_t cursorPosition)
{
	import dsymbol.conversion.second : typeSwap;

	if (lhsTokens.length == 0)
		return null;

	auto expression = getExpression(lhsTokens);
	if (expression.length == 0)
		return null;

	auto symbols = getSymbolsByTokenChain(completionScope, expression,
		cursorPosition, CompletionType.identifiers);
	if (symbols.length == 0)
		return null;

	DSymbol* symbol = symbols[0];
	typeSwap(symbol);
	if (symbol !is null && symbol.kind == CompletionKind.enumName)
		return symbol;
	return null;
}

/**
 * Infers the enum type of the parameter the cursor is in, from the call node in
 * the request's tree.
 */
private const(DSymbol)* enumFromCallArgument(const FunctionCallExpression call,
	size_t argumentIndex, Scope* completionScope, size_t cursorPosition)
{
	import dsymbol.conversion.second : typeSwap;

	if (call is null)
		return null;

	DSymbol* funcSym = resolveExpressionSymbol(call.unaryExpression, completionScope, cursorPosition);
	if (funcSym is null)
		return null;

	// Follow aliases
	if (funcSym.kind == CompletionKind.aliasName && funcSym.type !is null)
		funcSym = funcSym.type;

	// For struct/class constructors, find the constructor
	if (funcSym.kind == CompletionKind.structName
		|| funcSym.kind == CompletionKind.className
		|| funcSym.kind == CompletionKind.unionName)
	{
		auto ctors = funcSym.getPartsByName(CONSTRUCTOR_SYMBOL_NAME);
		if (ctors.length == 0)
			return null;
		funcSym = ctors[0];
	}

	if (funcSym.functionParameters.length == 0 || argumentIndex >= funcSym.functionParameters.length)
		return null;

	DSymbol* paramSym = funcSym.functionParameters[argumentIndex];
	typeSwap(paramSym);
	if (paramSym !is null && paramSym.kind == CompletionKind.enumName)
		return paramSym;
	return null;
}

/**
 * Infers the expected enum type by reading the token window before the dot.
 *
 * This is the pre-AST implementation, kept as the fallback for the shapes the
 * request's tree does not hold: calls at statement level (parsed as
 * declarations, so there is no call node) and statements whose expression did
 * not parse at all.  See docs/breadcrumb-replacement.md.
 */
private const(DSymbol)* enumFromTokenWindow(T)(T beforeTokens, Scope* completionScope,
	size_t cursorPosition)
{
	import dsymbol.conversion.second : typeSwap;

	// beforeTokens ends with [ ..., context_tok, . ]
	if (beforeTokens.length < 3)
		return null;
	if (beforeTokens[$ - 1] != tok!".")
		return null;

	auto tokensBeforeDot = beforeTokens[0 .. $ - 1];
	auto contextTok = tokensBeforeDot[$ - 1].type;

	// Assignment context -- `expr = .`
	if (contextTok == tok!"=")
	{
		auto lhsTokens = tokensBeforeDot[0 .. $ - 1];
		return enumFromTokenChain(lhsTokens, completionScope, cursorPosition);
	}

	// Comparison context -- `expr == .` or `expr != .`
	if (contextTok == tok!"==" || contextTok == tok!"!=")
	{
		auto lhsTokens = tokensBeforeDot[0 .. $ - 1];
		return enumFromTokenChain(lhsTokens, completionScope, cursorPosition);
	}

	if (contextTok != tok!"(" && contextTok != tok!",")
		return null;

	// Find the opening parenthesis and count the parameter index.
	size_t openParenIdx = size_t.max;
	int paramIndex = 0;

	if (contextTok == tok!"(")
	{
		// Cursor is right after `(` -- first parameter, index 0
		openParenIdx = tokensBeforeDot.length - 1;
		paramIndex = 0;
	}
	else // contextTok == tok!","
	{
		int depth = 0;
		size_t i = tokensBeforeDot.length - 1;

		while (i > 0)
		{
			i--;
			auto tt = tokensBeforeDot[i].type;
			// `{}` counts too: a struct or array literal argument can contain
			// commas that are not parameter separators.
			if (tt == tok!")" || tt == tok!"]" || tt == tok!"}")
				depth++;
			else if (tt == tok!"[" || tt == tok!"{")
				depth--;
			else if (tt == tok!"(")
			{
				if (depth == 0)
				{
					openParenIdx = i;
					break;
				}
				depth--;
			}
			else if (tt == tok!"," && depth == 0)
				paramIndex++;
		}
		// The last comma (the one we started at) is parameter boundary too
		paramIndex++;
	}

	if (openParenIdx == size_t.max || openParenIdx == 0)
		return null;

	auto funcTokens = tokensBeforeDot[0 .. openParenIdx];
	if (funcTokens.length == 0)
		return null;

	auto expression = getExpression(funcTokens);
	if (expression.length == 0)
		return null;

	auto symbols = getSymbolsByTokenChain(completionScope, expression,
		cursorPosition, CompletionType.calltips);
	if (symbols.length == 0)
		return null;

	DSymbol* funcSym = symbols[0];

	// Follow aliases
	if (funcSym.kind == CompletionKind.aliasName && funcSym.type !is null)
		funcSym = funcSym.type;

	// For struct/class constructors, find the constructor
	if (funcSym.kind == CompletionKind.structName
		|| funcSym.kind == CompletionKind.className
		|| funcSym.kind == CompletionKind.unionName)
	{
		auto ctors = funcSym.getPartsByName(CONSTRUCTOR_SYMBOL_NAME);
		if (ctors.length == 0)
			return null;
		funcSym = ctors[0];
	}

	if (funcSym.functionParameters.length == 0)
		return null;
	if (paramIndex >= funcSym.functionParameters.length)
		return null;

	DSymbol* paramSym = funcSym.functionParameters[paramIndex];
	typeSwap(paramSym);
	if (paramSym !is null && paramSym.kind == CompletionKind.enumName)
		return paramSym;
	return null;
}

deprecated("Use `calltipCompletion` instead") alias parenCompletion = calltipCompletion;

/**
 * Resolves the symbol an expression refers to, by walking the request tree's
 * node directly.
 *
 * This replaces the old `PathNode` layer (`ast_path.buildPath` + `resolvePath`
 * plus the typed-path encoders that fed it): the expression node *is* the
 * structure, so there is nothing to serialise and nothing to re-derive.
 * `findCursorContext` already returns the expression node for the
 * dot-shorthand contexts, so the resolver reads it in place.
 *
 * Only the shapes dot-shorthand needs are modelled -- names, member chains,
 * template instances and calls; anything else (`&x`, `a[i]`, ...) returns null
 * and the caller keeps its token-window fallback.
 */
private DSymbol* resolveExpressionSymbol(const(ExpressionNode) expression,
	Scope* completionScope, size_t cursorPosition)
{
	import dsymbol.conversion.second : typeSwap;

	if (expression is null || completionScope is null)
		return null;

	auto unary = cast(const(UnaryExpression)) expression;
	if (unary is null)
		return null;

	// A member access or a template instance wraps the expression to its left.
	if (unary.identifierOrTemplateInstance !is null)
	{
		auto left = resolveExpressionSymbol(unary.unaryExpression, completionScope, cursorPosition);
		if (left is null)
			return null;
		typeSwap(left);
		if (left is null)
			return null;
		return left.getFirstPartNamed(identifierName(unary.identifierOrTemplateInstance));
	}

	if (unary.primaryExpression !is null)
		return resolvePrimarySymbol(unary.primaryExpression, completionScope, cursorPosition);

	// `foo(...)` is worth what the callee returns.
	if (unary.functionCallExpression !is null)
	{
		auto callee = resolveExpressionSymbol(unary.functionCallExpression.unaryExpression,
			completionScope, cursorPosition);
		if (callee is null)
			return null;
		typeSwap(callee);
		return callee;
	}

	return null;
}

/// Resolves `Foo` / `foo` in expression-primary position.
private DSymbol* resolvePrimarySymbol(const(PrimaryExpression) primary,
	Scope* completionScope, size_t cursorPosition)
{
	if (primary is null)
		return null;
	istring name;
	if (primary.identifierOrTemplateInstance !is null)
		name = identifierName(primary.identifierOrTemplateInstance);
	else if (primary.primary == tok!"identifier")
		name = internString(primary.primary.text);
	if (name is null || name.length == 0)
		return null;
	auto symbols = completionScope.getSymbolsByNameAndCursor(name, cursorPosition);
	return symbols.length > 0 ? symbols[0] : null;
}

/// The base name of `a` / `a!(int)`.
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
 * Handles calltip completion for function calls and some keywords
 * Params:
 *     beforeTokens = the tokens before the cursor
 *     tokenArray = all tokens in the file
 *     cursorPosition = the cursor position in bytes
 * Returns:
 *     the autocompletion response
 */
AutocompleteResponse calltipCompletion(T)(T beforeTokens,
	const(Token)[] tokenArray, size_t cursorPosition, ref ModuleCache moduleCache,
	CalltipHint calltipHint = CalltipHint.none)
{
	AutocompleteResponse response;
	immutable(ConstantCompletion)[] completions;
	auto significantTokenId = getSignificantTokenId(beforeTokens);
	switch (significantTokenId)
	{
	case tok!"__traits":
		completions = traits;
		goto fillResponse;
	case tok!"scope":
		completions = scopes;
		goto fillResponse;
	case tok!"version":
		completions = predefinedVersions;
		goto fillResponse;
	case tok!"extern":
		completions = linkages;
		goto fillResponse;
	case tok!"pragma":
		completions = pragmas;
	fillResponse:
		response.completionType = CompletionType.identifiers;
		foreach (completion; completions)
		{
			response.completions ~= AutocompleteResponse.Completion(
				completion.identifier,
				CompletionKind.keyword,
				null, null, 0, // definition, symbol path+location
				completion.ddoc
			);
		}
		break;
	case tok!"characterLiteral":
	case tok!"doubleLiteral":
	case tok!"floatLiteral":
	case tok!"identifier":
	case tok!"idoubleLiteral":
	case tok!"ifloatLiteral":
	case tok!"intLiteral":
	case tok!"irealLiteral":
	case tok!"longLiteral":
	case tok!"realLiteral":
	case tok!"uintLiteral":
	case tok!"ulongLiteral":
	case tok!"this":
	case tok!"super":
	case tok!")":
	case tok!"]":
	mixin(STRING_LITERAL_CASES);
		RollbackAllocator rba;
		ScopeSymbolPair pair = generateAutocompleteTrees(tokenArray, &rba, cursorPosition, moduleCache);
		scope(exit) pair.destroy();
		// We remove by 2 when the calltip hint is !( else remove by 1.
		auto endOffset = beforeTokens.isTemplateBangParen ? 2 : 1;
		auto expression = getExpression(beforeTokens[0 .. $ - endOffset]);

		response.setCompletions(moduleCache, pair.scope_, expression,
			cursorPosition, CompletionType.calltips, calltipHint);
		//if (!pair.ufcsSymbols.empty) {
		//	response.completions ~= pair.ufcsSymbols.map!(s => makeSymbolCompletionInfo(s, CompletionKind.ufcsName)).array;
		//	// Setting CompletionType in case of none symbols are found via setCompletions, but we have UFCS symbols.
		//	response.completionType = CompletionType.calltips;
		//}
		break;
	default:

		// TODO: perhaps finish
		//if (calltipHint == CalltipHint.regularArguments)
		//{
		//    RollbackAllocator rba;
		//    ScopeSymbolPair pair = generateAutocompleteTrees(tokenArray, &rba, cursorPosition, moduleCache);
		//    scope(exit) pair.destroy();

		//    auto s = pair.scope_.getScopeByCursor(cursorPosition);
		//    writeln(">>> yes");
		//    foreach(sym; s.symbols)
		//    {
		//        if (sym.type)
		//            writeln("  ", sym.type.name);
		//    }
		//    //foreach(it; pair.scope_.parent)
		//    //writeln();
		//} 


		break;
	}
	return response;
}

IdType getSignificantTokenId(T)(T beforeTokens)
{
	auto significantTokenId = beforeTokens[$ - 2].type;
	if (beforeTokens.isTemplateBangParen)
	{
		return beforeTokens[$ - 3].type;
	}
	return significantTokenId;
}
/**
 * Hinting what the user expects for calltip completion
 * Params:
 *   beforeTokens = tokens before the cursor
 * Returns: calltipHint based of beforeTokens
 */
CalltipHint getCalltipHint(T)(T beforeTokens, out size_t parenIndex)
{
	if (beforeTokens.length < 2)
	{
		return CalltipHint.none;
	}

	parenIndex = beforeTokens.length;
	// evaluate at comma case
	if (beforeTokens.isComma)
	{
		size_t tmp = beforeTokens.goBackToOpenParen;
		if(tmp == size_t.max){
			return CalltipHint.regularArguments;
		}
		parenIndex = tmp;
		// check if we are actually a "!("
		if (beforeTokens[0 .. parenIndex].isTemplateBangParen)
		{
			return CalltipHint.templateArguments;
		}
		else if (beforeTokens[0 .. parenIndex].isIndexOperator)
		{
			// we are inside `a[foo, bar]`, which is definitely a custom opIndex
			return CalltipHint.indexOperator;
		}
		return CalltipHint.regularArguments;
	}

	if (beforeTokens.isIndexOperator)
	{
		return CalltipHint.indexOperator;
	}
	else if (beforeTokens.isTemplateBang || beforeTokens.isTemplateBangParen)
	{
		return CalltipHint.templateArguments;
	}
	else if (beforeTokens.isOpenParen || beforeTokens.isOpenSquareBracket)
	{
		// open square bracket for literals: `foo([`
		return CalltipHint.regularArguments;
	}

	return CalltipHint.none;
}

/**
 * Provides autocomplete for selective imports, e.g.:
 * ---
 * import std.algorithm: balancedParens;
 * ---
 */
AutocompleteResponse importCompletion(T)(T beforeTokens, ImportKind kind,
	ref ModuleCache moduleCache)
in
{
	assert (beforeTokens.length >= 2);
}
do
{
	AutocompleteResponse response;
	if (beforeTokens.length <= 2)
		return response;

	size_t i = beforeTokens.length - 1;

	if (kind == ImportKind.normal)
	{

		while (beforeTokens[i].type != tok!"," && beforeTokens[i].type != tok!"import"
				&& beforeTokens[i].type != tok!"=" )
			i--;
		setImportCompletions(beforeTokens[i .. $], response, moduleCache);
		return response;
	}

	loop: while (true) switch (beforeTokens[i].type)
	{
	case tok!"identifier":
	case tok!"=":
	case tok!",":
	case tok!".":
		i--;
		break;
	case tok!":":
		i--;
		while (beforeTokens[i].type == tok!"identifier" || beforeTokens[i].type == tok!".")
			i--;
		break loop;
	default:
		break loop;
	}

	size_t j = i;
	loop2: while (j <= beforeTokens.length) switch (beforeTokens[j].type)
	{
	case tok!":": break loop2;
	default: j++; break;
	}

	if (i >= j)
	{
		warning("Malformed import statement");
		return response;
	}

	immutable string path = beforeTokens[i + 1 .. j]
		.filter!(token => token.type == tok!"identifier")
		.map!(token => cast() token.text)
		.joiner(dirSeparator)
		.text();

	string resolvedLocation = moduleCache.resolveImportLocation(path);
	if (resolvedLocation is null)
	{
		warning("Could not resolve location of ", path);
		return response;
	}
	auto symbols = moduleCache.getModuleSymbol(internString(resolvedLocation));

	import containers.hashset : HashSet;
	HashSet!string h;

	void addSymbolToResponses(const(DSymbol)* sy)
	{
		auto a = DSymbol(sy.name);
		if (!builtinSymbols.contains(&a) && sy.name !is null && !h.contains(sy.name)
				&& !sy.skipOver && sy.name != CONSTRUCTOR_SYMBOL_NAME
				&& isPublicCompletionKind(sy.kind))
		{
			response.completions ~= makeSymbolCompletionInfo(sy, sy.kind);
			h.insert(sy.name);
		}
	}

	foreach (s; symbols.opSlice().filter!(a => !a.skipOver))
	{
		if (s.kind == CompletionKind.importSymbol && s.type !is null)
			foreach (sy; s.type.opSlice().filter!(a => !a.skipOver))
				addSymbolToResponses(sy);
		else
			addSymbolToResponses(s);
	}
	response.completionType = CompletionType.identifiers;
	return response;
}

/**
 * Populates the response with completion information for an import statement
 * Params:
 *     tokens = the tokens after the "import" keyword and before the cursor
 *     response = the response that should be populated
 */
void setImportCompletions(T)(T tokens, ref AutocompleteResponse response,
	ref ModuleCache cache)
{
	response.completionType = CompletionType.identifiers;
	string partial = null;
	if (tokens[$ - 1].type == tok!"identifier")
	{
		partial = tokens[$ - 1].text;
		tokens = tokens[0 .. $ - 1];
	}
	auto moduleParts = tokens.filter!(a => a.type == tok!"identifier").map!("a.text").array();
	string path = buildPath(moduleParts);

	bool found = false;

	foreach (importPath; cache.getImportPaths())
	{
		if (importPath.isFile)
		{
			if (!exists(importPath))
				continue;

			found = true;

			auto n = importPath.baseName(".d").baseName(".di").baseName(".c");
			if (isFile(importPath) && (importPath.endsWith(".d") || importPath.endsWith(".di") || importPath.endsWith(".c"))
					&& (partial is null || n.startsWith(partial)))
				response.completions ~= AutocompleteResponse.Completion(n, CompletionKind.moduleName, null, importPath, 0);
		}
		else
		{
			string p = buildPath(importPath, path);
			if (!exists(p))
				continue;

			found = true;

			try foreach (string name; dirEntries(p, SpanMode.shallow))
			{
				import std.path: baseName;
				if (name.baseName.startsWith(".#"))
					continue;

				auto n = name.baseName(".d").baseName(".di").baseName(".c");
				if (isFile(name) && (name.endsWith(".d") || name.endsWith(".di") || name.endsWith(".c"))
					&& (partial is null || n.startsWith(partial)))
					response.completions ~= AutocompleteResponse.Completion(n, CompletionKind.moduleName, null, name, 0);
				else if (isDir(name))
				{
					if (n[0] != '.' && (partial is null || n.startsWith(partial)))
					{
						immutable packageDPath = buildPath(name, "package.d");
						immutable packageDIPath = buildPath(name, "package.di");
						immutable packageD = exists(packageDPath);
						immutable packageDI = exists(packageDIPath);
						immutable kind = packageD || packageDI ? CompletionKind.moduleName : CompletionKind.packageName;
						immutable file = packageD ? packageDPath : packageDI ? packageDIPath : name;
						response.completions ~= AutocompleteResponse.Completion(n, kind, null, file, 0);
					}
				}
			}
			catch(FileException)
			{
				warning("Cannot access import path: ", importPath);
			}
		}
	}
	if (!found)
		warning("Could not find ", moduleParts);
}

/**
 *
 */
void setCompletions(T)(ref AutocompleteResponse response, ref ModuleCache cache,
	Scope* completionScope, T tokens, size_t cursorPosition,
	CompletionType completionType, CalltipHint callTipHint = CalltipHint.none,
	string partial = null)
{
	static void addSymToResponse(const(DSymbol)* s, ref AutocompleteResponse r, string p, Scope* completionScope, size_t[] circularGuard = [], CompletionType completionType = CompletionType.identifiers)
	{
		if (circularGuard.canFind(cast(size_t) s))
			return;

		if (s.qualifier == SymbolQualifier.pointer && s.type !is null)
		{
			addSymToResponse(s.type, r, p, completionScope, circularGuard ~ (cast(size_t) s), completionType);
		}

		if (s.kind == CompletionKind.aliasName && s.type !is null)
		{
			addSymToResponse(s.type, r, p, completionScope, circularGuard ~ (cast(size_t) s), completionType);
			return;
		}

        if (completionType == CompletionType.structMembers)
            warning("addSymToResponse: processing symbol '", s.name, "' kind: ", s.kind, " partial: '", p, "'");

		foreach (sym; s.opSlice())
		{
            if (completionType == CompletionType.structMembers)
                warning("  checking sym: '", sym.name, "' kind: ", sym.kind, " qual: ", sym.qualifier);

			if (sym.name !is null && sym.name.length > 0 && isPublicCompletionKind(sym.kind)
				&& !sym.generated
				&& (p is null ? true : sym.name.data.startsWith(p))
				&& !r.completions.canFind!((a) {
					// this filters out similar symbols
					// this is needed because similar symbols can exist do to version conditionals
					// fast check first, only compare full definition if it matches
					bool same = a.identifier == sym.name && a.kind == sym.kind;
					if (same) {
						auto info = makeSymbolCompletionInfo(sym, sym.kind);
						if (info.definition != a.definition) same = false;
					}
					return same;
				})
				&& sym.name[0] != '*'
				&& mightBeRelevantInCompletionScope(sym, completionScope))
			{
				if (completionType == CompletionType.structMembers)
				{
					if (sym.kind == CompletionKind.memberVariableName && sym.qualifier != SymbolQualifier.templated)
					{
						r.completions ~= makeSymbolCompletionInfo(sym, sym.kind);
                        warning("    ADDED struct member: ", sym.name);
					}
                    else
                    {
                        warning("    FILTERED struct member (kind/qualifier): ", sym.name, " kind: ", sym.kind, " qual: ", sym.qualifier);
                    }
				}
				else
				{
					r.completions ~= makeSymbolCompletionInfo(sym, sym.kind);
				}
			}
            else if (completionType == CompletionType.structMembers)
            {
                warning("    REJECTED sym: ", sym.name, 
                    " nameNull: ", sym.name is null, 
                    " publicKind: ", isPublicCompletionKind(sym.kind),
                    " startsWith: ", (p is null ? true : sym.name.data.startsWith(p)),
                    " hidden: ", (sym.name.length > 0 && sym.name[0] == '*'),
                    " relevant: ", mightBeRelevantInCompletionScope(sym, completionScope)
                );
            }

			if (sym.kind == CompletionKind.importSymbol && !sym.skipOver && sym.type !is null)
				addSymToResponse(sym.type, r, p, completionScope, circularGuard ~ (cast(size_t) s), completionType);
		}
	}

	// Handle the simple case where we get all symbols in scope and filter it
	// based on the currently entered text.
	if (partial !is null && tokens.length == 0)
	{
		auto currentSymbols = completionScope.getSymbolsInCursorScope(cursorPosition);
		foreach (s; currentSymbols.filter!(a => isPublicCompletionKind(a.kind)
				&& a.name.data.startsWith(partial)
				&& !response.completions.canFind!((r) {
					// this filters out similar symbols
					// this is needed because similar symbols can exist do to version conditionals
					// fast check first, only compare full definition if it matches
					bool same = (r.identifier == a.name && r.kind == a.kind && r.symbolFilePath == a.symbolFile);
					if (same) {
						auto info = makeSymbolCompletionInfo(a, a.kind);
						if (info.definition != r.definition) same = false;
					}
					return same;
				})
				&& mightBeRelevantInCompletionScope(a, completionScope)))
		{
			response.completions ~= makeSymbolCompletionInfo(s, s.kind);
		}
		response.completionType = CompletionType.identifiers;


        //warning("# partial: ", partial," : ", cursorPosition);
        //foreach(s; currentSymbols[])
        //{
        //	if (s.name == "fs")
        //	warning("  ", s.name," ", s.type.name);
        //  //if (s.ptr.name == "Data")
        //    //warning(s.name);
        //  {
        //      //foreach(it; s.opSlice())
        //      //    warning("  ", it.name," ", it.kind," ",it.qualifier);
        //  }
        //}

		return;
	}
	// "Module Scope Operator" : filter module decls
	else if (tokens.length == 1 && tokens[0] == tok!".")
	{
		auto currentSymbols = completionScope.getSymbolsInCursorScope(cursorPosition);
		foreach (s; currentSymbols.filter!(a => isPublicCompletionKind(a.kind)
				// TODO: for now since "module.partial" is transformed into ".partial"
				// we cant put the imported symbols that should be in the list.
				&& a.kind != CompletionKind.importSymbol
				&& a.kind != CompletionKind.dummy
				&& a.symbolFile == "stdin"
				&& (partial !is null && a.name.data.startsWith(partial)
					|| partial is null)
				&& mightBeRelevantInCompletionScope(a, completionScope)))
		{
			response.completions ~= makeSymbolCompletionInfo(s, s.kind);
		}
		response.completionType = CompletionType.identifiers;
		return;
	}

	if (tokens.length == 0)
		return;




	DSymbol*[] symbols = getSymbolsByTokenChain(completionScope, tokens,
		cursorPosition, completionType);

    if (completionType == CompletionType.structMembers)
    {
        warning("structMembers completion requested for tokens: ", tokens.map!(t => t.text is null ? str(t.type) : t.text));
        if (symbols.length > 0)
            warning("Found symbol: ", symbols[0].name, " kind: ", symbols[0].kind);
        else
            warning("No symbol found for token chain");
    }

	// If calltipHint is templateArguments we ensure that the symbol is also templated
	if (callTipHint == CalltipHint.templateArguments
		&& symbols.length >= 1
		&& symbols[0].qualifier != SymbolQualifier.templated)
	{
		return;
	}

	if (symbols.length == 0)
	{
		warning("setCompletions: symbols.length == 0");
		return;
	}

	warning("setCompletions: symbols[0] = ", symbols[0].name, " kind:", symbols[0].kind, " type:", symbols[0].type ? symbols[0].type.name : "null");

	if (completionType == CompletionType.identifiers || completionType == CompletionType.structMembers)
	{
		while (symbols[0].qualifier == SymbolQualifier.func
				|| symbols[0].kind == CompletionKind.functionName
				|| symbols[0].kind == CompletionKind.importSymbol
				|| symbols[0].kind == CompletionKind.aliasName)
		{
			symbols = symbols[0].type is null || symbols[0].type is symbols[0] ? []
				: [symbols[0].type];
			if (symbols.length == 0)
				return;
		}
		warning("setCompletions: completing with symbols[0] = ", symbols[0].name, " kind:", symbols[0].kind, " parts:", symbols[0].opSlice().length);
		//if (symbols[0].opSlice().length == 0)
		//{
		//	foreach (it; cache.cache[])
		//	{
		//		if (symbols[0].name.data == "SceneTest") {
		//			warning(" >>", it.symbol.name);
		//		}
		//	}
		//}

		addSymToResponse(symbols[0], response, partial, completionScope, [], completionType);
		response.completionType = completionType;
	}
	else if (completionType == CompletionType.calltips)
	{
		enforce(callTipHint != CalltipHint.none, "Make sure to have a properly defined calltipHint!");
		//trace("Showing call tips for ", symbols[0].name, " of kind ", symbols[0].kind);
		if (symbols[0].kind != CompletionKind.functionName
			&& symbols[0].callTip is null)
		{
			if (symbols[0].kind == CompletionKind.aliasName)
			{
				if (symbols[0].type is null || symbols[0].type is symbols[0])
					return;
				symbols = [symbols[0].type];
			}
			if (symbols[0].kind == CompletionKind.variableName)
			{
				auto dumb = symbols[0].type;
				if (dumb !is null)
				{
					if (dumb.kind == CompletionKind.functionName)
					{
						symbols = [dumb];
						goto setCallTips;
					}
					if (callTipHint == CalltipHint.indexOperator)
					{
						auto index = dumb.getPartsByName(internString("opIndex"));
						if (index.length > 0)
						{
							symbols = index;
							goto setCallTips;
						}
					}
					auto call = dumb.getPartsByName(internString("opCall"));
					if (call.length > 0)
					{
						symbols = call;
						goto setCallTips;
					}
				}
			}
			if (symbols[0].kind == CompletionKind.structName
				|| symbols[0].kind == CompletionKind.className)
			{
				if (callTipHint == CalltipHint.templateArguments)
				{
					response.completionType = CompletionType.calltips;
					response.completions = [generateStructConstructorCalltip(symbols[0], callTipHint)];
					return;
				}

				//Else we do calltip for regular arguments
				auto constructor = symbols[0].getPartsByName(CONSTRUCTOR_SYMBOL_NAME);
				if (constructor.length == 0)
				{
					// Build a call tip out of the struct fields
					if (symbols[0].kind == CompletionKind.structName)
					{
						response.completionType = CompletionType.calltips;
						response.completions = [generateStructConstructorCalltip(symbols[0], callTipHint)];
						return;
					}
				}
				else
				{
					symbols = constructor;
					goto setCallTips;
				}
			}
		}
	setCallTips:
		response.completionType = CompletionType.calltips;
		foreach (symbol; symbols)
		{
			if (symbol.kind != CompletionKind.aliasName && symbol.callTip !is null)
			{
				auto completion = makeSymbolCompletionInfo(symbol, char.init);
				// TODO: put return type
				response.completions ~= completion;
			}
		}
	}
}

bool mightBeRelevantInCompletionScope(const DSymbol* symbol, Scope* scope_)
{
	import dparse.lexer : tok;

	if (symbol.protection == tok!"private" &&
		!scope_.hasSymbolRecursive(symbol))
	{
		// scope is the scope of the current file so if the symbol is not in there, it's not accessible
		return false;
	}

	import std.stdio;

	//writeln(symbol.name, scope_.version_, scope_.parent);

	return true;
}


AutocompleteResponse.Completion generateStructConstructorCalltip(
	const DSymbol* symbol,
	CalltipHint calltipHint = CalltipHint.regularArguments
)
in
{
	if (calltipHint == CalltipHint.regularArguments)
	{
		assert(symbol.kind == CompletionKind.structName);
	}
}
do
{
	string generatedStructConstructorCalltip = calltipHint == CalltipHint.regularArguments ? "this(" : symbol.name ~ "!(";
	auto completionKindFilter = calltipHint == CalltipHint.regularArguments ? CompletionKind.variableName : CompletionKind.typeTmpParam;
	const(DSymbol)*[] fields =
	symbol.opSlice().filter!(a => a.kind == completionKindFilter).map!(a => cast(const(DSymbol)*) a).array();
	fields.sort!((a, b) => a.location < b.location);
	foreach (i, field; fields)
	{
		if (field.kind != completionKindFilter)
			continue;
		i++;
		if (field.type !is null && calltipHint == CalltipHint.regularArguments)
		{
			generatedStructConstructorCalltip ~= field.type.name;
			generatedStructConstructorCalltip ~= " ";
		}
		generatedStructConstructorCalltip ~= field.name;
		if (i < fields.length)
			generatedStructConstructorCalltip ~= ", ";
	}
	generatedStructConstructorCalltip ~= ")";
	auto completion = makeSymbolCompletionInfo(symbol, char.init);
	completion.identifier = calltipHint == CalltipHint.regularArguments ? "this" : symbol.name;
	completion.definition = generatedStructConstructorCalltip;
	completion.typeOf = symbol.name;
	return completion;
}
