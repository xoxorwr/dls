module dsymbol.type_lookup;

import dsymbol.string_interning;
import dparse.ast : BaseNode, Type;
import containers.unrolledlist;
import std.typecons : Rebindable;

/**
 * The type lookup kind.
 */
enum TypeLookupKind : ubyte
{
	inherit,
	aliasThis,
	initializer,
	/// `foreach (x; aggregate)`: the lookup is the loop variable's type, i.e.
	/// the *element* type of `aggregate` (its `.front` / `.opApply` / element
	/// type).  `astNode` is the aggregate expression, exactly as for an
	/// `initializer` lookup; the resolver applies the element step itself.
	foreachElement,
	mixinTemplate,
	varOrFunType,
	selectiveImport,
}

/**
 * information used by the symbol resolver to determine types, inheritance,
 * mixins, and alias this.
 */
struct TypeLookup
{
	this(TypeLookupKind kind)
	{
		this.kind = kind;
	}

	/// The AST node this lookup resolves from.
	///
	/// `libdparse` AST nodes are D classes, so this is a single reference (8
	/// bytes) -- not a pointer to a reference.  It is kept a class reference
	/// rather than an array of `PathNode`, because the tree *is* the typed
	/// structure: `second.d` walks it directly instead of re-deriving what
	/// `libdparse` already encoded.  See `docs/breadcrumb-replacement.md` and
	/// `PLAN2.md`.
	///
	/// For a `varOrFunType` lookup this is the declaration's `Type`; for an
	/// `initializer` lookup it is the initializer's expression node.  The
	/// referent is `const` (the passes only read it), but the field is
	/// `Rebindable` because D forbids assigning a plain `const` struct field
	/// after construction, and the producers fill the node in after the lookup
	/// is made.
	Rebindable!(const(BaseNode)) astNode;
	/// The kind of type lookup
	TypeLookupKind kind;
	/// A selective import's bound name and whether it is a rename
	/// (`import m : a;` binds `a`; `import m : b = c;` binds `c` under `b`).
	///
	/// Kept as interned data rather than an AST node on purpose: a selective
	/// import whose module is not cached yet is *deferred*, and the importing
	/// module's tree (and so any node in it) is gone by the time the deferred
	/// symbol is retried -- a node pointer here dangles (`PLAN2.md` section 5).
	istring selectiveImportName;
	/// ditto
	bool selectiveImportRenamed;
	/// Whether the declared type's template instance (`TD!int` written at the
	/// head of the type) is applied when the type resolves.
	///
	/// Only `addTypeWithContext` (a variable, a parameter, a return type) asks
	/// for it.  The old `VariableContext` capture lived in exactly that
	/// producer, so a type an alias, a base-class alias or an enum member
	/// declares keeps resolving to the *generic* symbol -- the same coverage
	/// as before this field existed.
	bool applyTypeInstance;
}
