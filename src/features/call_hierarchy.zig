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
