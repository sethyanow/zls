const std = @import("std");
const Ast = std.zig.Ast;
const lsp = @import("lsp");

const Server = @import("../Server.zig");
const Uri = @import("../Uri.zig");
const ast = @import("../ast.zig");
const offsets = @import("../offsets.zig");

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
