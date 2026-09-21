"""Order-independence of the module cache, swept instead of sampled.

Every ``didOpen`` / ``didSave`` re-caches the module and re-points the
dependents that hold a pointer into the old symbol tree (see the
module-cache notes in ``tests/README.md``).  Bugs in that machinery are
*ordering* bugs by construction: ``ModuleCache.cacheModule`` inserting before
removing only lost completions when the origin happened to be cached after a
module that forwarded it, while the opposite order was fine the whole time.

``test_public_import_forwarding`` samples that space by hand -- one class for
the good order, one for the bad one.  This module enumerates it.  Each cell is
one point of a three-axis cross product:

* **import shape** -- how the app reaches the library: directly, through one
  re-exporting module, through a two-level ``public import`` chain, or along
  two paths at once.
* **open order** -- every permutation of the modules the editor opens.
* **action** -- what happens after opening: nothing, an unchanged save of the
  library or of the forwarder, close-and-reopen of a module, or a save that
  adds / removes a library member.

All cells of a ``(shape, action)`` group must agree: the completion for ``w.``
has to carry the same members whichever order the modules were opened in, and
a member a save added (or removed) must be there (or gone) in every ordering.
Cells are compared against each other plus a required/forbidden member set, so
the assertions do not depend on DCD's built-in list of struct properties
(``sizeof``, ``init``, ...).

Each shape gets its own test class, and therefore its own server; within a
class every cell writes uniquely named modules and closes its buffers when it
is done.  Closing is not just hygiene: the open-document table is a
server-lifetime structure (see ``test_document_sync.BufferTableCapacityTests``)
and the module cache is keyed by path, so a cell that leaked either would have
later cells working with hundreds of leftovers.
"""

import itertools

from harness import DlsTestCase, labels, write_text


LEAF = "module {module};\n\nstruct Widget\n{{\n{members}}}\n"
FORWARDER = "module {module};\n\npublic import {target};\n"
APPLICATION = (
    "module {module};\n\n{imports}\nvoid main()\n{{\n    Widget w;\n    w.\n}}\n"
)

SIZE = "    int size;\n"
EXTRA = "    int extra;\n"

#: role -> how to build that module.  ``("leaf",)`` is the library,
#: ``("forwarder", role)`` re-exports another role, and
#: ``("application", [roles])`` imports what it is given and holds the single
#: completion site (one per fixture file, per tests/README.md).
SHAPES = {
    "direct": {
        "leaf": ("leaf",),
        "app": ("application", ["leaf"]),
    },
    "forward": {
        "leaf": ("leaf",),
        "m1": ("forwarder", "leaf"),
        "app": ("application", ["m1"]),
    },
    "chain": {
        "leaf": ("leaf",),
        "m2": ("forwarder", "leaf"),
        "m1": ("forwarder", "m2"),
        "app": ("application", ["m1"]),
    },
    "diamond": {
        "leaf": ("leaf",),
        "m1": ("forwarder", "leaf"),
        "app": ("application", ["m1", "leaf"]),
    },
}

#: action -> what it does plus what the completion at ``w.`` must look like
#: afterwards.  ``save`` / ``reopen`` name a role; ``members`` rewrites the
#: library's struct body (an editor save that changes the file).
ACTIONS = {
    "open-only": {"required": {"size"}, "forbidden": {"extra"}},
    "identity-save-leaf": {"save": "leaf", "required": {"size"}, "forbidden": {"extra"}},
    "identity-save-forwarder": {"save": "m1", "required": {"size"}, "forbidden": {"extra"}},
    "close-reopen-leaf": {"reopen": "leaf", "required": {"size"}, "forbidden": {"extra"}},
    "close-reopen-forwarder": {"reopen": "m1", "required": {"size"}, "forbidden": {"extra"}},
    "close-reopen-entry": {"reopen": "app", "required": {"size"}, "forbidden": {"extra"}},
    "edit-leaf-add-member": {
        "members": SIZE + EXTRA,
        "required": {"size", "extra"},
        "forbidden": set(),
    },
    "edit-leaf-remove-member": {
        "members": EXTRA,
        "required": {"extra"},
        "forbidden": {"size"},
    },
}


def build_project(shape: str, names: dict[str, str], members: str = SIZE) -> dict[str, str]:
    """Return ``role -> text`` for one cell of ``shape``."""
    texts = {}
    for role, spec in SHAPES[shape].items():
        if spec[0] == "leaf":
            texts[role] = LEAF.format(module=names[role], members=members)
        elif spec[0] == "forwarder":
            texts[role] = FORWARDER.format(module=names[role], target=names[spec[1]])
        else:
            imports = "".join(f"import {names[target]};\n" for target in spec[1])
            texts[role] = APPLICATION.format(module=names[role], imports=imports)
    return texts


def action_roles(spec: dict) -> set:
    """The roles an action touches, so shapes missing them can skip it."""
    roles = {spec[key] for key in ("save", "reopen") if key in spec}
    if "members" in spec:
        roles.add("leaf")
    return roles


class OrderingInvariantMixin:
    """Sweeps one import shape; subclasses only set ``SHAPE`` and ``PROJECT``."""

    SHAPE = ""
    #: Optional subset of ``ACTIONS``; ``None`` runs every applicable action.
    ACTIONS_TO_RUN = None

    def actions(self) -> list:
        roles = set(SHAPES[self.SHAPE])
        return [
            action
            for action, spec in ACTIONS.items()
            if action_roles(spec) <= roles
            and (self.ACTIONS_TO_RUN is None or action in self.ACTIONS_TO_RUN)
        ]

    def save(self, doc, text: str) -> None:
        """Simulate an editor save: the file hits the disk, then the LSP."""
        write_text(doc.path, text)
        doc.change(text)
        self.client.did_save(doc.uri)

    def apply_action(self, spec: dict, names: dict, docs: dict, texts: dict) -> None:
        if "save" in spec:
            self.save(docs[spec["save"]], texts[spec["save"]])
        elif "reopen" in spec:
            doc = docs[spec["reopen"]]
            doc.close()
            doc.open()
        elif "members" in spec:
            self.save(docs["leaf"], LEAF.format(module=names["leaf"], members=spec["members"]))

    def run_cell(self, cell: int, order: tuple, action: str) -> frozenset:
        shape = self.SHAPE
        names = {role: f"{shape}_{cell}_{role}" for role in SHAPES[shape]}
        texts = build_project(shape, names)

        docs: dict = {}
        opened = []
        try:
            # The whole project is on disk before the editor opens anything:
            # the axis under test is the order the *editor* opens files in,
            # not the order files show up on disk.  (A module that is missing
            # or empty when a dependent is cached is a separate failure --
            # test_module_cache_side_effects.EmptyModuleRecoveryTests.)
            for role in order:
                doc = self.write_file(names[role] + ".d", texts[role])
                docs[role] = doc
                opened.append(doc)
            for role in order:
                docs[role].open()
            # Requests are answered after the notifications that precede them,
            # so this response guarantees the server has finished caching the
            # cell -- including reading every module of it from disk.  Only
            # then may the action below touch those files again: a save that
            # truncates a module while the server is reading it makes DCD cache
            # it as empty, which is a failure of its own (see
            # EmptyModuleRecoveryTests) and not what this sweep is about.
            docs["app"].document_symbols()
            self.apply_action(ACTIONS[action], names, docs, texts)
            items = labels(docs["app"].completion("w.")["items"])
        finally:
            for doc in opened:
                doc.close()
        return frozenset(items)

    def test_orderings_agree(self):
        shape = self.SHAPE
        orders = list(itertools.permutations(SHAPES[shape]))
        results: dict = {action: [] for action in self.actions()}

        cell = 0
        for action in results:
            for order in orders:
                results[action].append((order, cell, self.run_cell(cell, order, action)))
                cell += 1

        for action, cells in results.items():
            spec = ACTIONS[action]
            by_result: dict = {}
            for order, _, result in cells:
                by_result.setdefault(result, []).append(order)

            if len(by_result) > 1:
                detail = "\n".join(
                    "    {:<40} {}".format(", ".join(order), sorted(result))
                    for result, orders in by_result.items()
                    for order in orders
                )
                # Log the cells that disagree with the majority, not the ones
                # that got the common answer: the exception is the interesting
                # one.
                majority = max(by_result, key=lambda result: len(by_result[result]))
                odd = [entry for entry in cells if entry[2] != majority]
                self.fail(
                    f"{shape}: completions depend on the open order for action "
                    f"{action!r}:\n{detail}\n{self.server_excerpt(odd)}"
                )

            result = next(iter(by_result))
            self.assertTrue(
                spec["required"] <= result,
                f"{shape}: after {action!r} the completion should carry "
                f"{sorted(spec['required'])}, got {sorted(result)}",
            )
            self.assertFalse(
                result & spec["forbidden"],
                f"{shape}: after {action!r} the completion should not carry "
                f"{sorted(spec['forbidden'])}, got {sorted(result)}",
            )

    def server_excerpt(self, cells: list) -> str:
        """The server log lines that mention the modules of the odd cells."""
        modules = tuple(
            f"{self.SHAPE}_{cell}_{role}" for _, cell, _ in cells for role in SHAPES[self.SHAPE]
        )
        lines = [
            line
            for line in self.client.stderr_lines()
            if any(module in line for module in modules) or "> empty" in line
        ]
        return "--- server log (filtered, {0} lines) ---\n{1}".format(
            len(lines), "\n".join(lines[:400])
        )


class DirectImportOrderingTests(OrderingInvariantMixin, DlsTestCase):
    """Control: the app imports the library itself."""

    PROJECT = {}  # every cell writes its own uniquely named modules
    SHAPE = "direct"


class ForwardedImportOrderingTests(OrderingInvariantMixin, DlsTestCase):
    """One re-exporting module between the app and the library."""

    PROJECT = {}
    SHAPE = "forward"


class ForwardingChainOrderingTests(OrderingInvariantMixin, DlsTestCase):
    """The two-level chain that exposed the original cache bug."""

    PROJECT = {}
    SHAPE = "chain"
    #: 24 orders x 8 actions is most of this module's runtime, and the other
    #: shapes already cover the rest of the action axis; keep the four that
    #: exercise different machinery: a plain open, the unchanged-save
    #: dependent refresh, re-caching the outer forwarder, and a content change
    #: that has to travel all the way down the chain.
    ACTIONS_TO_RUN = (
        "open-only",
        "identity-save-leaf",
        "close-reopen-forwarder",
        "edit-leaf-remove-member",
    )


class DiamondImportOrderingTests(OrderingInvariantMixin, DlsTestCase):
    """The app reaches the library both directly and through a re-export."""

    PROJECT = {}
    SHAPE = "diamond"
