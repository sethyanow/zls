---
id: zls-t17
title: 'Phase 2 Task 1: prepareCallHierarchy + Server Wiring'
status: open
type: task
priority: 1
parent: zls-gyi
---

## Dependency Gates
- **Blocked by:** none (Phase 1 sub-epic zls-h4v is closed; seam contract delivered — eager transitive loading available but not required for prepare)
- **Unlocks:** Phase 2 Task 2 (incomingCalls) and Phase 2 Task 3 (outgoingCalls) — both consume CallHierarchyItem produced here

## Context

First task of Phase 2 (sub-epic zls-gyi) of epic zls-xjj (Call Hierarchy + Cross-File Reference Coverage). Phase 1 shipped eager transitive import loading in DocumentStore. This task builds the entry point of the call hierarchy LSP protocol: `textDocument/prepareCallHierarchy`.

Call hierarchy in LSP is a three-step protocol:
1. `textDocument/prepareCallHierarchy` (position) → returns `CallHierarchyItem[]` representing the callable entities at that position
2. `callHierarchy/incomingCalls` (item) → returns callers
3. `callHierarchy/outgoingCalls` (item) → returns callees

Steps 2 and 3 take an `Item` as input. That `Item` carries a `data: ?LSPAny` field preserved across requests — R4 uses this to encode `{uri, node_index}` so incoming/outgoing don't have to re-resolve from position.

This task delivers step 1 only (prepare). Tasks 2 and 3 will implement the other steps. Capability advertisement (`callHierarchyProvider`) is intentionally deferred to the final phase 2 task — advertising a capability whose methods return `null` from `.other` would be misleading to clients. Test infrastructure bypasses capability checking by calling `sendRequestSync` directly.

## Codebase Verification Findings

- **Confirmed:** `src/Server.zig:1588` `HandledRequestParams` union; mechanical registration per method at `HandledRequestParams`, `isBlockingMessage` (line 1630), `sendRequestSync` (line 1794). Pattern: thin handler function → feature module.
- **Confirmed:** `src/features/` pattern. Each feature is a single `.zig` file. Tests live at `tests/lsp_features/<name>.zig` and are registered via `_ = @import("lsp_features/<name>.zig");` in `tests/tests.zig` (line 13-25).
- **Confirmed:** lsp_kit types present in `.zig-cache/o/.../lsp_types.zig:4103` — `call_hierarchy.Item`, `call_hierarchy.PrepareParams`, method registration at line 9366 (`textDocument/prepareCallHierarchy` → `?[]const Item`). Zero ZLS source references to "callHierarchy" — clean greenfield.
- **Confirmed:** AST tags for callable constructs: `.fn_decl`, `.fn_proto`, `.fn_proto_multi`, `.fn_proto_one`, `.fn_proto_simple`, `.test_decl`, `.@"comptime"`. Seen in `src/features/document_symbol.zig:116-120` and `src/analysis.zig:89-93, 2090`.
- **Confirmed:** existing `prepareRenameHandler` at `src/Server.zig:1467` shows the URI parsing + handle lookup + position → source_index pattern.
- **Confirmed:** existing test pattern at `tests/lsp_features/selection_range.zig:50-84` — `Context.init()` → `addDocument(...)` → `sendRequestSync("method", params)` → assert on response.
- **Confirmed:** `types.call_hierarchy.Item` has required fields `name`, `kind: SymbolKind`, `uri`, `range`, `selectionRange`, optional `data: ?LSPAny`.

## Design

### What is "callable" at a position
At position P in file F, walk up the AST from the innermost node until we find one of:
- `.fn_decl` → function declaration with body (named function)
- `.fn_proto`, `.fn_proto_one`, `.fn_proto_multi`, `.fn_proto_simple` → function prototype without body (extern / type-level fn)
- `.test_decl` → test declaration
- `.@"comptime"` → comptime block, IF it transitively contains at least one call expression (epic R1 constraint)

If none found → return `null` (LSP spec: null means "no items here").

Rationale for walking up: LSP clients typically trigger call hierarchy from a position inside the function body or on the function name. Either should work — walking up handles both.

### CallHierarchyItem shape
- `name` — function/test name as identifier text. For comptime blocks, use `"comptime"` (they are anonymous).
- `kind` — `SymbolKind.function` for fn_decl, fn_proto; `SymbolKind.method` if the fn is inside a container type (struct/union/enum) at top level; `SymbolKind.function` otherwise. For test_decl → `SymbolKind.function` (tests are callable units). For comptime → `SymbolKind.function` (callable unit of code even though unnamed).
- `uri` — URI of the document.
- `range` — the entire enclosing node (function signature + body, full test_decl, full comptime block).
- `selectionRange` — the name token (function identifier, test string/identifier) OR the `comptime` keyword for comptime blocks. Must be strictly contained within `range` per LSP spec.
- `data` — JSON object `{"uri": "<uri>", "node": <u32>}` where `<u32>` is the Ast.Node.Index of the enclosing callable. Encoded as `std.json.Value` constructed into `LSPAny`. Round-trip is required — `incomingCalls`/`outgoingCalls` will decode it in subsequent tasks.

### Handler location
Create new file `src/features/call_hierarchy.zig`. Export `pub fn prepareHandler(server: *Server, arena: std.mem.Allocator, request: types.call_hierarchy.PrepareParams) Server.Error!?[]const types.call_hierarchy.Item`.

Server.zig adds a thin wrapper `fn prepareCallHierarchyHandler(...)` that forwards to `call_hierarchy.prepareHandler`, matching the existing convention (see `workspaceSymbolHandler` at `src/Server.zig:1584` and `selectionRangeHandler` at line 1574).

### Test file
Create `tests/lsp_features/call_hierarchy.zig`. Use the `selection_range.zig` test pattern as template. Register via `_ = @import("lsp_features/call_hierarchy.zig");` in `tests/tests.zig`.

## Requirements (from epic zls-xjj, scoped to this task)

- **R1 (partial):** `textDocument/prepareCallHierarchy` returns `CallHierarchyItem[]` for fn_decl, fn_proto, test_decl, comptime blocks with calls.
- **R4:** `CallHierarchyItem.data` encodes `{uri, node_index}`. Must survive JSON round-trip through lsp_kit.
- **R9 (partial):** Register `@"textDocument/prepareCallHierarchy"` in `HandledRequestParams`, `isBlockingMessage`, `sendRequestSync`. (The `callHierarchyProvider` capability flag is NOT flipped here — deferred to the task that completes the three-method set.)
- **R10 (partial):** LSP feature tests in `tests/lsp_features/call_hierarchy.zig`.

Requirements R2, R3 (incoming/outgoing), R8 (Builder extension), and the capability flip portion of R9 are explicitly out of scope for this task.

## Implementation

TDD cycle throughout: test first, run to observe failure, implement, observe pass, commit.

### Step 1: Write failing test for prepare on a function declaration
**File:** `tests/lsp_features/call_hierarchy.zig` (new)
**Intent:** Given source `fn <>foo() void {}`, calling `prepareCallHierarchy` at the placeholder returns exactly one Item with `name = "foo"`, `kind = .function`, `selectionRange` matching the `foo` identifier, and `range` covering the whole fn_decl.
**Structure:** Import `zls`, `Context`, `helper`, `offsets`, `types`. Define `testPrepare(source, expected: []const ExpectedItem)` helper using the `selection_range.zig` pattern. Define `ExpectedItem` struct (name, kind, selection_text, range_text) for assertions. First test function: `test "prepare on fn_decl returns function Item"`.
**Run:** `zig build test -Dtest-filter="call_hierarchy" --summary all` (NOTE: file not yet registered, so it won't run — proceed to step 2 to register it)

### Step 2: Register the new test file in tests/tests.zig
**File:** `tests/tests.zig:22` (alphabetical position between `references.zig` and `selection_range.zig`)
**Change:** Add `_ = @import("lsp_features/call_hierarchy.zig");` line. One-line insertion.
**Run:** `zig build test -Dtest-filter="call_hierarchy" --summary all`
**Expected failure:** compilation error because `call_hierarchy.zig` will reference `sendRequestSync("textDocument/prepareCallHierarchy", ...)` which requires the method to be registered in `HandledRequestParams`. OR runtime error "method not found" returning null from `.other`.

### Step 3: Wire Server.zig method registration (still no handler)
**File:** `src/Server.zig`
**Changes (4 sites):**
- Line 1588-1612: Add `@"textDocument/prepareCallHierarchy": types.call_hierarchy.PrepareParams,` to `HandledRequestParams` union.
- Line 1636-1658: Add `.@"textDocument/prepareCallHierarchy",` to the non-blocking list in `isBlockingMessage`.
- Line 1803-1827: Add a dispatch arm to `sendRequestSync`: `.@"textDocument/prepareCallHierarchy" => try server.prepareCallHierarchyHandler(arena, params),`
- Before `HandledRequestParams` (around line 1586): Add thin wrapper `fn prepareCallHierarchyHandler(server: *Server, arena: std.mem.Allocator, request: types.call_hierarchy.PrepareParams) Error!?[]const types.call_hierarchy.Item { return try @import("features/call_hierarchy.zig").prepareHandler(server, arena, request); }`
**Run:** `zig build check`
**Expected failure:** `features/call_hierarchy.zig` doesn't exist yet.

### Step 4: Create call_hierarchy.zig skeleton with null-returning prepareHandler
**File:** `src/features/call_hierarchy.zig` (new)
**Contents:** Imports (`std`, `lsp`, `Server`, `DocumentStore`, `Analyser`, `offsets`, `ast`, `Uri`). Define `pub fn prepareHandler(server: *Server, arena: std.mem.Allocator, request: types.call_hierarchy.PrepareParams) Server.Error!?[]const types.call_hierarchy.Item { _ = server; _ = arena; _ = request; return null; }`.
**Run:** `zig build check` (should compile) → `zig build test -Dtest-filter="call_hierarchy" --summary all`
**Expected failure:** the test from Step 1 fails because the handler returns null instead of an Item.

### Step 5: Implement prepare for fn_decl
**File:** `src/features/call_hierarchy.zig`
**What to implement:**
- Parse `request.textDocument.uri` using `Uri.parse(arena, ...)`.
- Look up handle via `server.document_store.getHandle(uri)`. Return null if not found.
- Convert `request.position` to `source_index` via `offsets.positionToIndex(handle.tree.source, request.position, server.offset_encoding)`.
- Walk AST from the innermost node at `source_index` up to the root, looking for `.fn_decl` via `ast.nodeContainsSourceIndex` or by using the tree's node-containment iteration. (The existing `innermostScopeAtIndexWithTag` works on scopes; for AST nodes, iterate from root's children down using `Ast.Node.Index` and `tree.nodeTag`.)
- When `.fn_decl` found: extract name via `tree.fullFnProto(&buf, fn_node).?.name_token`, build Item with computed `name`, `kind = .function`, `range = offsets.nodeToRange(tree, fn_node, encoding)`, `selectionRange = offsets.tokenToRange(tree, name_token, encoding)`, `data = encodeItemData(arena, handle.uri, fn_node)`.
- Return `arena.dupe(Item, &.{item})` as a single-element slice.
- Define private helper `fn encodeItemData(arena, uri: Uri, node: Ast.Node.Index) !?std.json.Value` that builds `{"uri": "...", "node": N}` via `std.json.Value.ObjectMap` and wraps in LSPAny.
**Run:** `zig build test -Dtest-filter="call_hierarchy" --summary all`
**Expected:** Step 1 test passes.
**Commit:** "feat: add prepareCallHierarchy for fn_decl (zls-t17)"

### Step 6: Add test + impl for fn_proto (extern/prototype)
**Test:** `test "prepare on fn_proto (extern) returns function Item"` with source like `extern fn <>extFn(a: i32) i32;`.
**Implementation:** Extend the AST walk to also match `.fn_proto`, `.fn_proto_one`, `.fn_proto_multi`, `.fn_proto_simple` tags. Same Item construction.
**Run:** `zig build test -Dtest-filter="call_hierarchy"`
**Commit.**

### Step 7: Add test + impl for test_decl
**Test:** `test "prepare on test_decl returns Item"` with source `test "<>my test" { _ = 1; }` and another test with source `test <>myTest { _ = 1; }` (named test).
**Implementation:** Match `.test_decl` in the walk. Name = test identifier (from `tree.tokenSlice` on the test name token, which may be a `string_literal` or `identifier`). `selectionRange` = the test name token. `range` = the full test_decl node.
**Run:** tests pass.
**Commit.**

### Step 8: Add test + impl for comptime block with call
**Test:** `test "prepare on comptime block containing call returns Item"` with source like:
```zig
fn foo() void {}
comptime {
    <>foo();
}
```
Expected: Item with `name = "comptime"`, `kind = .function`, `selectionRange` = `comptime` keyword, `range` = full comptime block.
**And:** `test "prepare on comptime block with no calls returns null"` with `comptime { const x = 1; _ = x; }`.
**Implementation:** Match `.@"comptime"` in the walk. Before returning Item, walk the comptime block body looking for any `.call`/`.call_comma`/`.call_one`/`.call_one_comma` node via `ast.Walker` — if none, return null (not an Item).
**Run:** tests pass.
**Commit.**

### Step 9: Add test + verify null on non-callable positions
**Tests:**
- `test "prepare on whitespace between functions returns null"` with source `fn a() void {}\n<>\nfn b() void {}`.
- `test "prepare on variable declaration returns null"` with `const <>x = 1;` at top level.
**Implementation:** Should work without new code if the AST walk correctly returns null when no callable ancestor is found. If not, adjust fallthrough logic.
**Run:** tests pass.
**Commit.**

### Step 10: Test + verify data round-trip
**Test:** `test "CallHierarchyItem.data round-trips through JSON"` — build an Item, serialize via lsp_kit's JSON path (use `std.json.Stringify` with the arena), parse back via `std.json.parseFromSlice`, verify the `uri` and `node` fields survive unchanged.
**Implementation:** None if step 5's encoder is correct. If the test fails, fix the encoder (likely issue: `LSPAny` requires specific `std.json.Value` variant).
**Run:** tests pass.
**Commit.**

### Step 11: Pre-close verification
**Commands:**
- `zig build test --summary all` → ALL tests pass (not just call_hierarchy).
- `zig build check` → compiles clean.
- `zig fmt --check .` → passes.
**If any fail:** do not close. Debug and fix before closing.

### Step 12: Update success criteria in skeleton files
**Files:** `.bones/tasks/zls-t17.md` (this task), `.bones/tasks/zls-gyi.md` (Phase 2 sub-epic).
**Action:** Check off criteria that are verifiably met by this task's changes. Leave unchecked the ones owed to later tasks (incoming/outgoing/Builder/capability/demo).

### Step 13: Push
**Command:** `git push` (bare — no remote/branch per user rules)
**Only after:** tests + fmt all green, success criteria updated.

## Success Criteria

- [ ] `tests/lsp_features/call_hierarchy.zig` exists and is registered in `tests/tests.zig`
- [ ] Test: prepareCallHierarchy on `fn_decl` returns one Item with correct name/kind/range/selectionRange
- [ ] Test: prepareCallHierarchy on `fn_proto` (extern) returns one Item
- [ ] Test: prepareCallHierarchy on `test_decl` returns one Item (both string-named and identifier-named)
- [ ] Test: prepareCallHierarchy on `.@"comptime"` block containing a call returns one Item
- [ ] Test: prepareCallHierarchy on `.@"comptime"` block with no calls returns null
- [ ] Test: prepareCallHierarchy on non-callable position (whitespace, variable decl) returns null
- [ ] Test: CallHierarchyItem.data round-trips `{uri, node}` through JSON serialization
- [ ] `src/features/call_hierarchy.zig` exports `prepareHandler` matching the expected Error!?[]const Item signature
- [ ] `src/Server.zig` registers `@"textDocument/prepareCallHierarchy"` in `HandledRequestParams`, `isBlockingMessage`, `sendRequestSync`, plus a thin wrapper `prepareCallHierarchyHandler`
- [ ] `zig build test --summary all` passes
- [ ] `zig build check` compiles clean
- [ ] `zig fmt --check .` passes

## Anti-Patterns (FORBIDDEN for this task)

- **Advertising `callHierarchyProvider` capability.** Deferred until incoming + outgoing are implemented. A half-working advertised capability is worse than an undeclared one for clients that enumerate server features.
- **Adding stub `incomingCallsHandler` / `outgoingCallsHandler` in this task.** "No stubs. No v0 framing." Task 2 and Task 3 will each wire and implement their method fully.
- **Re-resolving node index from position at call time.** The `data` field encodes the node index precisely to avoid this. If the implementation finds itself parsing `range.start` to re-locate the node, that's the anti-pattern.
- **Using selectionRange text to identify the function later.** Names collide (overloaded names across files, shadowing within scopes). The node index is unique per `(uri, tree)` pair.
- **Running subset test commands only.** Pre-close verification runs the full `zig build test --summary all`, not just `-Dtest-filter="call_hierarchy"`. Builder/references existing behavior must still pass untouched.
- **Skipping tests for the null path.** "prepare on non-callable position returns null" is not optional — it is success criterion SC2 of the parent sub-epic.

## Key Considerations

### AST walk direction: position → enclosing callable
The LSP client passes a position; ZLS must find the "enclosing callable." Walking up from the innermost AST node at `source_index` is the natural approach. `ast.iterateChildren`-style iteration from root may require manual tracking of parentage. Alternative: use the existing `innermostScopeAtIndexWithTag(doc_scope, source_index, .initOne(.function))` for fn_decl/fn_proto coverage, and handle `test_decl` + `.@"comptime"` via a separate AST traversal (scope tree does not have dedicated test/comptime tags). Consider whether scope-based detection captures all cases before reaching for custom AST walks.

### fn_decl vs fn_proto edge case: prototypes inside container bodies
Field accessors in struct/union declarations use `.fn_proto` tags without bodies. These are callable via method-call syntax. Decision: treat them as callable — `kind = .method` when the fn_proto is a direct struct/union/enum member, else `kind = .function`. Detect via parent node tag in the AST walk.

### comptime block "contains call" detection
Walking the entire comptime block body to check for any call node is O(block_size). For small comptime blocks this is fine. Don't precompute a global "comptime blocks with calls" set — that's premature optimization.

### selectionRange containment
LSP spec mandates `selectionRange` ⊂ `range`. For comptime blocks, `selectionRange` = the `comptime` keyword's range, `range` = the full block (including braces). The keyword is the first token of the comptime node, so containment holds. Verify in test assertions.

### `data` field LSPAny construction
`types.LSPAny` in lsp_kit is `std.json.Value`. Build an object via:
```zig
var obj: std.json.ObjectMap = .init(arena);
try obj.put("uri", .{ .string = uri.raw });
try obj.put("node", .{ .integer = @intCast(@intFromEnum(node)) });
// wrap in .{ .object = obj }
```
Verify whether `@intFromEnum` is needed (depends on how `Ast.Node.Index` is represented — it is a non-exhaustive enum in 0.15). Round-trip test in Step 10 catches encoding errors.

### Error handling
Follow `prepareRenameHandler` (Server.zig:1467) for URI parse errors: map `error.OutOfMemory` to itself, other parse errors to `error.InvalidParams`. Missing handle → return null (not an error — graceful per LSP).

### Test fixture strategy
Single-file fixtures only for this task. Cross-file infrastructure (import relationships between `untitled://` docs, or file-system-backed fixtures) is a Task 2/3 concern because incoming/outgoing span the import graph. If any Task 1 test starts needing multi-file setup, that's a signal of scope creep — push back to this task's single-file scope.

### Pre-existing CallBuilder coexists
`src/features/references.zig:556 CallBuilder` is used by `callsiteReferences`. It is NOT modified in this task — Task 2 (incomingCalls) will assess whether to unify per R8 or route incomingCalls through a wider Builder extension. Task 1 leaves the existing codepath untouched.

## Out of Scope

- `callHierarchy/incomingCalls` handler (Phase 2 Task 2)
- `callHierarchy/outgoingCalls` handler (Phase 2 Task 3)
- `references.zig` Builder extension (R8 — consumed by Task 2)
- `callHierarchyProvider` capability advertisement (flipped by the task that ships all three handlers)
- Live narrated LSP demo (Phase 2 acceptance task after all three implementation tasks close)
- Cross-file test fixtures and multi-document test infrastructure (Task 2/3)
