---
id: zls-pun
title: 'Phase 2 Acceptance: Call Hierarchy Live Demo'
status: open
type: task
priority: 1
depends_on: [zls-mxw, zls-029]
parent: zls-gyi
---



## Context

Phase 2 of zls-xjj (Call Hierarchy Implementation) has three implementation tasks closed (zls-t17, zls-239, zls-a9k) — the call hierarchy protocol is wired, handlers are implemented, capability is advertised. A first acceptance demo run surfaced a real R2/R3 gap: cross-file coverage only works for file-path imports, not module-name imports — i.e., Phase 2's "spanning all files reachable via the import graph" requirement is only half-satisfied by Phase 1's substrate. Two blockers were filed:

- **zls-mxw** — module-import coverage in reverse reference search (Shape B: lazy `resolved_imports` cache on Handle populated via `uriFromImportStr`).
- **zls-029** — findReferences on `@import` string literals as a distinct first-class feature.

This task is the user-facing acceptance step once both blockers land: agent documentation + narrated LSP tool walkthrough against real ZLS symbols AND against the in-repo `tests/fixtures/module_imports/` fixture that exercises the module-name import path.

## Agent Documentation (complete before presenting demo)

- [x] CLAUDE.md: add `call_hierarchy.zig` to the Feature Modules list under Architecture Overview
- [x] CLAUDE.md: extend Request Flow / Core Components if relevant (only if stale — don't add tutorial content) — nothing else stale, Request Flow/Core Components still accurate
- [x] Project docs: none expected (no user-visible config changes)

## What This Phase Built

ZLS now implements the LSP call hierarchy protocol — three methods (`textDocument/prepareCallHierarchy`, `callHierarchy/incomingCalls`, `callHierarchy/outgoingCalls`) backed by the extended `references.zig` Builder. Callers and callees are grouped by enclosing function with `fromRanges` for each call site. After zls-mxw and zls-029 land, the import-graph coverage is complete: both file-path imports (`@import("foo.zig")`, covered by Phase 1) and module-name imports (`@import("foo")`, covered by zls-mxw's lazy `resolved_imports` cache on Handle) are walked by candidate discovery, and `@import` string literals are themselves first-class findReferences targets (zls-029). Server advertises `callHierarchyProvider`.

## Environment Setup

1. Ensure the local ZLS binary used by the LSP tool is the current HEAD (tip: c637ac95).
   ```bash
   zig build -Doptimize=ReleaseSafe
   ```
2. Confirm tests are green and format is clean.
   ```bash
   zig build test --summary all
   zig fmt --check .
   ```
3. The LSP tool must be attached to this ZLS. The agent will issue `prepareCallHierarchy`, `incomingCalls`, and `outgoingCalls` operations against `/Volumes/code/zls/src/*.zig`.

## Demo

Live narrated LSP tool walkthrough. The agent runs each step, names the symbol and file, and explains what the result proves.

**Demo 1 — `prepareCallHierarchy` on a named function**
- Target: `initAnalyser` at `src/Server.zig:269`
- Expected: a single `CallHierarchyItem` with `kind=Function`, `name="initAnalyser"`, selectionRange covering the identifier, and `data` encoding URI + AST node index.

**Demo 2 — `incomingCalls` grouped by handler**
- Target: `initAnalyser` item from Demo 1
- Expected: multiple `IncomingCall` entries, each `from` a distinct handler function in Server.zig (e.g., `hoverHandler`, `completionHandler`, `referencesHandler`, …), each with one or more `fromRanges` covering the call expression.

**Demo 3 — `outgoingCalls` from a handler**
- Target: `hoverHandler` at `src/Server.zig:1410`
- Expected: multiple `OutgoingCall` entries — `initAnalyser`, `hover.hover`, LSP type conversions — each with `fromRanges` for every call site inside hoverHandler.

**Demo 4 — Cross-file `incomingCalls`**
- Target: `resolveTypeOfNode` at `src/analysis.zig:1943`
- Expected: callers spanning `completions.zig`, `references.zig`, `semantic_tokens.zig`, `inlay_hints.zig`, `hover.zig` — proving cross-file coverage from Phase 1 is feeding the call hierarchy.

**Demo 5 — Cross-file `outgoingCalls`**
- Target: a feature handler (e.g., `hoverHandler` or `referencesHandler`)
- Expected: callees defined in other modules (analysis.zig, offsets.zig, features/hover.zig, …) proving outgoing traversal also crosses file boundaries.

**Demo 6 — Edge: test declaration**
- Target: a `test "…"` block in any source file
- Expected: `prepareCallHierarchy` returns a valid item (kind=Function) — not null.

**Demo 7 — Edge: non-callable position returns null**
- Target: a variable name or a string literal
- Expected: `prepareCallHierarchy` returns null (or an empty result), confirming the handler rejects non-callable positions.

**Demo 8 — Module-name import coverage (blocked by zls-mxw)**
- Target: `doubled` at `tests/fixtures/module_imports/b.zig:1`
- Before zls-mxw: `incomingCalls` returned empty because the caller `a.zig:4` (`mod_b.doubled(x)`) imports `mod_b` by module name, not by `.zig` path.
- Expected after zls-mxw: `incomingCalls` returns the call site at `tests/fixtures/module_imports/a.zig:4`, proving the `resolved_imports` cache + seed-all-modules (R-M6) work end-to-end in a live LSP session with a resolved BuildConfig.
- Narration: shows that Phase 2's R2/R3 ("spanning all files reachable via the import graph") is actually met for module-name imports, not just file-path imports covered by Phase 1.

**Demo 9 — findReferences on an `@import` string literal (blocked by zls-029)**
- Target: `@import("mod_b")` at `tests/fixtures/module_imports/a.zig:1`
- Expected: the result set includes every `@import` string literal in the fixture that resolves to the same `b.zig` URI — compared by resolved URI, not by literal text. With the fixture as-is, this is the one literal in `a.zig`; the handler fires, the URI comparison executes, and `prepareRename` returns null on the same position (no rename semantics for import strings).
- Narration: shows that import relationships are now first-class queryable entities, distinct from symbol references.

## Sign-Off

- [ ] Demo 1: prepareCallHierarchy on `initAnalyser` returns a correct CallHierarchyItem
- [ ] Demo 2: incomingCalls on `initAnalyser` returns multiple callers grouped by handler
- [ ] Demo 3: outgoingCalls on `hoverHandler` returns multiple callees grouped by callee
- [ ] Demo 4: incomingCalls on `resolveTypeOfNode` spans 4+ feature files
- [ ] Demo 5: outgoingCalls cross-file confirmed
- [ ] Demo 6: test declaration returns valid item
- [ ] Demo 7: non-callable position returns null
- [ ] Demo 8: incomingCalls on `doubled` in `tests/fixtures/module_imports/` finds the caller in `a.zig` via module-name import (zls-mxw landed)
- [ ] Demo 9: findReferences on an `@import` string literal finds cross-file importers by resolved URI (zls-029 landed)
- [ ] CLAUDE.md updated to mention call_hierarchy.zig
- [ ] Phase 2 complete — zls-gyi can close, parent epic zls-xjj final demo criterion satisfied
