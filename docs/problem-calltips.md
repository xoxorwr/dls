# Problem: `callTip` is a lossy encoding of the AST, and `DSymbol` is a god object

Status: **not started** - problem statement and design options only. Nothing here
has been implemented. The workarounds it describes are live in the tree today
and work (tested), but they are patches over the design flaw below, not a fix
for it.

## What `callTip` is

`DSymbol.callTip` (`dcd_templates/src/dsymbol/symbol.d:411`) is a single
`istring`: one pre-rendered, human-readable line describing a symbol -
`"void foo(int a, string b)"`, `"struct TD(T) {\n    T data;\n}"`, `"this(int
x)"`. It is built exactly once, while a module's AST is still alive, by three
places in `dsymbol/conversion/first.d`:

- `formatCallTip` (line 1516) - functions: return type + name + template
  parameters + value parameters, joined into one string via
  `app.formatNode(...)` on the raw AST nodes.
- `createCallTip` (line 1072) - structs/unions: `"struct Name(TemplateParams)
  {\n    field;\n    ...\n}"`.
- `processTemplateParameters` (line 1439) - not itself a callTip builder, but
  it is what supplies the per-parameter `DSymbol` children (`typeTmpParam`,
  `aliasName`, `variableName`, `variadicTmpParam`) that some downstream code
  tries to read back out of the symbol tree instead of the string.

It has to happen right then, not later, because the AST does not survive past
that point. `cacheModule` (`dsymbol/modulecache.d:250`) parses into a
function-local `RollbackAllocator parseAllocator`, runs `FirstPass`, and
returns - at which point that allocator's memory is gone. Nothing downstream
can hold an AST node reference; whatever a symbol will ever need to show has
to already be flattened into plain, persisted data by the time `cacheModule`
returns.

## Why that's a problem

`callTip` is *the* thing multiple, structurally different features end up
built on:

- **Hover** (`dls.hover`) just prints it. That's the one place a single
  joined display string is actually the right shape.
- **Signature help** (`dcd_get_signature`, `dll.d:1403`) needs the
  *individual* parameter labels, split apart, and needs to tell a template
  parameter list apart from a value parameter list - two different
  substrings of the same callTip, distinguished only by which parenthesis
  pair they happen to be.
- **Completion detail** (`server/dls/completion.d:132`) needs just the
  template parameter list for a struct/class, again as a substring of the
  same callTip.

None of that structure survives the join. Every consumer that wants a piece
back has to reverse-engineer it from punctuation: find a `(`, find its
matching `)`, hope no other paren pair sorts earlier or later in the string,
hope `{` bumps depth to keep a function-pointer field's parens from looking
top-level. `parseParameters` (`dll.d:1579`) is ~35 lines of bracket-depth
bookkeeping whose entire job is undoing the join `formatCallTip` just did a
few call frames earlier, in the same conversion pass.

Four distinct bugs came out of exactly this, in one session:

1. A qualified submodule import's chain lookup losing a manually-attached
   child symbol to a `.type` redirect (adjacent problem, different
   mechanism, but same family of "the persisted shape doesn't have a slot
   for the specific thing being asked").
2. `createCallTip` never including a struct's own template parameter list at
   all - `struct TD(T)` hovered as `struct TD`.
3. `completion.d`'s struct/class detail extraction assuming a body always
   follows the parameter list, breaking for the template-only case where the
   definition string built by `makeSymbolCompletionInfo` has no body.
4. `dcd_get_signature` picking the *first* top-level paren group in a
   callTip, which is the template parameter list for `T get(T)(T data)`, not
   the value parameter list a call's signature help actually means to show.

Each fix added another heuristic to the reverse-engineering step. None of
them fixed the actual cause: the persisted representation throws away
structure that more than one feature needs back.

## The proposed fix is itself incomplete

The fix discussed in this session - add `istring[] parameterLabels` and
`istring[] templateParameterLabels` next to `callTip` on `DSymbol`, populated
directly from the AST walk instead of reverse-engineered from the joined
string - solves the four bugs above. It does not generalize. The moment
something wants to show a function's attributes (`pure`, `@safe`, `nothrow`,
`const`, `@nogc`, a UDA), that information isn't in `callTip` either -
`formatCallTip` never looked at `dec.attributes`/`memberFunctionAttributes`
in the first place, so there's nothing to even reverse-engineer this time.
The fix would be a *third* flat field, then a fourth for whatever comes after
that. `parameterLabels`/`templateParameterLabels` closes today's specific gap
without closing the class of gap.

## The other half: `DSymbol` is a god object

`DSymbol` (`symbol.d:144`) already carries several fields that only mean
something for one `CompletionKind` or another:

- `constantValue` (line 456) - enum members / manifest constants only.
- `typeSymbolName` (line 448) - only certain alias shapes.
- `templateArgNames` (line 478) - only an instantiated template.
- `callTip` (line 411) - only "displayable" kinds.

Adding `parameterLabels`/`templateParameterLabels` the way discussed is two
more instances of the same pattern: 32 bytes (two `istring[]` slice headers,
16 bytes each - contents are heap-allocated separately, this is just the
inline header cost) added to *every* `DSymbol`, when only
`functionName`/`structName`/`unionName`/`className` symbols would ever
populate them. A project pulling in druntime + phobos + its own source
easily caches hundreds of thousands of symbols - the overwhelming majority of
which are variables, fields, enum members, imports - none of which need
either array. That's real, if modest, dead memory on the common case to fix
the uncommon one.

The direction that avoids growing `DSymbol` further: put kind-specific data
behind one field -

```d
private void* extra;  // meaning depends on `kind`; null when unused
```

with a small heap-allocated payload struct per relevant kind (e.g. a
`CallableInfo { istring returnType; istring[] attributes; istring[]
templateParameterLabels; istring[] parameterLabels; }`), read through
accessor methods instead of direct field access. That's 8 bytes flat on
every symbol instead of 32+, and zero extra allocation for symbols that
don't need it. It is also a substantially bigger change than the two-field
version: `DSymbol` is read directly (not through accessors) in a lot of
places across `dcd_templates/src`, and every one of those becomes a
candidate for review.

## Design options, not decided

1. **Two flat fields** (`parameterLabels`, `templateParameterLabels`).
   Cheapest to implement, fixes today's four bugs, keeps growing `DSymbol`
   flat-field by flat-field. Reasonable if attributes/etc. never come up
   again in practice - unlikely given signature help is exactly where an
   editor would want to show them next.

2. **A proper `Signature` value** (`returnType`, `attributes[]`,
   `templateParameters[]`, `parameters[]`) as the source of truth, with
   `callTip` becoming one rendering *derived from* it (still persisted,
   still built once while the AST is alive - the constraint that forces
   persistence at all doesn't go away) rather than the only thing kept.
   Solves the general problem, not just parameters. Still adds to
   `DSymbol`'s footprint unless combined with (3).

3. **`extra` pointer + per-kind payload**, as sketched above. Solves the
   god-object growth. Largest blast radius: touches direct-field-access
   sites across `dcd_templates/src`, not just the call-tip builders and their
   three current consumers.

(2) and (3) are not mutually exclusive - (3) is about *where* the structured
data lives (behind a pointer, only for kinds that need it), (2) is about
*what* the structured data is (a real signature, not just parameter arrays).
The likely end state is both: an `extra`-held `Signature` per callable/
aggregate symbol, `callTip` reduced to (or replaced by) a cached rendering of
it.

## What to do with this

Not scoped or scheduled. The current workarounds (`dll.d`'s
`parseParameters` and its two closing-paren fixes, `completion.d`'s
bracket-matched detail extraction, `first.d`'s `createCallTip`
template-parameter fix) are all in place, tested, and correct for what they
handle. This document exists so the next time a feature needs structured
data DCD currently only has as a flattened string, the fix is "implement one
of the options above" instead of "add another bracket-depth loop."
