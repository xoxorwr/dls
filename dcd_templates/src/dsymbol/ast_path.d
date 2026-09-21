/**
 * Structural (AST based) model of the construct a completion request is
 * anchored on.
 *
 * The completion request already carries the buffer text, and
 * `generateAutocompleteTrees` already parses it with `AutocompleteParser`,
 * which stops at the cursor and synthesises skeleton nodes past it.  That tree
 * is alive for the whole request, so the construct around the cursor can be
 * read instead of re-derived by scanning tokens backwards.
 *
 * `findCursorContext` reports which construct the cursor sits in (assignment
 * RHS, comparison RHS, or an argument of a call) and hands the resolver the
 * pieces it needs.  The expression nodes it returns are resolved in place --
 * there is no serialised path here anymore; the `PathNode` layer that used to
 * stand between the tree and the resolver has been removed (see
 * `docs/breadcrumb-replacement.md` and `PLAN2.md`).
 */
module dsymbol.ast_path;

import dparse.ast;
import dparse.lexer : Token, str, tok;

/**
 * What the cursor sits in, for dot-shorthand completion.
 */
enum CursorContextKind : ubyte
{
	none,
	/// `lhs = .MEMBER`
	assignmentRhs,
	/// `lhs == .MEMBER` / `lhs != .MEMBER`
	comparisonRhs,
	/// `callee(arg, .MEMBER`
	callArgument,
}

struct CursorContext
{
	CursorContextKind kind = CursorContextKind.none;
	/// The expression whose type is expected (assignment/comparison).
	ExpressionNode expected;
	/// The call the cursor is an argument of (`callArgument`).
	FunctionCallExpression call;
	/// Zero based parameter index (`callArgument`).
	size_t argumentIndex;
}

/// Byte offset just past `token`'s last token, or `token.index` when the
/// span is empty.  Token text is unset for static tokens, so fall back to the
/// spelling of the token type.
size_t tokenEnd(const(Token) token, size_t fallback)
{
	if (token.type == tok!"")
		return fallback;
	auto len = token.text.length;
	if (len == 0)
		len = str(token.type).length;
	return token.index + len;
}

/// True when `node`'s last token ends strictly before `cursor`.
bool endsBefore(const BaseNode node, size_t cursor)
{
	if (node is null || node.tokens.length == 0)
		return false;
	return tokenEnd(node.tokens[$ - 1], node.tokens[$ - 1].index) < cursor;
}

/// True when `cursor` is at or after the last *token start* of `node`.
bool startsAtOrBeforeCursor(const BaseNode node, size_t cursor)
{
	if (node is null || node.tokens.length == 0)
		return false;
	return node.tokens[$ - 1].index <= cursor;
}

/**
 * Walks the request's tree and records the innermost construct at the cursor.
 */
private class CursorContextVisitor : ASTVisitor
{
	this(size_t cursor, size_t cursorLine)
	{
		this.cursor = cursor;
		this.cursorLine = cursorLine;
	}

	// The base class carries the default traversal; our overrides only add the
	// constructs we care about and hand the rest back to it.
	alias visit = ASTVisitor.visit;

	override void visit(const AssignExpression n)
	{
		if (n.ternaryExpression !is null && startsAtOrBeforeCursor(n.ternaryExpression, cursor)
				&& onCursorLine(n))
			record(CursorContextKind.assignmentRhs, n.ternaryExpression, n);
		super.visit(n);
	}

	override void visit(const EqualExpression n)
	{
		if (n.left !is null && startsAtOrBeforeCursor(n.left, cursor) && onCursorLine(n))
			record(CursorContextKind.comparisonRhs, n.left, n);
		super.visit(n);
	}

	override void visit(const FunctionCallExpression n)
	{
		if (n.arguments !is null && onCursorLine(n))
		{
			auto args = argsOf(n);
			size_t index = 0;
			foreach (arg; args)
			{
				if (arg is null || arg.tokens.length == 0)
					continue;
				// The argument the cursor is in ends *at* the cursor (the
				// parser stopped there), so only arguments that end strictly
				// before it count towards the parameter index.
				if (endsBefore(arg, cursor))
					index++;
			}
			record(CursorContextKind.callArgument, null, n, index);
		}
		super.visit(n);
	}

	/// True when one of `node`'s tokens is on the cursor's line: this is the
	/// construct being typed, not one that merely ends before the cursor.
	private bool onCursorLine(const BaseNode node)
	{
		if (node is null || node.tokens.length == 0)
			return false;
		foreach (token; node.tokens)
			if (token.line == cursorLine)
				return true;
		return false;
	}

	private const(NamedArgument)[] argsOf(const FunctionCallExpression n)
	{
		if (n.arguments is null || n.arguments.namedArgumentList is null)
			return null;
		return n.arguments.namedArgumentList.items;
	}

	private void record(CursorContextKind kind, const(ExpressionNode) expected,
		const BaseNode node, size_t index = 0)
	{
		auto span = node.tokens.length
			? node.tokens[$ - 1].index - node.tokens[0].index
			: size_t.max;
		auto contains = containsCursor(node);
		// A construct the cursor is *inside* beats one that merely precedes it:
		// in `make().member = .` the call is narrower than the assignment but
		// the expected type comes from the assignment's left hand side.  Within
		// a tier the innermost (narrowest) construct wins.
		if (result.kind != CursorContextKind.none)
		{
			if (recordedContains && !contains)
				return;
			if (contains == recordedContains && span >= width)
				return;
		}
		recordedContains = contains;
		width = span;
		result.kind = kind;
		// The visitor walks a const view of the tree; the context keeps plain
		// references because the tree outlives the visitor (it lives in the
		// request's rollback allocator).
		result.expected = cast(ExpressionNode) expected;
		result.call = cast(FunctionCallExpression) node;
		result.argumentIndex = index;
	}

	/// True when the cursor sits inside `node`'s token span.
	private bool containsCursor(const BaseNode node)
	{
		if (node is null || node.tokens.length == 0)
			return false;
		auto first = node.tokens[0];
		auto last = node.tokens[$ - 1];
		auto lastEnd = last.index + (last.text.length ? last.text.length : str(last.type).length);
		return first.index <= cursor && cursor <= lastEnd;
	}

private:
	size_t cursor;
	/// Line of `cursor` in the request's source; only constructs on it are
	/// considered, so a construct that merely precedes the cursor (one on an
	/// earlier line, or one left over from a failed parse) cannot win.
	size_t cursorLine;
	size_t width = size_t.max;
	/// Whether the recorded construct contains the cursor (see `record`).
	bool recordedContains;
	CursorContext result;
}

/**
 * Returns the construct the cursor sits in.  `kind == none` means the cursor
 * is not in one of the modelled contexts.
 */
CursorContext findCursorContext(const Module mod, size_t cursor)
{
	auto visitor = new CursorContextVisitor(cursor, lineAt(mod.tokens, cursor));
	mod.accept(visitor);
	return visitor.result;
}

/// Line of `cursor` in `tokens`, 1-based like `Token.line`.
private size_t lineAt(const(Token)[] tokens, size_t cursor)
{
	if (tokens.length == 0)
		return 1;
	size_t line = tokens[$ - 1].line;
	foreach (token; tokens)
		if (token.index >= cursor)
		{
			line = token.line;
			break;
		}
	return line;
}
