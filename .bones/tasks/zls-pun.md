---
id: zls-pun
title: 'Phase 2 Acceptance: Call Hierarchy Live Demo'
status: open
type: task
priority: 1
parent: zls-gyi
---

## Context

Phase 2 of zls-xjj (Call Hierarchy Implementation) is technically complete. Implementation tasks zls-t17 (prepareCallHierarchy + all callable kinds), zls-239 (incomingCalls + caller grouping), and zls-a9k (outgoingCalls + capability flip) are closed. All 10 code-level sub-epic criteria are checked; `zig build test` passes, `zig fmt --check .` passes.

This task is the user-facing acceptance step: agent documentation + narrated LSP tool walkthrough against real ZLS symbols.

## Agent Documentation (complete before presenting demo)

- [x] CLAUDE.md: add `call_hierarchy.zig` to the Feature Modules list under Architecture Overview
- [x] CLAUDE.md: extend Request Flow / Core Components if relevant (only if stale — don't add tutorial content) — nothing else stale, Request Flow/Core Components still accurate
- [x] Project docs: none expected (no user-visible config changes)

## What This Phase Built

ZLS now implements the LSP call hierarchy protocol — three methods (`textDocument/prepareCallHierarchy`, `callHierarchy/incomingCalls`, `callHierarchy/outgoingCalls`) backed by the extended `references.zig` Builder. Callers and callees are grouped by enclosing function with `fromRanges` for each call site, and results span the full import graph (from Phase 1's eager transitive loading). Server advertises `callHierarchyProvider`.

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

## Sign-Off

- [ ] Demo 1: prepareCallHierarchy on `initAnalyser` returns a correct CallHierarchyItem
- [ ] Demo 2: incomingCalls on `initAnalyser` returns multiple callers grouped by handler
- [ ] Demo 3: outgoingCalls on `hoverHandler` returns multiple callees grouped by callee
- [ ] Demo 4: incomingCalls on `resolveTypeOfNode` spans 4+ feature files
- [ ] Demo 5: outgoingCalls cross-file confirmed
- [ ] Demo 6: test declaration returns valid item
- [ ] Demo 7: non-callable position returns null
- [ ] CLAUDE.md updated to mention call_hierarchy.zig
- [ ] Phase 2 complete — zls-gyi can close, parent epic zls-xjj final demo criterion satisfied
