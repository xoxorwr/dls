/**
 * The structured signature of a callable (or the template parameter list of an
 * aggregate): what `DSymbol.callTip` used to flatten into one line.
 *
 * `callTip` was built exactly once, while a module's AST was still alive, and
 * then served every consumer by being taken apart again: signature help found
 * the parameter list between brackets, completion detail found the template
 * parameter list the same way, and a function's attributes were not in there
 * at all.  A single joined string is the right shape for hover and the wrong
 * shape for everyone else.
 *
 * A `Signature` keeps the parts apart.  Each entry is a *rendered fragment*
 * rather than an AST node, because the tree it was read from does not outlive
 * the caching pass -- but walking the typed node once and keeping the pieces
 * is what lets the consumers stop re-deriving structure from punctuation.
 *
 * A `Signature` is immutable after it is built, so it may be shared; see
 * `DSymbol.extra`.
 */
module dsymbol.signature;

import dsymbol.string_interning;
import std.array : Appender, appender;

/**
 * How a `Signature` renders.
 */
enum SignatureShape : ubyte
{
	/// `[returnType ]name(templateParameters)(parameters)[ attributes]`
	callable,
	/// `name(templateParameters)` -- an aggregate's template parameter list.
	templateList,
	/// `returnType function|delegate(parameters)` -- a `T function(Args)` type.
	functionType,
}

/**
 * The parts of one signature.
 */
struct Signature
{
	/// How the parts below spell a display line.
	SignatureShape shape;

	/// The declared name, as the old call tip embedded it: `"get"`, `"this"`
	/// for a constructor, `"~this"` for a destructor, `"TD"` for an aggregate.
	istring name;

	/// Rendered return type; empty for constructors, destructors, aggregate
	/// template lists and function/delegate types.
	istring returnType;

	/// `"function"` or `"delegate"` when this describes a `T function(Args)`
	/// type rather than a declaration; empty otherwise.
	istring functionKind;

	/// Rendered function attributes in source order: `pure`, `nothrow`,
	/// `@safe`, `@nogc`, UDAs -- wherever the declaration spelled them.
	istring[] attributes;

	/// Rendered template parameters, declaration order (`T`, `K`, `T : int`).
	istring[] templateParameters;

	/// Rendered value parameters, declaration order (`int a`, `T data`, `T`).
	/// A trailing `...` varargs marker is one entry, exactly as the formatter
	/// spelled it inside the old call tip.
	istring[] parameters;

	/// An aggregate's full rendered body (`"struct Name(T) {\n    T data;\n}"`).
	/// Only `structName`/`unionName` populate this; empty for every other
	/// shape/use -- `className` still only carries the bare `templateList`
	/// head (see `symbol.d`'s `extra` doc), a class body was never flattened
	/// into a display string in the first place, and that stays out of scope
	/// here. Hover reads this directly (the callable/function-type shapes
	/// render through `renderSignature` instead, since they have no body).
	istring body;
}

/**
 * A precomputed display string behind `DSymbol.extra`, for the symbol shapes
 * that need one but not a full `Signature` -- meaning fixed by the symbol's
 * `kind`/`name`/`qualifier` the same way `Signature` itself is, read through
 * `DSymbol.renderedText()`. Three unrelated contexts share this one shape,
 * since none of them need more structure than "a string":
 *
 * - An array's dimension (`"3"` in `int[3]`, empty for a dynamic array) --
 *   the `ARRAY_SYMBOL_NAME` dummy wrapper symbol.
 * - An assoc-array's key type (`"string"` in `int[string]`) -- the
 *   `ASSOC_ARRAY_SYMBOL_NAME` dummy wrapper symbol.
 * - The module declaration line (`"module a.b.c;"`) -- the root module
 *   symbol (`kind == CompletionKind.moduleName`).
 */
struct RenderedText
{
	istring text;
}

/**
 * An alternate source file for a renamed selective import (`import m : b =
 * c;`), stashed on the `importSymbol` across the two-pass resolution in
 * `second.d` so the second pass can find where `c` actually lives. Not
 * display text -- read/written through `DSymbol.altFile()`/`setAltFile()`,
 * never rendered.
 */
struct AltFile
{
	istring path;
}

/**
 * A rendered display line plus the byte span each entry occupies in it.
 */
struct RenderedSignature
{
	/// The whole line, e.g. `"T get(T)(T data)"`.
	string label;
	/// `[start, end)` of each `templateParameters` entry within `label`.
	size_t[2][] templateSpans;
	/// `[start, end)` of each `parameters` entry within `label`.
	size_t[2][] parameterSpans;
}

/**
 * Renders a signature, recording where each parameter ended up.
 *
 * The dparse formatter already spells a parameter list as its entries joined
 * with `", "` (`format(Parameters)` in `dparse.formatter`), so assembling the
 * line here reproduces the old call tip byte for byte -- the offsets come out
 * of the assembly instead of a search for matching brackets.
 */
RenderedSignature renderSignature(const Signature* signature)
{
	RenderedSignature rendered;
	if (signature is null)
		return rendered;

	auto app = appender!string();
	final switch (signature.shape)
	{
	case SignatureShape.callable:
		if (signature.returnType.length > 0)
		{
			app.put(signature.returnType.data);
			app.put(' ');
		}
		app.put(signature.name.data);
		// Only a declaration that has a template parameter list spells one;
		// the value parameter list is always there (`int add()`).
		appendParenthesized(app, signature.templateParameters, rendered.templateSpans);
		appendList(app, signature.parameters, rendered.parameterSpans);
		foreach (attribute; signature.attributes)
		{
			app.put(' ');
			app.put(attribute.data);
		}
		break;
	case SignatureShape.templateList:
		app.put(signature.name.data);
		appendParenthesized(app, signature.templateParameters, rendered.templateSpans);
		break;
	case SignatureShape.functionType:
		if (signature.returnType.length > 0)
		{
			app.put(signature.returnType.data);
			app.put(' ');
		}
		app.put(signature.functionKind.data);
		appendList(app, signature.parameters, rendered.parameterSpans);
		break;
	}
	rendered.label = app.data;
	return rendered;
}

/**
 * Renders a parameter list on its own: `"(T, U)"`, or `""` when there is
 * none.  This is the head a templated aggregate shows (`struct TD(T)`), and
 * the `Name(Params)` a completion's `definition` is spelled with.
 */
string renderParenthesized(const istring[] items)
{
	if (items.length == 0)
		return "";
	auto app = appender!string();
	size_t[2][] spans;
	appendParenthesized(app, items, spans);
	return app.data;
}

/// Appends `"(...)"`, recording each entry's span.  Empty lists still render
/// as `"()"`: an empty value parameter list is a real part of the line.
private void appendList(ref Appender!string app, const istring[] items, ref size_t[2][] spans)
{
	app.put('(');
	foreach (i, item; items)
	{
		if (i > 0)
			app.put(", ");
		auto start = app.data.length;
		app.put(item.data);
		spans ~= [start, app.data.length];
	}
	app.put(')');
}

/// ditto, but nothing at all for an empty list.
private void appendParenthesized(ref Appender!string app, const istring[] items, ref size_t[2][] spans)
{
	if (items.length == 0)
		return;
	appendList(app, items, spans);
}
