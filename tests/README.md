# DLS test suite

End-to-end tests that drive the real `dls` binary over stdio exactly like an
editor would: LSP `Content-Length` framed JSON-RPC on stdin/stdout. There are
no third-party dependencies, only the Python 3 standard library.

## Running

```sh
python3 run_tests.py                  # whole suite
python3 run_tests.py -k completion    # only matching test ids
python3 run_tests.py --list           # list test ids
python3 run_tests.py -v               # one line per test
python3 run_tests.py --module hover   # whole modules
python3 run_tests.py --build          # 'make dls' first
python3 run_tests.py --server bin/dls # explicit binary
```

`DLS_SERVER` is honoured as an alternative to `--server`, and
`DLS_TEST_TIMEOUT` (or `--timeout`) sets the per-request timeout in seconds.
The binary defaults to `bin/dls`; build it with `make dls` when missing.

The full suite runs in a few seconds: one server process is started per test
module and shared by all tests in it, because warming DCD's module cache is by
far the most expensive part of a run.

## Layout

| File | Covers |
| --- | --- |
| `harness.py` | `LspClient`, fixture `Project`/`Doc`, position helpers, `DlsTestCase` |
| `test_initialize.py` | handshake, capabilities, shutdown, unknown methods |
| `test_completion.py` | member/module completions, prefix filtering, item shape |
| `test_hover.py` | hover on variables and type names |
| `test_definition.py` | `textDocument/definition` |
| `test_document_symbols.py` | outline symbols, kinds, ranges |
| `test_signature_help.py` | overloads, parameters, active parameter |
| `test_diagnostics.py` | the `check` command pipeline in `dls.json` |
| `test_document_sync.py` | didOpen/didChange/didSave/didClose, open-document table |
| `test_notification_robustness.py` | malformed, late or wrongly-typed notifications and unopened documents |
| `test_save_flow.py` | save cost contract: identical text must not re-parse |
| `test_imports.py` | cross-module resolution through import paths |
| `test_public_imports.py` | `public import` re-exports, private imports do not |
| `test_public_import_forwarding.py` | completions for forwarded symbols vs. cache order |
| `test_order_permutations.py` | open order x action x import shape, swept instead of sampled |
| `test_acyclic_dependencies.py` | multi-level non-circular import chains |
| `test_edit_public_imported_module.py` | editing a module other modules import |
| `test_enum_completion.py` | `.MEMBER` enum shorthand completion |
| `test_anonymous_struct.py` | named variables of anonymous struct type |
| `test_auto_declarations.py` | `auto` initializers and chained `auto` (the breadcrumb path) |
| `test_template_instantiation.py` | members of an instantiated struct template show the argument's type |
| `test_template_functions.py` | template functions: `T get(T)()` and return types built from parameters |
| `test_import_symbols.py` | `alias this`, base classes and mixin templates (import children) inside templates |

## Writing a test

```python
from harness import KIND_FIELD, DlsTestCase, find_item


class MyTests(DlsTestCase):
    PROJECT = {
        "app.d": """module app;

struct State
{
    int aaa;
}

void main()
{
    State st;
    st.aa
}
""",
    }

    def test_member_completion(self):
        doc = self.open_doc("app.d")
        items = doc.completion("st.aa")["items"]
        self.assertEqual(find_item(items, "aaa")["kind"], KIND_FIELD)
```

`DlsTestCase` writes `PROJECT` into a temporary directory, writes a `dls.json`
containing that directory as an import path (set `WRITE_DLS_JSON = False` to
test the fall-back), starts one server for the class and cleans both up
afterwards. Fixture files are rewritten on disk by `write_file()` when a test
needs a second document after startup.

Fixture writes go through `harness.write_text`, which writes a temporary file
and renames it into place. The server resolves imports by reading these files
from disk, so a plain `open(path, "w")` -- which truncates before it writes --
can be observed as an empty module. That is not a hypothetical: DCD caches the
empty read and, because of the recursion-guard leak below, never looks at the
path again. Tests that simulate a save should use `write_text` for the same
reason.

Positions come from the fixture text instead of hard-coded line/character
pairs: `doc.position("st.")` returns the LSP position right after the needle,
`offset` nudges it by characters, `occurrence` picks a later match, and
`doc.completion(...)`/`hover(...)`/`definition(...)`/`signature_help(...)` wrap
the matching request. `Doc.open()`, `Doc.change()` and `Doc.close()` drive
document sync.

Keep fixtures import-free where possible: parsing Phobos for every test file
is what makes a suite slow, and the sandbox may not have a D toolchain.

Put **one completion site per fixture file**. A statement left unterminated
because the cursor sits in the middle of it (`st.aa` with no `;`) confuses the
parser for the statements that follow, so a second completion site later in
the same file would silently resolve to nothing.

Fixtures live in one directory and are addressed by module name, so give every
module a unique name: a module cached during one test is only re-cached when
its file is opened, changed or saved again.

## Known gaps encoded in the suite

* `test_template_functions.TemplateReturnInstanceTests` and
  `.TemplateArgumentInferenceTests` are `expectedFailure`s: a return type built
  from the function's own parameter (`TD!T make(T)()` + `make!int()`) does not
  become `TD!int` -- the call's mapping is never built -- and template arguments
  are not inferred from a call's values (`wrap(1)`).  `T get(T)()` +
  `get!int()`, a method of an instantiated struct, and every `TD!int` shape do
  work.

* `test_template_instantiation.NestedTemplateInstanceTests` are
  `expectedFailure`s: an instance nested inside another instance
  (`CTX!Rectf` with a member of type `TD!T`) keeps the *outer* parameter, so
  `other.data` reports `TD!T` instead of `TD!Rectf`, the inner member reports
  `T` instead of `Rectf`, and following the chain further resolves to something
  unrelated.  The outer instantiation has to thread its mapping into the types
  of its members.
* (Template instantiation is otherwise covered: a `TD!int` used as a local
  variable, a parameter, a struct field, a call result or behind `auto` all
  report the argument's type -- see `test_template_instantiation.py`.)

* `test_auto_declarations.AutoReturnTypeTests` is an `expectedFailure`: an
  `auto` **function**'s return type is never inferred, in the same module or
  across an import, for values or for pointers (`auto w() { return g; }` --
  calling `w()` yields no type at all).  `first.d` records breadcrumbs for
  `auto x = <expr>` *variables*, but not for `auto` functions.  See
  `docs/breadcrumb-replacement.md`, where inferring it is one of the things the
  typed path is meant to make easy.
* (None for the buffer/cache split — that is deliberate, see below.)
* The `semanticTokens` handlers are routed in `main.d` but never send a
  response, so they cannot be tested with this client yet (a request would
  simply time out).
* `textDocument/definition` currently resolves variables to their type
  declaration; jumps to function definitions return an empty list.

## Deliberate behaviour pinned by tests

* `test_edit_public_imported_module.test_unsaved_edit_only_reaches_importers_on_save`
  documents the buffer/cache split: `didChange` (full text sync) refreshes only
  the server's document buffer -- every handler is handed that buffer, so
  unsaved edits are visible inside the edited file -- while DCD's module cache
  is refreshed on `didOpen` / `didSave`.  Importers therefore keep the previous
  parse of a dependency until it is saved.  Re-parsing on every keystroke was
  deliberately avoided; if that policy changes, this test is the one to update.
* `test_save_flow` pins what a save costs.  A save whose text is byte-identical
  to what DCD already cached (`CacheEntry.contentHash` + `sourceUnchanged`)
  must *not* re-parse the module, but must still notify its dependents
  (`refreshDependents`: same dependent walk, with identity pairs so stale
  symbol instances are re-pointed at the live tree, plus an unresolved-type
  retry and a modification-time re-anchor).  Measured on a small module with
  one dependent: 0.32 ms/save and 0 re-parses for identical saves, versus
  2.55 ms/save and a parse each when the text changes.  The assertions read
  the server log, because the cache work is otherwise invisible:
  `caching: <path>` is one parse, `update dep (refresh): <path>` is one
  dependent notification.  Reading the log has to wait for the harness's
  stderr reader thread (`LspClient.wait_for_log_line`): a request only orders
  the server's own work, so a log scan right after a save can be looking at
  lines the reader has not handed over yet.

## Notification and buffer hardening

`test_notification_robustness` pins the contract that the server survives
notifications no editor promises to send in a tidy order: `didSave` for a URI
that was never opened / for a document that was closed / with no `uri` at all,
`didChange` and `didClose` for unknown URIs, `didOpen` without `text` (falls
back to the file on disk) and a duplicate `didOpen` of the same URI (the buffer
table is keyed by URI and re-opening replaces the text rather than adding a
second entry).  Requests for an unopened document answer with an empty result
instead of aborting.  `didSave` also accepts the document text from the
request (`save.includeText`), so a save that arrives after the buffer was
closed still updates the cache.  `JsonShapeTests` covers the same contract for
fields whose *type* is wrong (a URI that isn't a string, a position that isn't
a number, `contentChanges` that isn't a list): each one has to read as absent,
never reach a JSON accessor that assumes it is there, and leave the document's
text alone.

## Order-independence sweep

`test_order_permutations` exists because the module-cache bugs in this area
are *ordering* bugs: `ModuleCache.cacheModule` inserting before removing only
lost completions when the origin happened to be cached after a module that
forwarded it, and the opposite order was fine the whole time.
`test_public_import_forwarding` samples that space by hand (one class for the
good order, one for the bad one); the sweep enumerates it -- for each import
shape (direct, one re-export, a two-level `public import` chain, and a diamond
with two paths to the library), every open order the editor could use, crossed
with what happens next (nothing, an unchanged save of the library or of the
forwarder, close-and-reopen of a module, a save that adds or removes a library
member -- one action per cell).

The invariant is "the answer does not depend on the ordering": every cell of a
`(shape, action)` group must produce the same completion for `w.`, and a
member a save added (or removed) must be there (or gone) in every ordering.
Cells are compared against each other plus a required/forbidden member set,
never against a hard-coded list, so the sweep does not break when DCD's
built-in struct properties (`sizeof`, `init`, ...) change, and adding a
permutation is a loop iteration rather than a new test class.

Two things about how it is written are load bearing. Every cell writes its own
uniquely named modules and closes its buffers when it is done, because the
module cache is keyed by absolute path (so a leaked module name would leave a
cell reading another cell's symbols) and the open-document table is a
server-lifetime structure the sweep would otherwise grow by four entries per
cell. And a cell writes *all* of its files before opening any of them, so the
axis under test is the order the editor opens files in -- a module that does
not exist yet when a dependent is cached is a different failure, pinned by
`EmptyModuleRecoveryTests`. After opening the documents a cell issues one
`documentSymbols` request before it acts on the files: requests are answered
after the notifications ahead of them, so that response means the server has
finished caching the cell and reading its modules from disk, and the save in
the next step cannot truncate a file the server is still reading. (Both of
those were found the hard way -- the sweep flaked in roughly one full-suite
run in five before the barrier and the atomic fixture writes were added.)

The sweep runs 204 cells in about six seconds, most of it the deep chain's 24
orders; that class therefore runs a subset of four actions (plain open,
unchanged save of the library, re-open of the outer forwarder, and a removed
member) instead of all eight, since the other three shapes already cover the
rest of the action axis.


## Regressions that were fixed (keep these tests)

* `test_public_import_forwarding` — with a two-level `public import` chain
  (`app -> m1 -> m2 -> leaf`), opening the documents as `app, m1, m2, leaf`
  used to make the app lose *all* completions for symbols reached through the
  chain, while opening the origin first worked and saving a forwarder restored
  them.  Root cause was in DCD's `ModuleCache.cacheModule`: the cache tree is
  keyed by path only and `TTree.insert` never overwrites a duplicate (the
  `overwrite` flag is ignored for duplicates stored in a full internal node),
  so `cache.insert(newEntry)` followed by `cache.remove(oldEntry)` emptied the
  entry.  The module then vanished from `cache[]`, the `update_dependen` scan
  could not find the dependents that needed rewiring, and
  `CacheAllocator.dispose(oldEntry)` freed a symbol tree that importers still
  pointed at.  The fix removes the old entry *before* inserting the new one, so
  the new entry is in place while `resolveDeferredTypes` / `update_dependen`
  run.
* `test_module_cache_side_effects` — canaries that pass before and after the
  fix: external on-disk changes are still picked up, removed members disappear
  again, circular public imports still resolve, completions survive closing and
  re-opening dependencies, every importer sees an updated dependency, repeated
  saves land on the latest content, and hover / documentSymbols / definition
  keep working after a re-cache.
* `test_imports.ImportResolutionWithoutConfigTests` (now
  `ImportPathsRequireDlsJsonTests`) — with no `dls.json`,
  `lsp_initialize_params` returned straight after falling back to
  `initializationOptions.importPaths`, skipping `dcd_add_imports`, so nothing
  in an imported module resolved.  The early return is gone; a later change
  removed the editor-specific channel altogether, so `dls.json` is now the
  only source of project import paths and the test pins that a workspace
  without one does not resolve imports.
* `test_document_sync.BufferTableCapacityTests` — open documents used to live in
  a fixed `BUFFER[128]` array (`BUFFER_LENGTH` in `dls/io.d`), and only
  `didClose` frees a slot.  A `didOpen` for the 129th document was logged
  (`buffer table is full (128 documents), ignoring ...`) and dropped without
  telling the client: it never reached `dcd_on_open`, and every request for it
  answered with an empty result until some other document closed, so an editor
  with more than 128 files open silently lost completions in them.  The table
  now starts at 64 slots and doubles, allocated through the long-lived heap
  allocator like the buffer contents themselves (`grow_buffers` in `io.d`);
  the tests open one document past the old limit, and check that `didClose`
  still frees its slot afterwards.
* `test_module_cache_side_effects.EmptyModuleRecoveryTests` —
  `ModuleCache.cacheModule` inserts the path into `recursionGuard` and then
  returns early on the `> empty` path (a zero-length file, or a zero-length
  `didSave` text) and on the failed C-header path.  It used to return without
  removing it again, so the guard rejected every later call for that path: a
  module that was empty when an importer first cached it -- the state every new
  editor buffer starts in -- could never be cached again, and its symbols never
  completed.  The way this reached users was a save: the file is truncated for
  a few microseconds while DCD resolves an import from it, the read comes back
  empty, and the module was dead for the rest of the session.  The guard is now
  released by a `scope(exit)` next to the insert, on every return path; the
  test opens the importer while the library is still empty, gives the library
  its content, and expects the symbol to complete.
