---
id: zls-xjj
title: Call Hierarchy + Cross-File Reference Coverage for ZLS
status: open
type: epic
priority: 1
depends_on: [zls-h4v, zls-gyi, zls-6pm]
---








## Requirements (IMMUTABLE)

R1. ZLS shall implement `textDocument/prepareCallHierarchy` returning `CallHierarchyItem` for all callable constructs: fn declarations, fn prototypes, test declarations, and comptime blocks containing function calls.

R2. ZLS shall implement `callHierarchy/incomingCalls` returning all functions that call the target, grouped by calling function, with accurate `fromRanges` for each call site. Results shall span all files reachable via the import graph, not just files already opened.

R3. ZLS shall implement `callHierarchy/outgoingCalls` returning all functions called by the target, grouped by callee, with accurate `fromRanges`. Results shall span all files reachable via the import graph.

R4. The `CallHierarchyItem.data` field shall encode URI + AST node index to avoid re-resolution between prepare and incoming/outgoing calls.

R5. The `DocumentStore` shall eagerly load files transitively reachable via `@import` chains when a file is opened, ensuring the full compilation unit is indexed. No artificial bound on depth or file count.

R6. The `gatherWorkspaceReferenceCandidates` function shall also load files on-demand during reference search as a fallback, ensuring files not yet loaded are still discovered.

R7. The existing `findReferences` operation shall benefit from R5/R6 — cross-file reference coverage shall improve without changes to the references handler itself.

R8. The `references.zig` Builder shall be extended to return structured call information consumable by both `findReferences` and the call hierarchy feature (Approach C — unified codepath).

R9. Server capabilities shall advertise `callHierarchyProvider` and the three methods shall be wired into `HandledRequestParams` and `sendRequestSync`.

R10. All new functionality shall have LSP feature tests in `tests/lsp_features/call_hierarchy.zig` following the existing test patterns.

## Success Criteria
- [ ] `textDocument/prepareCallHierarchy` returns correct items for functions, tests, and comptime blocks
- [ ] `callHierarchy/incomingCalls` returns callers across multiple files with correct grouping and ranges
- [ ] `callHierarchy/outgoingCalls` returns callees across multiple files with correct grouping and ranges
- [ ] `findReferences` cross-file coverage improved (validated by LSP tool demo on real codebase)
- [ ] `zig build test --summary all` passes with new tests
- [ ] `zig fmt --check .` passes
- [ ] Live narrated LSP tool demo showing call hierarchy on real ZLS functions with cross-file results

## Anti-Patterns (FORBIDDEN)
- NO single-file-only call hierarchy results (the whole point is cross-file — if we only find callers in the current file, we've failed. The existing `callsiteReferences` already does single-file.)
- NO separate Builder codepath for call hierarchy (R8 mandates Approach C — extending the existing Builder, not duplicating it. Separate codepaths will diverge and rot.)
- NO position-based re-resolution in incoming/outgoing handlers (R4 mandates URI + node index in data field. Re-resolving from selectionRange is fragile across edits.)
- NO artificial bounds on transitive import loading (R5 says unbounded. "What if the project is huge" is not a reason to silently drop coverage. Zig import graphs are bounded by the compilation unit.)
- NO skipping the live LSP demo (test suite green is necessary but not sufficient. The demo proves the feature works in a real codebase, not just in synthetic test fixtures.)

## Approach

Extend the existing `references.zig` Builder (Approach C) to return structured call information. The Builder's `referenceNode` already resolves symbols at each reference site — we augment it to also record whether each reference is a call expression and which function scope contains it. This enriched data feeds both the existing `findReferences` (which ignores the new fields) and the new call hierarchy handlers (which group by containing function).

For cross-file coverage, we fix the `DocumentStore` to eagerly load files transitively reachable via `@import` when any file is opened, and add on-demand loading as a fallback in `gatherWorkspaceReferenceCandidates`. This fixes both `findReferences` and call hierarchy in one shot.

The three LSP methods (`prepareCallHierarchy`, `incomingCalls`, `outgoingCalls`) are implemented in a new `src/features/call_hierarchy.zig` module following the existing feature module pattern. Server.zig wiring is mechanical: add to `HandledRequestParams`, `sendRequestSync`, capabilities, and `isBlockingMessage`.

## Architecture

### Components
- **`src/features/call_hierarchy.zig`** — new feature module: prepare/incoming/outgoing handlers
- **`src/features/references.zig`** — extended Builder with call-site metadata; enriched `callsiteReferences`
- **`src/DocumentStore.zig`** — eager transitive import loading on file open
- **`src/Server.zig`** — method registration, capabilities, handler delegation
- **`tests/lsp_features/call_hierarchy.zig`** — new test file
- **`tests/tests.zig`** — register new test file

### Data Flow

```
prepareCallHierarchy(position) → resolve declaration → build CallHierarchyItem{uri, node_index in data}

incomingCalls(item) → decode data → get DeclWithHandle
  → extended callsiteReferences(workspace: true) → [CallNode + enclosing function scope]
  → group by enclosing function → [IncomingCall{from: caller_item, fromRanges: [...]}]

outgoingCalls(item) → decode data → get function body AST
  → walk body for call expressions → resolve each callee
  → group by callee → [OutgoingCall{to: callee_item, fromRanges: [...]}]
```

### Key Types (from lsp_kit)
- `call_hierarchy.PrepareParams` — extends TextDocumentPositionParams
- `call_hierarchy.Item` — name, kind, tags, detail, uri, range, selectionRange, data
- `call_hierarchy.IncomingCall` — from: Item, fromRanges: []Range
- `call_hierarchy.OutgoingCall` — to: Item, fromRanges: []Range
- `call_hierarchy.IncomingCallsParams` / `OutgoingCallsParams` — item: Item

## Phases

### Phase 1: Cross-File Reference Coverage Fix
**Scope:** R5, R6, R7
**Gate:**
- `zig build test --summary all` → all tests pass
- `zig build check` → compiles clean
- [GATE TBD — LSP tool findReferences on `resolveTypeOfNode` finds 5+ feature files vs prior 2]
**Demo:** Live narrated LSP tool walkthrough: run findReferences on `resolveTypeOfNode` (analysis.zig:1943) and show results now include references.zig, semantic_tokens.zig, inlay_hints.zig — files that were missed before. Explain each call as it happens: "I'm querying findReferences on X, previously this found N files, now it finds M because the import graph is fully loaded."

### Phase 2: Call Hierarchy Implementation
**Scope:** R1, R2, R3, R4, R8, R9, R10
**Gate:**
- `zig build test --summary all` → all tests pass (including new call_hierarchy tests)
- `zig build check` → compiles clean
- `zig build test -Dtest-filter="call_hierarchy"` → call hierarchy tests pass specifically
**Demo:** Live narrated LSP tool walkthrough: prepareCallHierarchy on `initAnalyser` (Server.zig:269), then incomingCalls showing all 9 callers grouped by handler function. Then outgoingCalls on `hoverHandler` showing what it calls. Then cross-file: incomingCalls on `resolveTypeOfNode` showing callers across completions.zig, references.zig, semantic_tokens.zig, inlay_hints.zig. Narrate each step: what the call does, what the result means, why it proves the feature works.

## Agent Failure Mode Catalog

### Phase 1
| Shortcut | Rationalization | Pre-block |
|----------|----------------|-----------|
| Only fix the build-system path in gatherWorkspaceReferenceCandidates | "The build system path is the primary one" | R5 requires eager loading regardless of build system presence. Claude Code LSP doesn't configure workspaces. |
| Mark phase done after code compiles | "Existing tests still pass, the fix is in DocumentStore" | Gate requires live LSP demo showing improved cross-file coverage. Tests passing is necessary but not sufficient. |
| Add loading only in gatherWorkspaceReferenceCandidates (on-demand only) | "On-demand is simpler and achieves the same thing" | R5 explicitly requires eager transitive loading. On-demand alone can't discover files that import the target (reverse direction). |

### Phase 2
| Shortcut | Rationalization | Pre-block |
|----------|----------------|-----------|
| Implement call hierarchy with a separate CallBuilder instead of extending existing Builder | "Extending the Builder is risky, separate is safer" | R8 mandates Approach C. A separate codepath is an anti-pattern. If extending Builder is hard, surface the blocker. |
| Skip outgoingCalls, ship prepare + incoming only | "incomingCalls is the high-value feature" | User explicitly chose all three at once. outgoingCalls is a requirement. |
| Test only single-file scenarios | "Cross-file is covered by Phase 1" | R2/R3 require cross-file results. Tests must include multi-file scenarios using addDocument with import relationships. |
| Skip the narrated demo | "Tests prove it works" | Anti-pattern: "NO skipping the live LSP demo." The demo proves real-codebase behavior. |

## Seam Contracts

### Phase 1 → Phase 2
**Delivers:** Eager transitive import loading in DocumentStore. On-demand fallback in gatherWorkspaceReferenceCandidates. Improved cross-file findReferences coverage.
**Assumes:** Phase 2 assumes `callsiteReferences(workspace: true)` now returns results across all transitively imported files, not just already-opened files.
**If wrong:** incomingCalls/outgoingCalls will silently miss callers/callees in files not opened by the editor. The call hierarchy feature would repeat the exact same cross-file gap we're fixing.

## Design Rationale

### Problem
ZLS lacks call hierarchy support (`textDocument/prepareCallHierarchy`, `callHierarchy/incomingCalls`, `callHierarchy/outgoingCalls`). These are critical for AI agents that need to understand call chains for refactoring. Additionally, `findReferences` has incomplete cross-file coverage — testing showed it finds 2 of 5 files for `resolveTypeOfNode` and 6 of 14 files for `offsets.Loc`. Both issues stem from the `DocumentStore` only searching files already loaded in memory.

### Research Findings
**Codebase:**
- `src/features/references.zig:544-653` — existing `CallBuilder` and `callsiteReferences` already find call sites cross-file using `gatherWorkspaceReferenceCandidates`. This is 80% of incomingCalls. [VERIFIED via Read tool]
- `src/features/references.zig:327-391` — `gatherWorkspaceReferenceCandidates` has two paths: build-system (follows import graph from root source file) and fallback (iterates only loaded handles). The fallback path is why cross-file coverage is incomplete. [VERIFIED via Read tool]
- `src/analysis.zig:6221` — `innermostScopeAtIndexWithTag` with `.function` filter finds enclosing function scope for any source position. This is the grouping mechanism for incomingCalls. [VERIFIED via Read tool]
- `src/DocumentScope.zig:227` — `Scope.Tag` enum has `.function` variant. [VERIFIED via Read tool]
- `lsp_types.zig:4103-4241` — all call hierarchy types fully defined in lsp_kit. [VERIFIED via Read tool on .zig-cache]
- `lsp_types.zig:9361-9405` — method mappings for all three call hierarchy methods exist in lsp_kit. [VERIFIED via Grep]
- `src/Server.zig:1588-1612` — `HandledRequestParams` union pattern. Adding new methods is mechanical. [VERIFIED via Read tool]
- `src/Server.zig:540-580` — Server capabilities. No `callHierarchyProvider` currently. [VERIFIED via Grep]
- Zero mentions of "callHierarchy" anywhere in ZLS source. [VERIFIED via Grep across entire codebase]

**External:**
- LSP 3.16.0 spec defines call hierarchy as a three-step protocol: prepare → incoming/outgoing.
- Claude Code's LSP tool supports `prepareCallHierarchy`, `incomingCalls`, `outgoingCalls` operations.
- Claude Code's LSP tool does NOT expose a query parameter for `workspaceSymbol` (separate tracked issue on their GitHub).

### Approaches Considered

#### 1. Approach A: Build on existing callsiteReferences
**Why explored:** Reuses proven infrastructure, minimal new code.
**REJECTED BECAUSE:** Creates a parallel codepath for call resolution that will diverge from the reference Builder over time. User chose Approach C.
**DO NOT REVISIT UNLESS:** Extending the Builder proves architecturally infeasible (e.g., the Builder's type signature can't accommodate call metadata without breaking existing callers).

#### 2. Approach B: Build from scratch using DocumentScope
**Why explored:** Clean slate for call hierarchy specifically.
**REJECTED BECAUSE:** Duplicates all the symbol resolution logic that the Builder already has. Higher risk, more code, guaranteed divergence.
**DO NOT REVISIT UNLESS:** The existing Builder and Analyser are fundamentally incompatible with call hierarchy data requirements.

#### 3. Approach C: Extend Builder for both features (selected)
**Chosen because:** Unifies the codepaths so improvements to symbol resolution benefit both findReferences and call hierarchy. The Builder already walks AST nodes and resolves symbols — adding call-site metadata is an incremental extension, not a rewrite.

### Scope Boundaries
**In scope:** prepareCallHierarchy, incomingCalls, outgoingCalls, cross-file coverage fix, Builder extension, tests, server wiring.
**Out of scope:** workspaceSymbol query parameter (Claude Code tool limitation, not ZLS), type hierarchy (separate LSP feature), partial result streaming (can add later).

### Open Questions
- How to encode URI + node index in `CallHierarchyItem.data` (LSPAny) — JSON object or packed string? Resolve during implementation.
- Whether `addDocument` in test context can simulate `@import` relationships for cross-file tests. Need to verify during Phase 2 task scoping.

## Design Discovery

### Key Decisions Made
| Question | Answer | Implication |
|----------|--------|-------------|
| Callable scope for prepareCallHierarchy | All constructs: functions, methods, tests, comptime blocks | R1 covers all callable constructs, not just named functions |
| Ship prepare+incoming first or all three? | All three at once | R2 + R3 both required in Phase 2 |
| Fix cross-file coverage together or separately? | Together, bundled | R5-R7 form Phase 1, gating Phase 2 |
| Bound transitive import loading? | Unbounded | R5 says no artificial bounds |
| CallHierarchyItem.data content | URI + AST node index | R4 avoids position re-resolution |
| Implementation approach | C — extend existing Builder | R8 mandates unified codepath |
| Ship order | One epic, cross-file fix as Phase 1 | Phase 1 validates infrastructure before Phase 2 builds on it |
| Eager vs on-demand loading | Both | R5 (eager) + R6 (on-demand fallback) |
| Acceptance demo format | Live narrated LSP tool walkthrough | Explains each call as it happens, before/after comparison |

### Dead-End Paths
- Attempted to use `workspaceSymbol` via LSP tool to search for symbols — LSP tool doesn't expose a query parameter, ZLS returns null for empty queries. This is a Claude Code tool limitation, not a ZLS issue.
- Attempted to test `prepareCallHierarchy` via LSP tool before implementation — confirmed ZLS has zero call hierarchy code.

### Open Concerns
- Cross-file test infrastructure: `addDocument` uses `untitled://` URIs which bypass file-system loading. Need to verify that import relationships between `untitled://` documents work with the enhanced Builder. If not, may need to use file-system-backed test documents.

### Requirement Tensions
| Req Pair | Component | Compatible? | Resolution |
|----------|-----------|-------------|------------|
| R5 (eager loading) + R6 (on-demand fallback) | DocumentStore + gatherWorkspaceReferenceCandidates | Yes | Belt and suspenders — eager catches forward imports, on-demand catches anything missed |
| R7 (findReferences benefits) + R8 (Builder extension) | references.zig Builder | Yes | Builder extension enriches data without changing existing output format. findReferences ignores new fields. |
| R8 (unified codepath) + R1-R3 (call hierarchy) | references.zig + call_hierarchy.zig | Yes | Builder produces enriched data, call_hierarchy.zig consumes it. call_hierarchy.zig does not duplicate resolution logic. |

## Log

- [2026-04-13T12:37:11Z] [Seth] Adversarial finding (out of zls-91m scope): analysis.zig:resolveImportString and gatherWorkspaceReferenceCandidates build-system path (lines 358-364) still use getOrLoadHandle which awaits. Not currently triggered by recursive scenarios, but they're potential deadlock vectors if any future code path runs them during an in-progress createAndStoreDocument. Consider migrating to ensureHandleLoaded in a follow-up task.
