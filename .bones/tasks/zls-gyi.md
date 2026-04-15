---
id: zls-gyi
title: 'Phase 2: Call Hierarchy Implementation'
status: open
type: epic
priority: 1
depends_on: [zls-h4v, zls-6pm, zls-t17, zls-239, zls-a9k, zls-pun, zls-mxw, zls-029]
parent: zls-xjj
---














## Context
Parent epic zls-xjj, Phase 2. Depends on Phase 1 (zls-h4v: Cross-File Reference Coverage Fix).

Phase 1 fixed the DocumentStore to eagerly load transitive imports, giving us reliable cross-file reference coverage. This phase builds the actual call hierarchy feature on top of that infrastructure.

The implementation extends the existing `references.zig` Builder (Approach C) to return structured call information, then builds a new `call_hierarchy.zig` feature module that consumes the enriched data. Server.zig wiring is mechanical.

## Requirements
- R1: `textDocument/prepareCallHierarchy` returning CallHierarchyItem for all callable constructs (fn declarations, fn prototypes, test declarations, comptime blocks with calls)
- R2: `callHierarchy/incomingCalls` returning all callers grouped by calling function, with fromRanges, spanning all files reachable via the import graph
- R3: `callHierarchy/outgoingCalls` returning all callees grouped by callee, with fromRanges, spanning all files
- R4: CallHierarchyItem.data encodes URI + AST node index
- R8: references.zig Builder extended to return structured call info for both findReferences and call hierarchy (Approach C unified codepath)
- R9: Server capabilities advertise callHierarchyProvider; methods wired into HandledRequestParams and sendRequestSync
- R10: LSP feature tests in tests/lsp_features/call_hierarchy.zig

## Success Criteria
- [x] `prepareCallHierarchy` returns correct items for functions, methods, tests, and comptime blocks
- [x] `prepareCallHierarchy` returns null for non-callable positions
- [x] `incomingCalls` returns callers across multiple files with correct grouping and ranges
- [x] `incomingCalls` groups multiple calls from the same caller into one IncomingCall with multiple fromRanges
- [x] `outgoingCalls` returns callees across multiple files with correct grouping and ranges
- [x] `outgoingCalls` groups multiple calls to the same callee into one OutgoingCall with multiple fromRanges
- [x] Builder extension does not break existing findReferences behavior
- [x] Server advertises callHierarchyProvider capability
- [x] `zig build test --summary all` passes (including new call_hierarchy tests)
- [x] `zig build test -Dtest-filter="call_hierarchy"` passes specifically
- [x] `zig fmt --check .` passes
- [ ] Live narrated LSP tool demo showing all three operations on real ZLS functions

## Anti-Patterns
- NO separate CallBuilder codepath (R8 mandates extending existing Builder, not duplicating)
- NO skipping outgoingCalls (user explicitly chose all three at once)
- NO single-file-only tests (R2/R3 require cross-file results; tests must include multi-file scenarios)
- NO position-based re-resolution (R4: use URI + node index in data field)
- NO skipping the live LSP demo (tests prove correctness, demo proves real-world behavior)

## Key Considerations
- `CallHierarchyItem.data` encoding: JSON object `{"uri": "...", "node": N}` serialized as LSPAny. Must round-trip through lsp_kit serialization.
- Test infrastructure: `addDocument` uses `untitled://` URIs. Need to verify that import relationships between untitled documents work for cross-file tests. If not, may need file-system-backed test fixtures.
- The Builder extension must be backward-compatible: existing callers that only want reference locations should not need to change.
- `innermostScopeAtIndexWithTag(doc_scope, source_index, .initOne(.function))` is the mechanism for finding the enclosing function scope for grouping incoming calls.
- For outgoing calls, walk the function body with `ast.Walker`, collect call/call_one/call_comma/call_one_comma nodes, resolve callees.
- Recursive calls: a function calling itself should appear in both incoming and outgoing results.

## Acceptance Requirements
**Agent Documentation:** Update stale docs only.
- [ ] CLAUDE.md: update Architecture Overview to mention call_hierarchy.zig feature module
- [ ] Project docs: none expected

**User Demo:** Live narrated LSP tool walkthrough.
- `prepareCallHierarchy` on `initAnalyser` (Server.zig:269) — show the returned CallHierarchyItem with name, kind, range
- `incomingCalls` on `initAnalyser` — show all 9 callers in Server.zig grouped by handler function, narrate the grouping
- `outgoingCalls` on `hoverHandler` (Server.zig:1409) — show what functions it calls
- Cross-file: `incomingCalls` on `resolveTypeOfNode` (analysis.zig:1943) — show callers across completions.zig, references.zig, semantic_tokens.zig, inlay_hints.zig
- Cross-file: `outgoingCalls` on a feature handler — show it calling functions defined in other modules
- Edge case: `prepareCallHierarchy` on a test declaration — show it returns a valid item
- Edge case: `prepareCallHierarchy` on a non-callable position (e.g., a variable) — show it returns null
- Narrate each step as it happens: what the LSP call does, what the result means, why it proves the feature works
