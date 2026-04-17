const std = @import("std");
const Ast = std.zig.Ast;
const lsp = @import("lsp");

const Server = @import("../Server.zig");
const Uri = @import("../Uri.zig");
const ast = @import("../ast.zig");
const offsets = @import("../offsets.zig");
const Analyser = @import("../analysis.zig");
const DocumentStore = @import("../DocumentStore.zig");
const references = @import("references.zig");

const types = lsp.types;

pub fn prepareHandler(
    server: *Server,
    arena: std.mem.Allocator,
    request: types.call_hierarchy.PrepareParams,
) Server.Error!?[]const types.call_hierarchy.Item {
    const document_uri = Uri.parse(arena, request.textDocument.uri) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidParams,
    };
    const handle = server.document_store.getHandle(document_uri) orelse return null;
    const tree = &handle.tree;
    const source_index = offsets.positionToIndex(tree.source, request.position, server.offset_encoding);

    // Walk the AST from root downward, collecting nodes whose extent contains source_index.
    // The resulting stack is ordered outermost → innermost; the last entry is the innermost.
    var stack: std.ArrayList(Ast.Node.Index) = .empty;
    defer stack.deinit(arena);

    var walker: ast.Walker = try .init(arena, tree, .root);
    defer walker.deinit(arena);
    while (try walker.next(arena, tree)) |event| {
        switch (event) {
            .open => |node| {
                const loc = offsets.nodeToLoc(tree, node);
                if (loc.start <= source_index and source_index <= loc.end) {
                    try stack.append(arena, node);
                } else {
                    walker.skip();
                }
            },
            .close => break,
        }
    }

    // Search from innermost outward for an enclosing callable.
    var i: usize = stack.items.len;
    while (i > 0) {
        i -= 1;
        const node = stack.items[i];
        const parent_tag: ?std.zig.Ast.Node.Tag = if (i > 0) tree.nodeTag(stack.items[i - 1]) else null;
        if (try buildItemIfCallable(arena, handle.uri, tree, node, parent_tag, server.offset_encoding)) |item| {
            const out = try arena.alloc(types.call_hierarchy.Item, 1);
            out[0] = item;
            return out;
        }
    }

    return null;
}

/// Returns a CallHierarchyItem for `node` when its tag represents a callable entity
/// whose prepareCallHierarchy result should point at it; returns null otherwise.
fn buildItemIfCallable(
    arena: std.mem.Allocator,
    uri: Uri,
    tree: *const Ast,
    node: Ast.Node.Index,
    parent_tag: ?std.zig.Ast.Node.Tag,
    encoding: offsets.Encoding,
) !?types.call_hierarchy.Item {
    const tag = tree.nodeTag(node);
    switch (tag) {
        .fn_decl,
        .fn_proto,
        .fn_proto_one,
        .fn_proto_multi,
        .fn_proto_simple,
        => {
            // The fn_proto* variant that appears as the prototype child of a fn_decl is not
            // callable on its own — the enclosing fn_decl is. Skip the child so the outer
            // iteration matches the fn_decl on its next step.
            if (tag != .fn_decl and parent_tag == .fn_decl) return null;
            var buf: [1]Ast.Node.Index = undefined;
            const fn_proto = tree.fullFnProto(&buf, node).?;
            const name_token = fn_proto.name_token orelse return null;
            const name = tree.tokenSlice(name_token);
            return .{
                .name = name,
                .kind = .Function,
                .uri = uri.raw,
                .range = offsets.nodeToRange(tree, node, encoding),
                .selectionRange = offsets.tokenToRange(tree, name_token, encoding),
                .data = try encodeItemData(arena, uri, node),
            };
        },
        .test_decl => {
            const name_token = tree.nodeData(node).opt_token_and_node[0].unwrap() orelse return null;
            const name = tree.tokenSlice(name_token);
            return .{
                .name = name,
                .kind = .Function,
                .uri = uri.raw,
                .range = offsets.nodeToRange(tree, node, encoding),
                .selectionRange = offsets.tokenToRange(tree, name_token, encoding),
                .data = try encodeItemData(arena, uri, node),
            };
        },
        .@"comptime" => {
            // Only treat this comptime block as a callable if it actually contains a call.
            // An idle comptime block (const/let/math-only) is not meaningful to surface in
            // a call hierarchy.
            if (!try comptimeBlockContainsCall(arena, tree, node)) return null;
            const keyword_token = tree.nodeMainToken(node);
            return .{
                .name = "comptime",
                .kind = .Function,
                .uri = uri.raw,
                .range = offsets.nodeToRange(tree, node, encoding),
                .selectionRange = offsets.tokenToRange(tree, keyword_token, encoding),
                .data = try encodeItemData(arena, uri, node),
            };
        },
        else => return null,
    }
}

/// Walks the descendants of `comptime_node` looking for a single call-like expression.
/// Short-circuits on the first hit — we only need existence, not a count, per the
/// adversarial catalog (avoid O(block_size) full scans).
fn comptimeBlockContainsCall(
    arena: std.mem.Allocator,
    tree: *const Ast,
    comptime_node: Ast.Node.Index,
) !bool {
    var walker: ast.Walker = try .init(arena, tree, comptime_node);
    defer walker.deinit(arena);
    while (try walker.next(arena, tree)) |event| switch (event) {
        .open => |descendant| {
            if (descendant == comptime_node) continue;
            var buf: [1]Ast.Node.Index = undefined;
            if (tree.fullCall(&buf, descendant) != null) return true;
        },
        .close => {},
    };
    return false;
}

/// Encode {uri, node} into the LSPAny payload that survives across prepare → incoming/outgoing.
fn encodeItemData(arena: std.mem.Allocator, uri: Uri, node: Ast.Node.Index) !types.LSPAny {
    var obj: std.json.ObjectMap = .init(arena);
    try obj.put("uri", .{ .string = uri.raw });
    try obj.put("node", .{ .integer = @intCast(@intFromEnum(node)) });
    return .{ .object = obj };
}

/// Inverse of `encodeItemData`. Recovers (uri, node) from the LSPAny payload a client
/// sent back with `callHierarchy/incomingCalls` (or outgoingCalls).
///
/// Returns null for any malformed input rather than erroring — per LSP etiquette the
/// client can always re-prepare if we reject an Item. This includes:
/// - data is null
/// - data is not a JSON object
/// - missing "uri" or "node" fields
/// - "uri" is not a JSON string or "node" is not a JSON integer
/// - "node" integer is negative or exceeds u32 range
///
/// Bounds validation against the actual `tree.nodes.len` is the caller's job — the
/// decoder has no access to a tree. The caller should also validate that the decoded
/// node still points at a callable tag (staleness check) before using it.
const DecodedItemData = struct {
    uri_raw: []const u8,
    node: std.zig.Ast.Node.Index,
};

fn decodeItemData(data: ?types.LSPAny) ?DecodedItemData {
    const root = data orelse return null;
    const obj = switch (root) {
        .object => |o| o,
        else => return null,
    };

    const uri_raw = switch (obj.get("uri") orelse return null) {
        .string => |s| s,
        else => return null,
    };

    const node_int = switch (obj.get("node") orelse return null) {
        .integer => |i| i,
        else => return null,
    };

    const node_u32 = std.math.cast(u32, node_int) orelse return null;
    return .{ .uri_raw = uri_raw, .node = @enumFromInt(node_u32) };
}

pub fn incomingCallsHandler(
    server: *Server,
    arena: std.mem.Allocator,
    request: types.call_hierarchy.IncomingCallsParams,
) Server.Error!?[]const types.call_hierarchy.IncomingCall {
    // Decode the Item.data payload produced by prepare.
    const decoded = decodeItemData(request.item.data) orelse return null;

    // Parse URI and look up the handle. The URI slice lives in the request arena.
    const document_uri = Uri.parse(arena, decoded.uri_raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const handle = server.document_store.getHandle(document_uri) orelse return null;
    const tree = &handle.tree;

    // Bounds + staleness check: the node index from the prior prepare must still be in
    // range and point at a callable tag. If the file was re-parsed after prepare, the
    // index may be invalid or now refer to unrelated syntax.
    if (@intFromEnum(decoded.node) >= tree.nodes.len) return null;
    const tag = tree.nodeTag(decoded.node);
    switch (tag) {
        .fn_decl, .fn_proto, .fn_proto_one, .fn_proto_multi, .fn_proto_simple => {},
        // test_decl / comptime are callable constructs in the call-hierarchy sense
        // (they appear as nodes in the hierarchy tree) but cannot themselves BE called
        // by user code — return an empty result rather than null. Null means "not
        // applicable"; empty means "applicable, no callers."
        .test_decl, .@"comptime" => return &.{},
        else => return null,
    }

    // Resolve the (handle, node) back into the DeclWithHandle the reference machinery
    // consumes. For callable nodes, the node itself IS the decl's ast_node.
    const decl_handle: Analyser.DeclWithHandle = .{
        .decl = .{ .ast_node = decoded.node },
        .handle = handle,
    };

    var analyser = server.initAnalyser(arena, handle);
    defer analyser.deinit();

    // Gather every call site (with caller fn node) across the workspace.
    const sites = try references.callsiteReferencesWithCaller(&analyser, decl_handle, true);

    // Group by (caller_handle.uri, caller_fn_node). Skip file-scope calls
    // (caller_fn_node == null) — the call hierarchy protocol has no natural Item
    // for "file scope" caller; documented limitation.
    const Bucket = struct {
        handle: *DocumentStore.Handle,
        caller_fn_node: Ast.Node.Index,
        ranges: std.ArrayList(types.Range),
    };
    var buckets: std.ArrayList(Bucket) = .empty;
    // Backing storage for bucket.ranges lives on the arena; no explicit deinit.

    outer: for (sites.items) |cs| {
        const caller_fn_node = cs.caller_fn_node orelse continue;
        const call_range = offsets.nodeToRange(&cs.handle.tree, cs.call_node, server.offset_encoding);

        for (buckets.items) |*bucket| {
            if (bucket.handle.uri.eql(cs.handle.uri) and bucket.caller_fn_node == caller_fn_node) {
                try bucket.ranges.append(arena, call_range);
                continue :outer;
            }
        }

        var ranges: std.ArrayList(types.Range) = .empty;
        try ranges.append(arena, call_range);
        try buckets.append(arena, .{
            .handle = cs.handle,
            .caller_fn_node = caller_fn_node,
            .ranges = ranges,
        });
    }

    const out = try arena.alloc(types.call_hierarchy.IncomingCall, buckets.items.len);
    for (buckets.items, out) |bucket, *slot| {
        // caller_fn_node came from innermostScopeAtIndexWithTag(.function), which wraps
        // fn_decls — buildItemIfCallable with parent_tag=null resolves to the fn_decl
        // branch directly. The .? unwrap is safe.
        const caller_item = (try buildItemIfCallable(
            arena,
            bucket.handle.uri,
            &bucket.handle.tree,
            bucket.caller_fn_node,
            null,
            server.offset_encoding,
        )).?;
        slot.* = .{
            .from = caller_item,
            .fromRanges = bucket.ranges.items,
        };
    }
    return out;
}

/// Resolve a `.call*` node's callee to a `DeclWithHandle`. Mirror of
/// `references.zig:614-647` (CallBuilder.referenceNode's .identifier and
/// .field_access branches) WITHOUT the target_decl.eql filter — outgoing accepts
/// every resolved callee, not just those equal to a target.
///
/// Returns null for unresolved or non-resolvable callees:
/// - paren-wrapped: `(f)()` — fn_expr is a paren expr, not .identifier
/// - anonymous fn literal: `(fn() void {})()` — fn_expr is .fn_proto*
/// - method/call chains: `get_fn().run()` — fn_expr is itself a call expression
/// - undefined identifier: lookupSymbolGlobal returns null
/// - field_access where LHS type cannot be resolved
///
/// Per the design: silent null return is a deliberate choice, NOT an error swallow.
fn resolveCallee(
    analyser: *Analyser,
    handle: *DocumentStore.Handle,
    call_node: Ast.Node.Index,
) Analyser.Error!?Analyser.DeclWithHandle {
    const tree = &handle.tree;
    var buf: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buf, call_node).?; // caller has filtered to .call*

    const called_node = call.ast.fn_expr;
    switch (tree.nodeTag(called_node)) {
        .identifier => {
            const identifier_token = ast.identifierTokenFromIdentifierNode(tree, called_node) orelse return null;
            return try analyser.lookupSymbolGlobal(
                handle,
                offsets.identifierTokenToNameSlice(tree, identifier_token),
                tree.tokenStart(identifier_token),
            );
        },
        .field_access => {
            const lhs_node, const field_name = tree.nodeData(called_node).node_and_token;
            const lhs = (try analyser.resolveTypeOfNode(.of(lhs_node, handle))) orelse return null;
            const deref_lhs = try analyser.resolveDerefType(lhs) orelse lhs;
            const symbol = offsets.tokenToSlice(tree, field_name);
            return try deref_lhs.lookupSymbol(analyser, symbol);
        },
        else => return null,
    }
}

/// Returns the body node to walk for outgoingCalls — the inner block of fn_decl,
/// test_decl, or comptime. Returns null for fn_proto* variants (no body) and any
/// non-callable tag (the handler's upstream tag filter prevents those reaching here,
/// but the `else` branch is the safety net).
fn bodyNodeFor(tree: *const Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    switch (tree.nodeTag(node)) {
        // .node_and_node[1] is the body block (first is the fn_proto prototype).
        .fn_decl => return tree.nodeData(node).node_and_node[1],
        // .opt_token_and_node[0] is the optional name token (Task 1 uses this);
        // [1] is the body block — always present per the Ast schema.
        .test_decl => return tree.nodeData(node).opt_token_and_node[1],
        .@"comptime" => return tree.nodeData(node).node,
        // Prototype-only nodes (extern fns, fn types) — no body to walk.
        .fn_proto, .fn_proto_one, .fn_proto_multi, .fn_proto_simple => return null,
        else => return null,
    }
}

pub fn outgoingCallsHandler(
    server: *Server,
    arena: std.mem.Allocator,
    request: types.call_hierarchy.OutgoingCallsParams,
) Server.Error!?[]const types.call_hierarchy.OutgoingCall {
    // Decode Item.data — null for malformed payloads (per LSP etiquette client can re-prepare).
    const decoded = decodeItemData(request.item.data) orelse return null;

    const document_uri = Uri.parse(arena, decoded.uri_raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const handle = server.document_store.getHandle(document_uri) orelse return null;
    const tree = &handle.tree;

    // Bounds + staleness check — same shape as incomingCallsHandler.
    if (@intFromEnum(decoded.node) >= tree.nodes.len) return null;
    const tag = tree.nodeTag(decoded.node);
    switch (tag) {
        .fn_decl,
        .fn_proto,
        .fn_proto_one,
        .fn_proto_multi,
        .fn_proto_simple,
        .test_decl,
        .@"comptime",
        => {},
        else => return null,
    }

    // No body to walk → applicable but no callees. Return empty slice, NOT null.
    const body_node = bodyNodeFor(tree, decoded.node) orelse return &.{};

    var analyser = server.initAnalyser(arena, handle);
    defer analyser.deinit();

    // Walk the body collecting `.call*` nodes. Skip the body root itself.
    var call_nodes: std.ArrayList(Ast.Node.Index) = .empty;
    {
        var walker: ast.Walker = try .init(arena, tree, body_node);
        defer walker.deinit(arena);
        while (try walker.next(arena, tree)) |event| switch (event) {
            .open => |descendant| {
                if (descendant == body_node) continue;
                switch (tree.nodeTag(descendant)) {
                    .call, .call_comma, .call_one, .call_one_comma => {
                        try call_nodes.append(arena, descendant);
                    },
                    else => {},
                }
            },
            .close => {},
        };
    }

    // Group by resolved callee decl. Linear-scan bucketing — same pattern as
    // incomingCallsHandler. Buckets carry the ast_node so we can build the Item later.
    const Bucket = struct {
        callee: Analyser.DeclWithHandle,
        callee_ast_node: Ast.Node.Index,
        ranges: std.ArrayList(types.Range),
    };
    var buckets: std.ArrayList(Bucket) = .empty;

    outer: for (call_nodes.items) |call_node| {
        const callee = (try resolveCallee(&analyser, handle, call_node)) orelse continue;
        // Only `.ast_node` decls have a node we can pass to buildItemIfCallable.
        // Function-parameter, capture, and label decls have no AST node to point at.
        const callee_ast_node = switch (callee.decl) {
            .ast_node => |n| n,
            else => continue,
        };
        const range = offsets.nodeToRange(tree, call_node, server.offset_encoding);

        for (buckets.items) |*bucket| {
            if (bucket.callee.eql(callee)) {
                try bucket.ranges.append(arena, range);
                continue :outer;
            }
        }

        var ranges: std.ArrayList(types.Range) = .empty;
        try ranges.append(arena, range);
        try buckets.append(arena, .{
            .callee = callee,
            .callee_ast_node = callee_ast_node,
            .ranges = ranges,
        });
    }

    // Build OutgoingCalls. Skip buckets whose callee can't be represented as an Item
    // (e.g., callee resolves to a var_decl holding a fn value — not a callable tag).
    var out: std.ArrayList(types.call_hierarchy.OutgoingCall) = .empty;
    try out.ensureTotalCapacityPrecise(arena, buckets.items.len);
    for (buckets.items) |bucket| {
        const to_item = (try buildItemIfCallable(
            arena,
            bucket.callee.handle.uri,
            &bucket.callee.handle.tree,
            bucket.callee_ast_node,
            null,
            server.offset_encoding,
        )) orelse continue;
        out.appendAssumeCapacity(.{
            .to = to_item,
            .fromRanges = bucket.ranges.items,
        });
    }
    return out.items;
}
