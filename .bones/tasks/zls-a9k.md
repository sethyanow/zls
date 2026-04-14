---
id: zls-a9k
title: 'Phase 2 Task 3: outgoingCalls handler + callee grouping + capability flip'
status: open
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
- **Confirmed:** Server capabilities block at `src/Server.zig:552-581` declares all provider flags. callHierarchyProvider goes alongside definitionProvider, referencesProvider, etc. lsp_kit type at `lsp_types.zig:3571`: `callHierarchyProvider: ?CallHierarchyOptions = null` where `CallHierarchyOptions = struct { workDoneProgress: ?bool = null }`. A minimal opt-in is `.callHierarchyProvider = .{ .call_hierarchy_options = .{} }` (mirroring how `codeActionProvider` sets options at line 551).
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
**Add:** `pub fn outgoingCallsHandler(server, arena, request) Server.Error!?[]const types.call_hierarchy.OutgoingCall { _ = all; return null; }` — below incomingCallsHandler.
**Run:** `zig build check` clean. Step 1 test still fails at null-response.

### Step 4: Implement bodyNodeFor helper
**File:** `src/features/call_hierarchy.zig`
**Add:**
```
fn bodyNodeFor(tree: *const Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    switch (tree.nodeTag(node)) {
        .fn_decl => /* second node from tree.nodeData */,
        .test_decl => /* .opt_token_and_node[1].unwrap() */,
        .@"comptime" => /* .node */,
        .fn_proto, .fn_proto_one, .fn_proto_multi, .fn_proto_simple => return null, // prototype — no body
        else => return null,
    }
}
```
No test run yet — consumed in Step 6.

### Step 5: Implement resolveCallee helper
**File:** `src/features/call_hierarchy.zig`
**Add:**
```
fn resolveCallee(
    analyser: *Analyser,
    handle: *DocumentStore.Handle,
    call_node: Ast.Node.Index,
) !?Analyser.DeclWithHandle {
    // Extract called_node from tree.fullCall, switch on its tag —
    // .identifier → lookupSymbolGlobal; .field_access → resolveTypeOfNode
    // + lookupSymbol. Mirror CallBuilder.referenceNode WITHOUT the
    // target_decl.eql(child) filter. Return the resolved DeclWithHandle
    // or null for unresolved / non-identifier / non-field-access callees.
}
```
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

### Step 12: RED+GREEN — unresolved callees (builtins, anonymous fn)
**Tests:**
- Target body contains `@import("std")` — builtin call, resolveCallee returns null — excluded from results.
- Target body invokes an anonymous fn literal `(fn() void {})()` — can't resolve to a named decl — excluded.
- Result: OutgoingCall list contains only resolved callees, no errors.
**Commit:** "test(call-hierarchy): outgoing silently skips unresolved callees (zls-a9k)"

### Step 13: Flip callHierarchyProvider capability
**File:** `src/Server.zig`
**Edit:** Add `.callHierarchyProvider = .{ .call_hierarchy_options = .{} },` to the capabilities block at ~line 552-581, alongside the other provider flags. Placement: between `definitionProvider` and `typeDefinitionProvider` or wherever natural — no functional difference.
**Run:** `zig build check` clean.
**Commit:** "feat(call-hierarchy): advertise callHierarchyProvider capability (zls-a9k)"

### Step 14: Pre-close verification + criteria + push
**Commands:**
- `zig build test --summary all` → all tests pass.
- `zig build check` → clean.
- `zig fmt --check .` → clean.
**Criteria update:** Check off 15 task-local criteria in `.bones/tasks/zls-a9k.md`. Update zls-gyi: outgoingCalls criteria + capability criterion. Leave only the live-demo criterion unchecked (acceptance task's responsibility).
**Push:** `git push` (bare).

## Success Criteria

- [ ] `src/Server.zig` registers `@"callHierarchy/outgoingCalls"` in all 4 sites with thin wrapper `outgoingCallsHandler`
- [ ] `src/features/call_hierarchy.zig` exports `outgoingCallsHandler` with signature `Server.Error!?[]const types.call_hierarchy.OutgoingCall`
- [ ] `src/features/call_hierarchy.zig` has private `bodyNodeFor` helper switching on fn_decl / test_decl / @"comptime" / fn_proto variants
- [ ] `src/features/call_hierarchy.zig` has private `resolveCallee` helper mirroring CallBuilder.referenceNode's resolution (identifier + field_access) without the target filter
- [ ] `src/Server.zig` advertises `callHierarchyProvider` in the InitializeResult capabilities block
- [ ] Test: single callee returns one OutgoingCall with one fromRange
- [ ] Test: multiple calls to one callee collapse into one OutgoingCall with N fromRanges
- [ ] Test: cross-file callee via `@import` is found (callee's Item has the other file's URI)
- [ ] Test: field_access callee (method on struct type) is found
- [ ] Test: outgoingCalls on test_decl walks the test body
- [ ] Test: outgoingCalls on comptime block walks the block
- [ ] Test: outgoingCalls on extern fn_proto (no body) returns empty slice (not null)
- [ ] Test: unresolved callees (builtins like `@import`, anonymous fn literals) are silently skipped
- [ ] `zig build test --summary all` passes
- [ ] `zig build check` compiles clean
- [ ] `zig fmt --check .` passes

## Anti-Patterns (FORBIDDEN for this task)

- **Extending references.CallBuilder to do outgoing.** Its shape (filter by target_decl) doesn't fit outgoing's accept-everything traversal. Adding a "match all" sentinel is an anti-pattern; keep outgoing self-contained in call_hierarchy.zig.
- **Walking the entire workspace for outgoingCalls.** The target fn's body is self-contained — walking other files is wasted work and could produce bogus "callees" from unrelated code.
- **Returning null for fn_proto without body.** Prototypes are valid Items; they just have no body. Return empty slice (`&.{}`), not null. Null is reserved for "item data malformed".
- **Advertising the capability before the handler is wired.** The flag must be added in the SAME commit as (or after) the handler registration — otherwise clients see a capability they can call but gets `.other` null response.
- **Silently failing on unresolved callees (e.g., via a swallowing catch block).** The design is "skip, don't error" — but the code path must be a deliberate `?DeclWithHandle` null return, not an error-swallowing kludge. Makes the skip visible in code.

## Key Considerations

### bodyNodeFor exact accessors (verify during implementation)

From the codebase verification: each callable tag uses a different `tree.nodeData` variant.

- `.fn_decl`: `tree.nodeData(node).node_and_node[1]` — the second node is the block body (first is the fn_proto prototype).
- `.test_decl`: `tree.nodeData(node).opt_token_and_node[1].unwrap() orelse unreachable` — but if this is null for some test_decl variants (e.g., decls without bodies — do those exist?), treat as "no body" and return null.
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

#### resolveCallee

**Input Hostility: Call via method chain / parenthesized expression**
- Assumption: `call.ast.fn_expr` is `.identifier` or `.field_access`.
- Betrayal: Call via `(f)()` wraps in parens; `get_fn().run()` has a call expression as the fn_expr.
- Consequence: Neither branch matches; resolveCallee returns null. Callee silently missing from results.
- Mitigation: Accept this as a limitation — these call patterns resolve to dynamic values, not named decls. Document in Key Considerations. Future work: resolve through parens and call chains.

**Input Hostility: Generic function call**
- Assumption: lookupSymbolGlobal returns the fn_decl for a generic fn.
- Betrayal: For generics, ZLS may resolve to a different decl representation depending on instantiation context.
- Consequence: The returned decl may not point at a fn_decl ast_node → buildItemIfCallable returns null → callee skipped.
- Mitigation: Match existing CallBuilder behaviour. If incoming correctly handles generics, outgoing inherits the correctness.

**Dependency Treachery: resolveTypeOfNode on field_access LHS fails**
- Assumption: LHS of `a.foo()` resolves to a type that has `foo`.
- Betrayal: LHS type is unresolved (missing import, error in parse).
- Consequence: resolveCallee returns null → callee skipped.
- Mitigation: Structural — silent skip is already the design.

#### outgoingCallsHandler

**Temporal Betrayal: Target body edited mid-request**
- Assumption: target's tree stable for request lifetime.
- Betrayal: DocumentStore guarantees this per-request. Shared invariant inherited.
- Mitigation: None new.

**Resource Exhaustion: Target with 10,000 calls in body**
- Assumption: O(body_size) walk + O(callees²) grouping is cheap.
- Betrayal: Target is a massive function (stdlib `std.fmt.formatType`-level complexity).
- Consequence: Slow outgoingCalls response.
- Mitigation: Accept for Task 3. partialResultToken is in the params but unimplemented — documented.

#### bodyNodeFor

**Input Hostility: test_decl without body (if such a thing exists)**
- Assumption: `.opt_token_and_node[1].unwrap()` succeeds.
- Betrayal: If the Zig parser ever produces a test_decl without a body (e.g., an error recovery path), `.unwrap()` returns null.
- Consequence: Panic on null unwrap.
- Mitigation: Use `orelse return null` pattern, same as Task 1's prepare. Treat as "no body" like fn_proto.

#### Capability flag

**State Corruption: Client caches capabilities**
- Assumption: Client re-queries capabilities when server restarts.
- Betrayal: Stale cached capabilities in persistent client state — client continues assuming old capabilities.
- Consequence: Client either ignores the flag (calling a method we now support) or refuses to call call_hierarchy because its cache says we don't.
- Mitigation: Structural — LSP clients are expected to re-initialize on restart. Not a server concern.

## Out of Scope

- Paren-wrapped and chained call expressions as outgoing callees (e.g., `(f)()`, `get_fn().run()`) — documented as known limitation.
- partialResultToken streaming support (present in OutgoingCallsParams but unimplemented).
- Main `Builder` rewrite (still deferred — not required for any of Phase 2 tasks).
- Live narrated LSP demo — that's the acceptance task, scheduled after Task 3 closes.
