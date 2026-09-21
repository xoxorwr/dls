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

module dsymbol.conversion;

import dparse.ast;
import dparse.lexer;
import dparse.parser;
import dparse.rollback_allocator;
import dsymbol.cache_entry;
import dsymbol.conversion.first;
import dsymbol.conversion.second;
import dsymbol.conversion.third;
import dsymbol.modulecache;
import dsymbol.scope_;
import dsymbol.semantic;
import dsymbol.string_interning;
import dsymbol.symbol;
//import dsymbol.ufcs;
import std.algorithm;
import std.experimental.allocator;
import containers.hashset;
import std.conv : to;

/**
 * Used by autocompletion.
 */
ScopeSymbolPair generateAutocompleteTrees(const(Token)[] tokens,
	RollbackAllocator* parseAllocator,
	size_t cursorPosition, ref ModuleCache cache)
{
	Module m = parseModuleForAutocomplete(tokens, internString("stdin"),
		parseAllocator, cursorPosition);

	scope first = new FirstPass(m, internString("stdin"), &cache);
	first.run();

	secondPass(first.rootSymbol, first.rootSymbol, first.moduleScope, cache);

	thirdPass(first.rootSymbol, first.moduleScope, cache, cursorPosition);

    //auto ufcsSymbols = getUFCSSymbolsForCursor(first.moduleScope, tokens, cursorPosition);

	auto r = move(first.rootSymbol.acSymbol);
	typeid(SemanticSymbol).destroy(first.rootSymbol);
	return ScopeSymbolPair(r, move(first.moduleScope), m);
}

struct ScopeSymbolPair
{
	void destroy()
	{
		typeid(DSymbol).destroy(symbol);
		typeid(Scope).destroy(scope_);
		// don't destroy ufcsSymbols contents since we don't own the values
		// array itself is GC-allocated, so we just let it live
	}

	DSymbol* symbol;
	Scope* scope_;
	/// The request's syntax tree.  It lives in the caller's rollback allocator
	/// for as long as the pair does, so callers may inspect structure (for
	/// example where the cursor sits) without re-parsing anything.
	Module syntaxTree;
	//DSymbol*[] ufcsSymbols;
}

/**
 * Used by import symbol caching.
 *
 * Params:
 *     tokens = the tokens that compose the file
 *     fileName = the name of the file being parsed
 *     parseAllocator = the allocator to use for the AST
 * Returns: the parsed module
 */
Module parseModuleSimple(const(Token)[] tokens, string fileName, RollbackAllocator* parseAllocator, bool importC = false)
{
	assert (parseAllocator !is null);
	scope parser = new SimpleParser();
	parser.fileName = fileName;
	parser.tokens = tokens;
	parser.messageFunction = &doesNothing;
	parser.allocator = parseAllocator;
	parser.importC = importC;
	return parser.parseModule();
}

private:

    Module parseModuleForAutocomplete(const(Token)[] tokens, string fileName,
        RollbackAllocator* parseAllocator, size_t cursorPosition, bool importC = false)
    {
        scope parser = new AutocompleteParser();
        parser.fileName = fileName;
        parser.tokens = tokens;
        parser.messageFunction = &doesNothing;
        parser.allocator = parseAllocator;
        parser.cursorPosition = cursorPosition;
        parser.importC = importC;
        return parser.parseModule();
    }

class AutocompleteParser : Parser
{
	import dparse.stack_buffer : StackBuffer;

	/**
	 * Keep a partial assignment when the right hand side does not parse.
	 *
	 * `c = .` and `c = pick(.` are the normal state of a line being typed.
	 * The stock parser returns null for the whole assignment when the right
	 * hand side fails, `parseDeclarationsAndStatements` then rewinds to the end
	 * of the block, and completion loses the statement entirely -- which is why
	 * dot-shorthand completion had to fall back to reading tokens.  The left
	 * hand side is still meaningful when the cursor is past the operator, so
	 * keep it and skip what is left of the broken expression.
	 */
	override ExpressionNode parseAssignExpression()
	{
		import dparse.ast : AssignExpression;
		import dparse.lexer : tok;

		auto startIndex = index;
		if (!moreTokens())
			return null;

		auto ternary = parseTernaryExpression();
		if (ternary is null)
			return null;

		if (!currentIsOneOf(tok!"=", tok!">>>=", tok!">>=", tok!"<<=", tok!"+=",
				tok!"-=", tok!"*=", tok!"%=", tok!"&=", tok!"/=", tok!"|=",
				tok!"^^=", tok!"^=", tok!"~="))
		{
			ternary.tokens = tokens[startIndex .. index];
			return ternary;
		}

		auto node = allocator.make!AssignExpression;
		node.line = current().line;
		node.column = current().column;
		node.ternaryExpression = ternary;
		node.operator = advance().type;

		auto rhs = parseAssignExpression();
		if (rhs !is null)
			node.expression = rhs;
		else
			skipBrokenTail();

		node.tokens = tokens[startIndex .. index];
		return node;
	}

	/// Consume what is left of an expression that did not parse, up to the
	/// cursor, without running past the end of the statement.
	private void skipBrokenTail()
	{
		import dparse.lexer : tok;

		while (moreTokens() && !currentIsOneOf(tok!"}", tok!")", tok!"]", tok!";")
				&& current.index <= cursorPosition)
			advance();
	}

	/**
	 * Tolerate the missing `;` of the statement the cursor is in.
	 *
	 * A line being typed has no semicolon yet, so the stock implementation
	 * returns null for the whole statement whenever the cursor is inside an
	 * expression -- `paint(.Bl)` loses its call node that way, and with it the
	 * only structure completion has about the argument it is in.  Statements
	 * that end before the cursor keep the stock behaviour.
	 */
	override ExpressionStatement parseExpressionStatement(Expression expression = null)
	{
		import dparse.ast : ExpressionStatement;
		import dparse.lexer : tok;

		auto startIndex = index;
		auto node = allocator.make!ExpressionStatement;
		moveStartIndexBefore(startIndex, expression);
		node.expression = expression is null ? parseExpression() : expression;
		if (node.expression is null)
			return null;

		if (currentIs(tok!";"))
			advance();
		else if (!coversCursor(node.expression) && !onCursorLine(node.expression))
			return null;

		node.tokens = tokens[startIndex .. index];
		return node;
	}

	/// True when the cursor lies inside (or at the end of) `node`'s tokens.
	private bool coversCursor(const BaseNode node)
	{
		if (node is null || node.tokens.length == 0)
			return false;
		auto first = node.tokens[0];
		auto last = node.tokens[$ - 1];
		auto lastEnd = last.index + (last.text.length ? last.text.length : str(last.type).length);
		return first.index <= cursorPosition && cursorPosition <= lastEnd;
	}

	/// True when any of `node`'s tokens sits on the line the cursor is on --
	/// this is the statement the user is typing, whose tail may be unparseable
	/// and whose `;` is missing.
	private bool onCursorLine(const BaseNode node)
	{
		if (node is null || node.tokens.length == 0)
			return false;
		auto line = lineOfCursor();
		foreach (token; node.tokens)
			if (token.line == line)
				return true;
		return false;
	}

	private size_t lineOfCursor()
	{
		if (cursorLine == 0)
		{
			cursorLine = tokens.length ? tokens[$ - 1].line : 1;
			foreach (token; tokens)
				if (token.index >= cursorPosition)
				{
					cursorLine = token.line;
					break;
				}
		}
		return cursorLine;
	}

	/**
	 * Keep a partial comparison when the right hand side does not parse.
	 *
	 * Same story as the assignment above, for `if (c == .)` -- the stock
	 * implementation drops the whole `EqualExpression` when its right hand side
	 * fails, and with it the condition, the `if` statement and the structure
	 * completion needs.
	 */
	override EqualExpression parseEqualExpression(ExpressionNode shift = null)
	{
		import dparse.ast : EqualExpression;
		import dparse.lexer : tok;

		auto bookmark = setBookmark();
		auto checkpoint = allocator.setCheckpoint();
		auto node = super.parseEqualExpression(shift);
		if (node !is null)
			return node;

		// Only the shape the cursor is inside can be rescued: an operator was
		// consumed and its right hand side is missing.
		allocator.rollback(checkpoint);
		goToBookmark(bookmark);

		auto startIndex = index;
		auto partial = allocator.make!EqualExpression;
		moveStartIndexBefore(startIndex, shift);
		partial.left = shift is null ? parseShiftExpression() : shift;
		if (partial.left is null || !currentIsOneOf(tok!"==", tok!"!="))
			return null;

		partial.operator = advance().type;
		auto right = parseShiftExpression();
		if (right !is null)
			partial.right = right;
		else
			skipBrokenTail();

		partial.tokens = tokens[startIndex .. index];
		return partial;
	}

	/**
	 * The stock implementation gives up on the whole `Arguments` node when the
	 * closing `)` is missing, and `parseCommaSeparatedRule` throws the list
	 * away when one element does not parse.  Both happen for exactly the call
	 * the user is typing in: `foo(bar, .` used to lose its
	 * `FunctionCallExpression` entirely, so completion had no structure to
	 * read and had to count commas in the token stream instead.
	 *
	 * Keep what parsed.  The cursor is the end of the program from the
	 * parser's point of view, so an unterminated argument list is normal here.
	 */
	override Arguments parseArguments()
	{
		auto startIndex = index;
		auto node = allocator.make!Arguments;
		if (expect(tok!"(") is null)
			return null;

		if (!currentIs(tok!")"))
		{
			auto listStart = index;
			auto list = allocator.make!NamedArgumentList;
			StackBuffer items;
			size_t startLocation = current().index;
			while (moreTokens())
			{
				auto itemStart = index;
				auto startByte = current().index;
				auto item = parseNamedArgument();
				if (item is null)
				{
					// The argument did not parse (a literal the parser does
					// not accept yet, or the half-typed one the cursor is in).
					// Keep a placeholder covering the tokens that were
					// consumed: the arguments after it -- and with them the
					// parameter index completion computes -- would otherwise
					// be lost.
					skipToArgumentBoundary();
					item = makePlaceholderArgument(itemStart, startByte);
					if (item is null)
						break;
				}
				if (!items.put(item))
					return null;
				if (currentIs(tok!","))
				{
					advance();
					if (currentIsOneOf(tok!")", tok!"}", tok!"]"))
						break;
					continue;
				}
				break;
			}
			ownArray(list.items, items);
			list.startLocation = startLocation;
			if (moreTokens)
				list.endLocation = current().index;
			list.tokens = tokens[listStart .. index];
			node.namedArgumentList = list;
		}

		if (currentIs(tok!")"))
			advance();
		node.tokens = tokens[startIndex .. index];
		return node;
	}

	/// A placeholder for an argument that did not parse.
	private NamedArgument makePlaceholderArgument(size_t startIndex, size_t startByte)
	{
		if (index <= startIndex)
			return null;
		auto node = allocator.make!NamedArgument;
		node.startLocation = startByte;
		node.endLocation = index < tokens.length ? tokens[index].index : startByte;
		node.tokens = tokens[startIndex .. index];
		return node;
	}

	/// Consume the rest of an argument that failed to parse, up to the next
	/// top-level comma or the end of the argument list.
	private void skipToArgumentBoundary()
	{
		import dparse.lexer : tok;

		int depth = 0;
		while (moreTokens())
		{
			auto type = current.type;
			if (type == tok!"(" || type == tok!"[" || type == tok!"{")
				depth++;
			else if (type == tok!")" || type == tok!"]" || type == tok!"}")
			{
				if (depth == 0)
					break;
				depth--;
			}
			else if (type == tok!"," && depth == 0)
				break;
			advance();
		}
	}

	override BlockStatement parseBlockStatement()
	{
		if (!currentIs(tok!"{"))
			return null;
		// A function without a declared return type (`auto`) is typed from its
		// own `return` statements, so the body has to be parsed even though it
		// lies entirely before the cursor.  `parseFunctionDeclaration` raises
		// this for the duration of such a function.
		if (parseAutoFunctionBody)
			return super.parseBlockStatement();
		if (current.index > cursorPosition)
		{
			BlockStatement bs = allocator.make!(BlockStatement);
			bs.startLocation = current.index;
			skipBraces();
			bs.endLocation = tokens[index - 1].index;
			return bs;
		}
		immutable start = current.index;
		auto b = setBookmark();
		skipBraces();
		if (tokens[index - 1].index < cursorPosition)
		{
			abandonBookmark(b);
			BlockStatement bs = allocator.make!BlockStatement();
			bs.startLocation = start;
			bs.endLocation = tokens[index - 1].index;
			return bs;
		}
		else
		{
			goToBookmark(b);
			return super.parseBlockStatement();
		}
	}

	/**
	 * Keeps the body of a function that has no declared return type.
	 *
	 * `parseBlockStatement` above drops every block that ends before the
	 * cursor, because nothing in it can be completed; an `auto` function is the
	 * exception -- its type *is* its `return` expression, and the module cache
	 * never parses function bodies at all (`parseModuleSimple` uses a parser
	 * that skips them).  Without this the request tree is the last place the
	 * expression exists.
	 */
	override FunctionDeclaration parseFunctionDeclaration(Type type = null, bool isAuto = false,
		Attribute[] attributes = null)
	{
		immutable previous = parseAutoFunctionBody;
		if (isAuto || type is null)
			parseAutoFunctionBody = true;
		scope(exit) parseAutoFunctionBody = previous;
		return super.parseFunctionDeclaration(type, isAuto, attributes);
	}

	bool parseAutoFunctionBody;

private:
	size_t cursorPosition;
	/// Line of `cursorPosition`, computed once (see `lineOfCursor`).
	size_t cursorLine;
}

class SimpleParser : Parser
{
	override Unittest parseUnittest()
	{
		expect(tok!"unittest");
		if (currentIs(tok!"{"))
			skipBraces();
		return allocator.make!Unittest;
	}

	override MissingFunctionBody parseMissingFunctionBody()
	{
		// Unlike many of the other parsing functions, it is valid and expected
		// for this one to return `null` on valid code. Returning `null` in
		// this function means that we are looking at a SpecifiedFunctionBody
		// or ShortenedFunctionBody.
		//
		// The super-class will handle re-trying with the correct parsing
		// function.

		const bool needDo = skipContracts();
		if (needDo && moreTokens && (currentIs(tok!"do") || current.text == "body"))
			return null;
		if (currentIs(tok!";"))
			advance();
		else
			return null;
		return allocator.make!MissingFunctionBody;
	}

	override SpecifiedFunctionBody parseSpecifiedFunctionBody()
	{
		if (currentIs(tok!"{"))
			skipBraces();
		else
		{
			skipContracts();
			if (currentIs(tok!"do") || (currentIs(tok!"identifier") && current.text == "body"))
				advance();
			if (currentIs(tok!"{"))
				skipBraces();
		}
		return allocator.make!SpecifiedFunctionBody;
	}

	override ShortenedFunctionBody parseShortenedFunctionBody()
	{
		skipContracts();
		if (currentIs(tok!"=>"))
		{
			while (!currentIs(tok!";") && moreTokens)
			{
				if (currentIs(tok!"{")) // potential function literal
					skipBraces();
				else
					advance();
			}
			if (moreTokens)
				advance();
			return allocator.make!ShortenedFunctionBody;
		}
		else
		{
			return null;
		}
	}

	/**
	 * Skip contracts, and return `true` if the type of contract used requires
	 * that the next token is `do`.
	 */
	private bool skipContracts()
	{
		bool needDo;

		while (true)
		{
			if (currentIs(tok!"in"))
			{
				advance();
				if (currentIs(tok!"{"))
				{
					skipBraces();
					needDo = true;
				}
				if (currentIs(tok!"("))
					skipParens();
			}
			else if (currentIs(tok!"out"))
			{
				advance();
				if (currentIs(tok!"("))
				{
					immutable bool asExpr = peekIs(tok!";")
						|| (peekIs(tok!"identifier")
							&& index + 2 < tokens.length && tokens[index + 2].type == tok!";");
					skipParens();
					if (asExpr)
					{
						needDo = false;
						continue;
					}
				}
				if (currentIs(tok!"{"))
				{
					skipBraces();
					needDo = true;
				}
			}
			else
				break;
		}
		return needDo;
	}



}

void doesNothing(string, size_t, size_t, string, bool) {}
