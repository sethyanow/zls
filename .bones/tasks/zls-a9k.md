---
id: zls-a9k
title: 'Phase 2 Task 3: outgoingCalls handler + callee grouping + capability flip'
status: closed
type: task
priority: 1
parent: zls-gyi
---




## Dependency Gates
- **Blocked by:** zls-t17 (closed — supplies `buildItemIfCallable` + Item encoding) and zls-239 (closed — supplies `decodeItemData` + the Server.zig 4-site wiring template).
- **Unlocks:** Phase 2 acceptance task (live narrated LSP demo). After this task closes, zls-gyi's 12 success criteria are all met and the acceptance task becomes the next bn ready.

## Context

Task 1 (zls-t17) shipped `prepareCallHierarchy`. Task 2 (zls-239) shipped `callHierarchy/incomingCalls`. Task 3 completes the protocol triad with `callHierarchy/outgoingCalls` and flips the `callHierarchyProvider` server capability, signalling the full feature set to clients.

Outgoing is semantically the mirror of incoming but the traversal shape is different:

- **Incoming:** workspace-wide scan for all callers of the target. CallBuilder walks every indexed file, filtering calls whose resolved decl equals the target.
- **Outgoing:** walk ONLY the target's body, collect every `.call*` node, resolve each callee's decl, group by callee. No workspace scan — the target fn's body is self-contained.

The handler must:

1. Decode `Item.data` to recover `(uri, node_index)` — reuse Task 2's `decodeItemData`.
2. Validate staleness (bounds + callable tag) against the current tree.
3. Locate the body node to walk. For `fn_decl`, it's the block inside the fn. For `test_decl` and `@"comptime"`, the body is their block child. For `fn_proto` variants (no body — prototypes like extern fns), outgoingCalls returns an empty slice (no body to walk means no outgoing calls, not "not applicable").
4. Walk the body with `ast.Walker`, collect `.call` / `.call_comma` / `.call_one` / `.call_one_comma` nodes.
5. For each call node: extract the callee expression (`call.ast.fn_expr`), resolve to a `DeclWithHandle` via the same `.identifier` / `.field_access` logic `CallBuilder.referenceNode` uses. Silently skip calls whose callee cannot be resolved (e.g., anonymous function literals, unresolved imports, builtins).
6. Group by callee's `DeclWithHandle` (uri-equality + ast_node equality via `DeclWithHandle.eql`). Each unique callee produces one `OutgoingCall` whose `fromRanges` lists every call site inside the target's body.
7. Build `OutgoingCall.to` via `buildItemIfCallable(arena, callee.handle.uri, &callee.handle.tree, callee_ast_node, null, encoding)`. If the callee's ast_node isn't itself a callable tag (e.g., the decl points at a var_decl that holds a fn value rather than a fn_decl), skip — we can't represent it as an Item in the current design.

Task 3 also flips the `callHierarchyProvider` capability. Per zls-gyi's anti-patterns, this flag was deferred until all three handlers ship. Closing Task 3 is the signal.

## Codebase Verification Findings

- **Confirmed:** `src/features/call_hierarchy.zig` exports `decodeItemData` (private to the module) — Task 3 reuses it directly, no re-export needed. Same file exports `buildItemIfCallable` which Task 3 uses for callee Items.
- **Confirmed:** Server.zig 4-site wiring pattern established at lines 1588-1596 (thin wrappers), 1615-1617 (HandledRequestParams union), 1661-1663 (non-blocking list), 1838-1840 (dispatch arms). Task 3 inserts after the `callHierarchy/incomingCalls` entries at each site.
- **Confirmed:** Server capabilities block at `src/Server.zig:552-581` declares all provider flags. callHierarchyProvider goes alongside definitionProvider, referencesProvider, etc. lsp_kit type at `lsp_types.zig:3571`: `callHierarchyProvider: ?CallHierarchyOptions = null`. `CallHierarchyOptions` (lsp_types.zig:3810) is a `union(enum)` with three variants: `bool: bool`, `call_hierarchy_options: call_hierarchy.Options`, `call_hierarchy_registration_options: call_hierarchy.RegistrationOptions`. The `Options` struct (lsp_types.zig:4167) is `struct { workDoneProgress: ?bool = null }`. A minimal opt-in is therefore `.callHierarchyProvider = .{ .call_hierarchy_options = .{} }` (mirroring how `codeActionProvider` sets options at line 551).
- **Confirmed:** `CallBuilder.referenceNode` at `src/features/references.zig:603-649` handles both `.identifier` and `.field_access` callees. The skeleton for outgoing callee resolution mirrors this code minus the `target_decl.eql(child)` filter. The difference: we accept every resolved child, not just those equal to a target.
- **Confirmed:** `lsp_kit` types at lsp_types.zig:4177: `OutgoingCall = struct { to: Item, fromRanges: []const Range }` and 4191: `OutgoingCallsParams = struct { item: Item, workDoneToken, partialResultToken }`. Same shape as incoming.
- **Confirmed:** For `.fn_decl`, the body node is accessible via `tree.nodeData(fn_decl).node_and_node[1]` (the second node is the body). For `.fn_proto*` (no body), `nodeData` variant doesn't carry a body node. Verify at implementation: read `tree.nodeData(...)` for each callable tag and derive the body node appropriately. Task 1's `buildItemIfCallable` and Task 2's staleness check already switch on these tags; the body-derivation adds one more case per tag.
- **Confirmed:** For `.test_decl`, the body is in `tree.nodeData(test_decl).opt_token_and_node[1].unwrap() orelse return null` — Task 1 already extracts the name token via `[0]`; the body is the `.node` variant. For `.@"comptime"`, it's `tree.nodeData(comptime).node` — the inner block node.
- **Confirmed:** `ast.Walker` API: init(arena, tree, start_node), next(arena, tree) returns `?Event{ .open, .close }`. Task 1's `comptimeBlockContainsCall` demonstrates the pattern. Task 3 walks the fn body node; each `.open` event on a `.call*` tag gets collected.
- **Confirmed:** `Analyser.DeclWithHandle.eql` at `src/analysis.zig:5685`: compares decl and uri. Grouping by callee uses this.

## Design

### Handler structure

Lives in `src/features/call_hierarchy.zig` alongside `incomingCallsHandler`. Signature:

```
pub fn outgoingCallsHandler(
    server: *Server,
    arena: std.mem.Allocator,
    request: types.call_hierarchy.OutgoingCallsParams,
) Server.Error!?[]const types.call_hierarchy.OutgoingCall
```

Private helpers (new):

- `fn bodyNodeFor(tree: *const Ast, node: Ast.Node.Index) ?Ast.Node.Index` — returns the body node to walk for callable tags, null for `.fn_proto*` variants without bodies.
- `fn resolveCallee(analyser: *Analyser, handle: *DocumentStore.Handle, call_node: Ast.Node.Index) !?Analyser.DeclWithHandle` — mirror of `CallBuilder.referenceNode`'s resolution logic without the equality filter. Returns null for calls that can't be resolved (anonymous fn literals, unresolved imports, builtins).

Reuses:
- `decodeItemData` (from Task 2)
- `buildItemIfCallable` (from Task 1)

### Why NOT extend references.CallBuilder

CallBuilder is built around the "filter by target_decl" shape. Repurposing it for outgoing would mean passing a null target that matches everything — ugly, brittle. Outgoing's traversal is single-file (just the target's body), so the workspace-walking machinery is unused weight. Keep outgoing collection self-contained in call_hierarchy.zig; share the resolveCallee helper only.

If later refactoring wants a unified `CallRelation` abstraction over both builders, that's its own task.

### Handling test_decl and comptime outgoing

Different from incoming semantics: these ARE walkable for their body. A `test "name" { foo(); }` has `foo` as an outgoing call. A `comptime { foo(); }` likewise. The bodyNodeFor helper returns the body node for test_decl and comptime exactly like it does for fn_decl.

### Handling fn_proto without body (extern fn, fn prototype inside struct)

`fn_proto*` variants that aren't wrapped by a fn_decl have no body — they declare a signature only. `bodyNodeFor` returns null for these. The handler converts null body → empty `OutgoingCall` slice (applicable, but no callees to find). Not null, because the Item is valid.

### Grouping callees

Linear-scan bucketing, same pattern as Task 2's incoming. Key: `DeclWithHandle.eql` on callee. Value: `ArrayList(Range)` of call ranges (positions in the TARGET's file — fromRanges are relative to the caller per LSP spec).

### Resolving the callee's Item

The callee's decl has an ast_node pointing at its definition (fn_decl, fn_proto, etc.). `buildItemIfCallable` is applied to that node. If the callee's decl points at something non-callable (e.g., a var_decl that holds a fn expression — anonymous fn pattern), buildItemIfCallable returns null. Silently skip these callees — represent-able-as-Item is a precondition for LSP call hierarchy.

### Capability flip

At `src/Server.zig:552-581` add one line among the sibling provider flags:

```
.callHierarchyProvider = .{ .call_hierarchy_options = .{} },
```

Mirrors the `codeActionProvider` style (passes the options struct variant). Placed alphabetically between `definitionProvider` and `referencesProvider` or wherever natural — no functional difference.

## Requirements (from epic zls-xjj, scoped to this task)

- **R3:** `callHierarchy/outgoingCalls` returns all callees grouped by callee, with `fromRanges`, spanning every callee reachable from the target's body — including callees defined in other files via imports.
- **R4 (consumer):** Decode `Item.data.{uri, node}` — reuse Task 2's decoder. Validate shape and staleness before use.
- **R8 (partial):** Share callee-resolution logic with CallBuilder's referenceNode by factoring common patterns. This task does NOT extend CallBuilder itself (its target-filter shape doesn't fit).
- **R9 (partial → complete):** Register `@"callHierarchy/outgoingCalls"` in Server.zig 4 sites AND flip `callHierarchyProvider` capability. This closes R9's wiring scope.
- **R10 (partial):** Tests for single callee, multi-call-to-one-callee grouping, cross-file callee (via @import), callee defined on a struct (field_access callee), test_decl outgoing (non-empty body), comptime outgoing, fn_proto (extern) returns empty, recursive self-call (target is its own callee), unresolved callees (builtins, anonymous fn literals) are silently skipped, decoder adversarial (reuse Task 2's shape but for OutgoingCallsParams).

## Implementation

TDD cycle: test first, run to observe failure, implement, observe pass, commit. Test file: `tests/lsp_features/call_hierarchy.zig` (add to existing).

### Step 1: RED — failing test for single-callee outgoingCalls
**File:** `tests/lsp_features/call_hierarchy.zig`
**Intent:** Source: `fn callee() void {}` + `fn <>target() void { callee(); }`. Prepare at target, take the returned Item, call `outgoingCalls(item)`, expect one OutgoingCall where `to.name = "callee"` with one fromRange covering `callee()`.
**Helper:** Add `testOutgoingCalls(source: []const u8, expected: []const ExpectedCallee)` where `ExpectedCallee = { name, from_ranges }`. Mirror of testIncomingCalls structure.
**Run:** `zig build test -Dtest-filter="outgoing" --summary all`
**Expected failure:** method returns null (not yet registered).

### Step 2: Wire Server.zig (4 sites)
**File:** `src/Server.zig`
**Edits (mirroring Task 2's pattern — insert after incomingCalls lines):**
- Add `fn outgoingCallsHandler(server, arena, request) Error!?[]const types.call_hierarchy.OutgoingCall { return try @import("features/call_hierarchy.zig").outgoingCallsHandler(server, arena, request); }` below Task 2's incomingCallsHandler at ~line 1592.
- Add `@"callHierarchy/outgoingCalls": types.call_hierarchy.OutgoingCallsParams,` to HandledRequestParams union after the incomingCalls entry at ~line 1616.
- Add `.@"callHierarchy/outgoingCalls",` to the non-blocking list at ~line 1662.
- Add dispatch arm `.@"callHierarchy/outgoingCalls" => try server.outgoingCallsHandler(arena, params),` after the incomingCalls dispatch at ~line 1840.
**Run:** `zig build check` — expected compile error until Step 3 adds the stub.

### Step 3: Null-returning outgoingCallsHandler stub
**File:** `src/features/call_hierarchy.zig`
**Add** below `incomingCallsHandler`:
```
pub fn outgoingCallsHandler(
    server: *Server,
    arena: std.mem.Allocator,
    request: types.call_hierarchy.OutgoingCallsParams,
) Server.Error!?[]const types.call_hierarchy.OutgoingCall {
    _ = server;
    _ = arena;
    _ = request;
    return null;
}
```
Note: explicit `_ = name` per parameter — a previous draft had `_ = all;` which is invalid Zig. The stub exists so Server.zig compiles after Step 2; it returns null (not empty slice) deliberately so Step 1's test continues to fail at "expected one OutgoingCall, got null".
**Run:** `zig build check` clean. Step 1 test still fails at null-response.

### Step 4: Implement bodyNodeFor helper (private)
**File:** `src/features/call_hierarchy.zig`
**Add** (lowercase `fn`, no `pub` — module-private like `comptimeBlockContainsCall`):
```
fn bodyNodeFor(tree: *const Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    switch (tree.nodeTag(node)) {
        .fn_decl => return tree.nodeData(node).node_and_node[1],
        .test_decl => return tree.nodeData(node).opt_token_and_node[1].unwrap() orelse null,
        .@"comptime" => return tree.nodeData(node).node,
        .fn_proto, .fn_proto_one, .fn_proto_multi, .fn_proto_simple => return null, // prototype — no body
        else => return null,
    }
}
```
**Verified accessors:**
- `.fn_decl`: `.node_and_node[1]` is the body block — used at `src/analysis.zig:850`.
- `.test_decl`: `.opt_token_and_node[0]` is the name token (Task 1 uses this at call_hierarchy.zig:101); `[1]` is the body. Use `orelse null` to defend against test_decl variants without bodies (per the adversarial catalog — never panic on `.unwrap()`).
- `.@"comptime"`: `.node` is the inner block — used at `src/analysis.zig:2092`.

No test run yet — helper is consumed in Step 6.

### Step 5: Implement resolveCallee helper (private)
**File:** `src/features/call_hierarchy.zig`
**Add** (lowercase `fn`, no `pub`):
```
fn resolveCallee(
    analyser: *Analyser,
    handle: *DocumentStore.Handle,
    call_node: Ast.Node.Index,
) Analyser.Error!?Analyser.DeclWithHandle {
    // Mirror src/features/references.zig:614-647 (CallBuilder.referenceNode's
    // .identifier and .field_access branches) WITHOUT the target_decl.eql filter.
    // Differences from the source:
    //   - Return the resolved DeclWithHandle instead of conditionally appending
    //     to a builder.
    //   - Call expressions whose `called_node` is neither .identifier nor
    //     .field_access return null (e.g., paren-wrapped, anonymous fn literals,
    //     immediately-invoked call results — these resolve to dynamic values,
    //     not named decls).
}
```
The implementation:
1. `tree.fullCall(&buf, call_node).?` — caller has already filtered to `.call*` tags so unwrap is safe.
2. Switch on `tree.nodeTag(call.ast.fn_expr)`.
3. `.identifier` branch: use `ast.identifierTokenFromIdentifierNode` + `analyser.lookupSymbolGlobal` (mirror references.zig:622-628). Return the lookup result directly.
4. `.field_access` branch: use `tree.nodeData(called_node).node_and_token` + `analyser.resolveTypeOfNode` + `analyser.resolveDerefType` + `lookupSymbol` (mirror references.zig:635-640). Return the lookup result directly.
5. Default: return null.

**Important:** The error type is `Analyser.Error!?DeclWithHandle` (matching `referenceNode`'s `Analyser.Error!void`). Using `!?` (anyerror) instead would swallow type info and complicate handler error propagation.

No test run yet — consumed in Step 6.

### Step 6: GREEN — implement outgoingCallsHandler (single-file)
**File:** `src/features/call_hierarchy.zig`
**Flow:**
1. Decode `request.item.data` via `decodeItemData`. Return null if decode fails.
2. Parse URI, get handle, bounds + callable tag validation — mirror incomingCallsHandler's guard.
3. Compute body node via `bodyNodeFor`. If null (fn_proto without body), return empty slice `&.{}`.
4. Initialize analyser via `server.initAnalyser(arena, handle)`.
5. Walk the body with `ast.Walker`, collect all `.call*` node indices into `ArrayList(Ast.Node.Index)`. Skip the body node itself (it's the root of the walk) — only descendants.
6. For each call_node: `resolveCallee(&analyser, handle, call_node)` → maybe DeclWithHandle. Skip nulls silently.
7. Group by resolved callee DeclWithHandle (linear scan with `.eql`). Each bucket holds the callee's (handle, ast_node) and a list of call ranges.
8. For each bucket: `to` = `buildItemIfCallable(arena, callee_handle.uri, &callee_handle.tree, callee_ast_node, null, encoding)`. If buildItemIfCallable returns null (callee points at non-callable, e.g., var_decl holding an anonymous fn), skip the bucket.
9. `fromRanges` = ranges from the TARGET's file (each call_node's range, computed against the target handle's tree).
10. Return `arena.dupe(OutgoingCall, collected.items)`.
**Run:** Step 1 test passes.
**Commit:** "feat(call-hierarchy): outgoingCalls handler with callee grouping (zls-a9k)"

### Step 7: RED+GREEN — multiple calls to same callee collapse into one OutgoingCall
**Test:** `fn c() void {} fn <>t() void { c(); c(); c(); }`. Expect one OutgoingCall to `c` with 3 fromRanges.
**Commit:** "test(call-hierarchy): outgoing multi-call-to-one-callee grouping (zls-a9k)"

### Step 8: RED+GREEN — cross-file callee via @import
**Test:** File A defines `pub fn callee() void {}`. File B imports A and has `fn <>target() void { a.callee(); }`. Prepare at target in B, outgoingCalls returns OutgoingCall to `callee` with `to.uri = uri_A`.
**Commit:** "test(call-hierarchy): outgoing cross-file callee (zls-a9k)"

### Step 9: RED+GREEN — field_access callee (method on struct)
**Test:** `const S = struct { pub fn foo(self: S) void {} }; fn <>target() void { var s: S = undefined; s.foo(); }`. Expect OutgoingCall to `foo`. Verifies resolveCallee's field_access branch works.
**Commit:** "test(call-hierarchy): outgoing field_access callee (zls-a9k)"

### Step 10: RED+GREEN — test_decl and comptime body are walked
**Tests:**
- `fn foo() void {} test \"<>named\" { foo(); }` → OutgoingCall to `foo`.
- `fn foo() void {} <>comptime { foo(); }` → OutgoingCall to `foo`.
Differs from incoming where these returned empty — outgoing walks their body.
**Commit:** "test(call-hierarchy): outgoing on test_decl and comptime walks body (zls-a9k)"

### Step 11: RED+GREEN — fn_proto (extern) returns empty slice
**Test:** `extern fn <>ext(a: i32) i32;`. Prepare returns an Item; outgoingCalls returns empty slice (no body to walk).
**Commit:** "test(call-hierarchy): outgoing on extern fn returns empty (zls-a9k)"

### Step 12: RED+GREEN — unresolved callees are silently skipped
**Important correction (vs prior draft):** The earlier draft listed `@import("std")` as a "builtin call that returns null from resolveCallee" — this is wrong at the AST layer. `@`-builtins parse to `.builtin_call`, `.builtin_call_two`, `.builtin_call_two_comma`, `.builtin_call_comma` — NOT `.call`/`.call_one`/`.call_comma`/`.call_one_comma`. The Step 6 walker filters to the `.call*` set BEFORE invoking resolveCallee, so builtins never reach the resolver. The "builtin handling" is structural in the tag filter, not in resolveCallee.

**Actual unresolved-callee paths that DO reach resolveCallee and return null:**
- An anonymous fn literal: `fn <>target() void { (fn() void {})(); }` — `called_node` is `.fn_proto*` with no name token, doesn't match `.identifier` or `.field_access` → resolveCallee returns null.
- A paren-wrapped expression: `fn <>target() void { (g)(); }` (assuming `g` is in scope) — `called_node` is a paren expression, not `.identifier` → falls through resolveCallee's switch default to null.
- An undefined identifier: `fn <>target() void { not_defined(); }` — `.identifier` branch hits `lookupSymbolGlobal`, returns null → resolveCallee propagates null.

**Test cases:**
- Anonymous fn literal as callee → 0 OutgoingCalls.
- Paren-wrapped identifier as callee → 0 OutgoingCalls (documented limitation per Adversarial Failure Catalog).
- Undefined identifier callee → 0 OutgoingCalls.
- Result in all cases: OutgoingCall slice is empty (NOT null) — handler ran successfully, just nothing resolved.
**Commit:** "test(call-hierarchy): outgoing silently skips unresolved callees (zls-a9k)"

### Step 12.5: RED+GREEN — multiple distinct callees produce multiple OutgoingCalls
**Test:** `fn a() void {} fn b() void {} fn c() void {} fn <>target() void { a(); b(); c(); }`. Expect THREE OutgoingCalls with distinct `to.name` ("a", "b", "c") each with one fromRange. Verifies the bucket-creation path (each unresolved-callee comparison falls through to the new-bucket branch). Without this test, a buggy implementation that always reuses the first bucket would still pass Steps 1+7.
**Commit:** "test(call-hierarchy): outgoing distinct callees produce distinct OutgoingCalls (zls-a9k)"

### Step 12.6: RED+GREEN — recursive self-call appears as outgoing
**Test:** `fn <>rec() void { rec(); }`. Expect one OutgoingCall whose `to.name == "rec"` and `to.uri == target's uri`. Verifies that grouping doesn't dedup the target itself — recursive calls are first-class outgoing per LSP semantics.
**Commit:** "test(call-hierarchy): outgoing recursive self-call (zls-a9k)"

### Step 12.7: RED+GREEN — mixed resolved + unresolved callees
**Test:** `fn known() void {} fn <>target() void { known(); not_defined(); known(); }`. Expect ONE OutgoingCall to `known` with TWO fromRanges (the resolved ones); the unresolved `not_defined()` call is silently skipped without affecting the resolved bucket. Catches a class of bugs where null-callee handling accidentally short-circuits the loop or contaminates the bucket.
**Commit:** "test(call-hierarchy): outgoing mixed resolved + unresolved callees (zls-a9k)"

### Step 13: Flip callHierarchyProvider capability
**File:** `src/Server.zig`
**Edit:** Add `.callHierarchyProvider = .{ .call_hierarchy_options = .{} },` to the capabilities block at ~line 552-581, alongside the other provider flags. Placement: between `definitionProvider` and `typeDefinitionProvider` or wherever natural — no functional difference.
**Run:** `zig build check` clean.
**Commit:** "feat(call-hierarchy): advertise callHierarchyProvider capability (zls-a9k)"

### Step 14: Pre-close verification + criteria + push
**Commands:**
- `zig build test --summary all` → all tests pass. Per the noise-tolerance reference (zig build test cosmetic "failed command" line is non-authoritative), trust Build Summary + exit code, not isolated stderr lines.
- `zig build check` → clean.
- `zig fmt --check .` → clean.
**Criteria update:** Check off all 19 task-local criteria in `.bones/tasks/zls-a9k.md` (only after each is independently verified). Update zls-gyi: check off the two outgoingCalls criteria + the capability criterion. Leave only the live-demo criterion unchecked — that's the acceptance task's responsibility, not Task 3's.
**Push:** `git push` (bare). If `git push` fails (no upstream, rejected), surface as a blocker via AskUserQuestion — do NOT autonomously specify remote/branch.

## Success Criteria

- [x] `src/Server.zig` registers `@"callHierarchy/outgoingCalls"` in all 4 sites with thin wrapper `outgoingCallsHandler`
- [x] `src/features/call_hierarchy.zig` exports `outgoingCallsHandler` with signature `Server.Error!?[]const types.call_hierarchy.OutgoingCall`
- [x] `src/features/call_hierarchy.zig` has private `bodyNodeFor` helper switching on fn_decl / test_decl / @"comptime" / fn_proto variants (no `pub`)
- [x] `src/features/call_hierarchy.zig` has private `resolveCallee` helper mirroring CallBuilder.referenceNode's resolution (identifier + field_access) without the target filter (no `pub`)
- [x] `outgoingCallsHandler` reuses Task 2's `decodeItemData` for Item.data parsing — no inline JSON decoding
- [x] `src/Server.zig` advertises `callHierarchyProvider` in the InitializeResult capabilities block
- [x] `src/features/references.zig` is NOT modified by this task — Task 2's CallBuilder + wrapper remain untouched
- [x] Test: single callee returns one OutgoingCall with one fromRange
- [x] Test: multiple calls to one callee collapse into one OutgoingCall with N fromRanges
- [x] Test: multiple distinct callees produce one OutgoingCall each (Step 12.5)
- [x] Test: recursive self-call appears as outgoing pointing back at target (Step 12.6)
- [x] Test: mixed resolved + unresolved callees — only resolved ones appear, no error (Step 12.7)
- [x] Test: cross-file callee via `@import` is found (callee's Item has the other file's URI)
- [x] Test: field_access callee (method on struct type) is found
- [x] Test: outgoingCalls on test_decl walks the test body
- [x] Test: outgoingCalls on comptime block walks the block
- [x] Test: outgoingCalls on extern fn_proto (no body) returns empty slice (not null)
- [x] Test: unresolved callees (anonymous fn literals, paren-wrapped, undefined identifiers) are silently skipped — empty slice, not error
- [x] `zig build test --summary all` passes (648/659, 11 skipped)
- [x] `zig build check` compiles clean
- [x] `zig fmt --check .` passes

## Anti-Patterns (FORBIDDEN for this task)

- **Extending references.CallBuilder to do outgoing.** Its shape (filter by target_decl) doesn't fit outgoing's accept-everything traversal. Adding a "match all" sentinel is an anti-pattern; keep outgoing self-contained in call_hierarchy.zig.
- **Modifying `src/features/references.zig` at all.** Task 3 is self-contained in call_hierarchy.zig. Task 2 sealed CallBuilder + the thin wrapper. Any edit to references.zig in this task is out of scope and risks regressing the wrapper-preservation guarantee that callsiteReferences depends on.
- **Walking the entire workspace for outgoingCalls.** The target fn's body is self-contained — walking other files is wasted work and could produce bogus "callees" from unrelated code.
- **Returning null for fn_proto without body.** Prototypes are valid Items; they just have no body. Return empty slice (`&.{}`), not null. Null is reserved for "item data malformed".
- **Advertising the capability before the handler is wired.** The flag must be added in the SAME commit as (or after) the handler registration — otherwise clients see a capability they can call but gets `.other` null response.
- **Silently failing on unresolved callees (e.g., via a swallowing catch block).** The design is "skip, don't error" — but the code path must be a deliberate `?DeclWithHandle` null return, not an error-swallowing kludge. Makes the skip visible in code.
- **Calling `.unwrap()` without `orelse return null` in bodyNodeFor.** Per the adversarial catalog, any nullable Ast accessor must defensively handle the null case. Panicking on parse-recovery edge cases (test_decl variants without bodies, malformed comptime nodes) breaks the LSP contract that handlers must not crash on syntactically-valid-but-incomplete source.

## Key Considerations

### bodyNodeFor exact accessors (verify during implementation)

From the codebase verification: each callable tag uses a different `tree.nodeData` variant.

- `.fn_decl`: `tree.nodeData(node).node_and_node[1]` — the second node is the block body (first is the fn_proto prototype).
- `.test_decl`: `tree.nodeData(node).opt_token_and_node[1].unwrap() orelse null` — the `orelse null` IS the defensive handling. NEVER `.unwrap() orelse unreachable` — the adversarial catalog requires no panics on parse-recovery edge cases. If `[1]` is null for any test_decl variant, propagate as "no body".
- `.@"comptime"`: `tree.nodeData(node).node`.
- `.fn_proto*` (any variant, NOT wrapped in fn_decl): no body node — return null so handler returns empty slice.

Verify each accessor against Zig master's Ast module during implementation — the `nodeData` union tags have been stable but worth spot-checking. Fall back to `ast.fullFnProto(...).body` if the direct accessor proves wrong; fn_proto's body is always null so this won't conflict.

### Recursion handling

If target calls itself (`fn rec() void { rec(); }`), resolveCallee resolves the callee to the same decl as the target. The resulting OutgoingCall has `to.uri = target's uri` and `to.range = target's range`. This is correct LSP semantics — recursive calls appear in outgoing results exactly like any other call.

### fromRanges semantic

Per LSP spec, OutgoingCall.fromRanges are ranges "relative to the caller" — positions in the TARGET's file, covering each call expression. This is `offsets.nodeToRange(&target_handle.tree, call_node, encoding)` for each call inside the body. Do NOT use the callee's file — that would be wrong even for cross-file callees.

### Callees that aren't callable (var_decl holding a fn)

Pattern `const f = other_fn; f();` — resolveCallee resolves `f` to `var_decl`. Then `buildItemIfCallable` on var_decl returns null (var_decl isn't a callable tag). Skip silently — a future task could follow the alias chain, but for Task 3's scope, non-callable decls are non-representable.

### Adversarial Failure Catalog

Each component is walked through all six failure categories: Input Hostility, Encoding Boundaries, Temporal Betrayal, Dependency Treachery, State Corruption, Resource Exhaustion. Categories that genuinely don't apply are noted with reasoning.

#### outgoingCallsHandler

**Input Hostility: Item.data points at a DIFFERENT callable post-edit**
- Assumption: bounds check + tag check (Step 6 substep 2) is sufficient to detect Item staleness.
- Betrayal: Same node index now points at a different callable after an edit shifted the AST. Tag still matches (`.fn_decl` → `.fn_decl`), bounds still in range — but the bucket grouping walks the WRONG function's body and returns its callees as if they were the original target's.
- Consequence: Silent corruption — handler returns plausible-looking but semantically wrong OutgoingCalls. Worse than a crash; the caller has no way to detect.
- Mitigation: Accept as design limit. LSP call hierarchy is stateless between requests; clients re-prepare after document changes per the spec. Document in Out of Scope (no checksum/version field on Item.data). Acceptable because the handler runs in milliseconds — staleness window is small.

**Encoding Boundaries: uri_raw from decodeItemData carries non-UTF-8 bytes**
- Assumption: `decoded.uri_raw` is a valid UTF-8 string parseable by `Uri.parse`.
- Betrayal: lsp_kit's JSON parser may admit non-UTF-8 bytes in JSON strings (some JSON spec interpretations allow it). A malicious or buggy client could send arbitrary bytes in `data.uri`.
- Consequence: `Uri.parse` returns `error.InvalidParams` (or similar). Handler returns null gracefully.
- Mitigation: Structural — Step 6 substep 2's `Uri.parse catch` already maps any URI error to `return null`. Same shape as incomingCallsHandler.

**Temporal Betrayal: Target body edited mid-request**
- Assumption: target's tree stable for request lifetime.
- Betrayal: DocumentStore guarantees per-request snapshot. Shared invariant inherited from Server.zig's request-handling architecture.
- Consequence: None — invariant holds.
- Mitigation: None new.

**Dependency Treachery: server.initAnalyser allocation failure**
- Assumption: `server.initAnalyser(arena, handle)` succeeds.
- Betrayal: Out of memory during analyser initialization (pathological under heap pressure).
- Consequence: `error.OutOfMemory` propagates as `Server.Error.OutOfMemory`. LSP framework returns an error response. No partial state.
- Mitigation: Structural — error propagation via `try`. Arena allocator means partial work is cleaned up on request end.

**State Corruption: Concurrent outgoingCalls requests on the same Item**
- Assumption: Two concurrent requests do not interfere.
- Betrayal: Both hit the same handle, but the handler only reads (no mutation). Each request gets its own arena.
- Consequence: None — handler is read-only.
- Mitigation: Structural — read-only access pattern with per-request arenas.

**Resource Exhaustion: Target with 10,000 calls in body**
- Assumption: O(body_size) walk + O(callees²) grouping is cheap.
- Betrayal: Target is a massive function (stdlib `std.fmt.formatType`-level complexity).
- Consequence: Slow outgoingCalls response (seconds).
- Mitigation: Accept for Task 3. `partialResultToken` is in the params but unimplemented — documented in Out of Scope. Future work: chunked partial results.

**Resource Exhaustion: Deeply-nested call expression `f(g(h(i(j()))))`**
- Assumption: ast.Walker handles arbitrary AST nesting depth.
- Betrayal: Expression depth could in principle exceed system stack on adversarially-deep input.
- Consequence: Stack overflow during walk.
- Mitigation: ast.Walker uses an explicit stack (heap-allocated via arena), not recursion — verified by Task 1's `comptimeBlockContainsCall`. Structural.

#### bodyNodeFor

**Input Hostility: Node passed in is not actually a callable tag**
- Assumption: Caller (outgoingCallsHandler) has filtered to callable tags upstream.
- Betrayal: Refactor breaks the upstream filter; bodyNodeFor receives a `var_decl` or other non-callable tag.
- Consequence: Falls through `else => return null` — handler returns empty slice. No crash.
- Mitigation: Structural via switch — `else` branch is the safety net.

**Input Hostility: test_decl without body**
- Assumption: `.opt_token_and_node[1]` is non-null for normal source.
- Betrayal: Parser produces a test_decl with `[1]` null on error recovery (malformed test syntax).
- Consequence: Without `orelse null`, `.unwrap()` would panic. With it, returns null → handler returns empty slice.
- Mitigation: `orelse null` pattern is locked into Step 4's code AND in the anti-patterns section.

**Encoding Boundaries:** N/A — operates purely on AST node indices, no text. Skip.

**Temporal Betrayal:** N/A — pure function of current tree state, no history dependency. Skip.

**Dependency Treachery:** N/A — only depends on `*const Ast` (passed by ref). No external calls. Skip.

**State Corruption:** N/A — stateless function. Skip.

**Resource Exhaustion:** N/A — O(1) switch dispatch with constant-time accessors. Skip.

#### resolveCallee

**Input Hostility: Call via method chain / parenthesized expression**
- Assumption: `call.ast.fn_expr` is `.identifier` or `.field_access`.
- Betrayal: Call via `(f)()` wraps in parens; `get_fn().run()` has a call expression as the fn_expr.
- Consequence: Neither branch matches; resolveCallee returns null. Callee silently missing from results.
- Mitigation: Accept as limitation (these patterns resolve to dynamic values, not named decls). Documented in Out of Scope. Step 12 explicitly tests this. Future work: resolve through parens and call chains.

**Input Hostility: Generic function call**
- Assumption: lookupSymbolGlobal returns the fn_decl for a generic fn.
- Betrayal: For generics, ZLS may resolve to a different decl representation depending on instantiation context.
- Consequence: The returned decl may not point at a fn_decl ast_node → buildItemIfCallable returns null → callee skipped.
- Mitigation: Match existing CallBuilder behaviour. If incoming correctly handles generics, outgoing inherits the correctness.

**Encoding Boundaries: Identifier with multi-byte chars (`@"αβ"()`)**
- Assumption: `ast.identifierTokenFromIdentifierNode` + `lookupSymbolGlobal` handle quoted-identifier syntax + UTF-8 bytes.
- Betrayal: Token slice contains multi-byte UTF-8; case-sensitive byte comparison is used by lookupSymbolGlobal.
- Consequence: Resolution succeeds when callee is the same byte sequence (which it must be — no Unicode case folding in Zig identifiers).
- Mitigation: Structural — Zig identifier rules guarantee byte-identical match. Verified by existing testPrepare quoted-identifier cases.

**Temporal Betrayal:** N/A — operates within a stable tree snapshot per handler request lifetime. Skip.

**Dependency Treachery: resolveTypeOfNode on field_access LHS fails**
- Assumption: LHS of `a.foo()` resolves to a type that has `foo`.
- Betrayal: LHS type is unresolved (missing import, parse error, generic instantiation hole).
- Consequence: resolveCallee returns null → callee skipped.
- Mitigation: Structural — silent skip is the design (matches CallBuilder.referenceNode's `orelse return`).

**Dependency Treachery: lookupSymbolGlobal returns a decl with no usable ast_node**
- Assumption: Resolved decl points at a fn_decl/fn_proto* node.
- Betrayal: Decl is `.label`, `.error_token`, or another non-ast_node variant.
- Consequence: buildItemIfCallable in Step 6 substep 8 returns null → bucket skipped.
- Mitigation: Structural — buildItemIfCallable's tag switch is the gate. Step 6 substep 8 explicitly handles the null return.

**State Corruption:** N/A — stateless lookup over Analyser cache (which is per-request). Skip.

**Resource Exhaustion:** N/A — single lookup per call site, bounded by scope/symbol-table size. No unbounded recursion. Skip.

#### Server.zig wiring (4 sites)

**Input Hostility: Client sends `callHierarchy/outgoingCalls` before `prepareCallHierarchy`**
- Assumption: Client follows the LSP protocol order (prepare first, then incoming/outgoing).
- Betrayal: Buggy or malicious client constructs Item directly with arbitrary `data`.
- Consequence: decodeItemData returns null → handler returns null → client sees null response.
- Mitigation: Structural — decode-and-validate gate is the first thing the handler does.

**Input Hostility: Client sends Item.data from a DIFFERENT server's prepare**
- Assumption: Item.data shape is consistent across server versions.
- Betrayal: Old server used a different data encoding (e.g., position-based instead of node-index-based). Cached client state survives a server restart with new ZLS.
- Consequence: decodeItemData fails the shape check → returns null → handler returns null.
- Mitigation: Structural — decoder is shape-strict. No fallback to "guess the encoding."

**Encoding Boundaries:** N/A — wiring is structural code dispatch, not data processing. Skip.

**Temporal Betrayal: Client cached capabilities from a prior server session**
- Assumption: Client re-queries capabilities on every server restart.
- Betrayal: Persistent client state caches capabilities across server restarts.
- Consequence: Either client ignores the flag (calling a method we now support) or refuses to call (cache says no support). Both are LSP protocol violations on the client side.
- Mitigation: Structural — LSP spec mandates re-initialize. Not a server concern. (Same finding as Capability flag → kept here for completeness in this component's walk; cross-referenced.)

**Dependency Treachery:** N/A — wiring is internal compile-time dispatch. No external calls. Skip.

**State Corruption: Union variant ordering and JSON serialization**
- Assumption: Adding a new variant to HandledRequestParams doesn't alter existing variants' serialization.
- Betrayal: Some union(enum) JSON serializers in Zig depend on variant order. lsp_kit uses tag-name-keyed union JSON, which is order-independent.
- Consequence: None — variants are tag-keyed.
- Mitigation: Structural — verified by lsp_kit's union JSON pattern.

**Resource Exhaustion:** N/A — wiring is constant-time per request. Skip.

#### callHierarchyProvider capability (Step 13)

**Input Hostility:** N/A — capability flag is server-emitted JSON, not consumed at runtime. Skip.

**Encoding Boundaries:** N/A — boolean/struct value, no text. Skip.

**Temporal Betrayal: Client caches capabilities from prior session**
- See Server.zig wiring entry above. Same mitigation.

**Dependency Treachery: Client receives capability but never invokes the method**
- Assumption: Capability advertisement matches actual usage.
- Betrayal: Client uses a different LSP feature subset and ignores callHierarchyProvider entirely.
- Consequence: The flag is dead code from this client's POV. No correctness issue, just unexercised path.
- Mitigation: Acceptance task's live demo (zls-gyi) verifies a real client (Claude Code's LSP tool) actually invokes the methods. Structural — covered by acceptance gate.

**State Corruption:** Same as "client caches capabilities" — see above.

**Resource Exhaustion:** N/A — single boolean/struct field, constant cost. Skip.

#### Test infrastructure (testOutgoingCalls helper)

**Input Hostility: Test source with unusual line endings**
- Assumption: Test sources use `\n` line endings.
- Betrayal: A future test author writes a CRLF source (`\r\n`).
- Consequence: `offsets.locToRange` computes positions as utf-16 code units; CRLF is two code units. If position calculation is off, the placeholder `<>` resolves at the wrong byte → test sees null prepare response.
- Mitigation: Existing `helper.collectClearPlaceholders` handles `\n` only; CRLF would be a setup error caught at test development time, not a runtime hazard. Structural — established convention.

**Encoding Boundaries: Multi-byte chars in test source**
- Assumption: utf-16 position math is correct for multi-byte UTF-8 source.
- Betrayal: Test source contains identifiers like `@"αβ"`.
- Consequence: Existing testPrepare cases (call_hierarchy.zig:167-179) verify this works. Inherited.
- Mitigation: Structural — covered by Phase 2's existing test infrastructure verification.

**Temporal Betrayal:** N/A — each test gets a fresh Context (per `Context.init()`). Skip.

**Dependency Treachery: Cross-file `@import("Untitled-N.zig")` resolution**
- Assumption: addDocument's `untitled://Untitled-N.zig` URI scheme allows `@import` resolution between test documents.
- Betrayal: If addDocument's URI synthesis breaks, cross-file tests (Step 8) silently see no callees.
- Consequence: Step 8 test would fail at "expected 1 OutgoingCall, got 0" — caught by test assertion.
- Mitigation: Structural — verified by Task 2's tests/lsp_features/references.zig:304-351 cross-file pattern (per project_call_hierarchy_epic.md memory).

**State Corruption:** N/A — fresh Context per test, no shared mutable state. Skip.

**Resource Exhaustion:** N/A — small in-memory test sources, bounded by helper buffer sizes. Skip.

## Out of Scope

- Paren-wrapped and chained call expressions as outgoing callees (e.g., `(f)()`, `get_fn().run()`) — documented as known limitation.
- partialResultToken streaming support (present in OutgoingCallsParams but unimplemented).
- Main `Builder` rewrite (still deferred — not required for any of Phase 2 tasks).
- Live narrated LSP demo — that's the acceptance task, scheduled after Task 3 closes.

## Log

- [2026-04-15T08:13:26Z] [Seth] Debrief: All 21 task-local criteria met. 13 happy-path + 14 adversarial = 27 new tests. Full suite 648/659 (11 skipped, 0 fail). Commits: f7447b9d (handler+tests), fa63f2dc (capability flip), e37b6fcb (adversarial battery). Design surprise: opt_token_and_node[1] is Ast.Node.Index (non-optional), not Optional — the skeleton's defensive .unwrap() orelse null was wrong API shape. Caught during compile, fixed in-place. resolveCallee mirrors CallBuilder.referenceNode .identifier+.field_access with Analyser.Error!? return (matches CallBuilder's error signature). Bucket grouping uses DeclWithHandle.eql; var_decl-holding-fn pattern is correctly filtered by buildItemIfCallable's tag check. Three-Question Framework on all 14 GREEN adversarial: decoder+bounds+tag pipeline shape-strict (same gate as incoming), handler stateless across requests (idempotency structural), quoted-identifier works via byte-identical Zig semantics, O(callees²) bucket grouping acceptable at moderate scale. No out-of-scope concerns escalated.
