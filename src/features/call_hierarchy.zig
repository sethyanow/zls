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
        if (try buildItemIfCallable(arena, handle.uri, tree, node, server.offset_encoding)) |item| {
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
    encoding: offsets.Encoding,
) !?types.call_hierarchy.Item {
    switch (tree.nodeTag(node)) {
        .fn_decl => {
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
        else => return null,
    }
}

/// Encode {uri, node} into the LSPAny payload that survives across prepare → incoming/outgoing.
fn encodeItemData(arena: std.mem.Allocator, uri: Uri, node: Ast.Node.Index) !types.LSPAny {
    var obj: std.json.ObjectMap = .init(arena);
    try obj.put("uri", .{ .string = uri.raw });
    try obj.put("node", .{ .integer = @intCast(@intFromEnum(node)) });
    return .{ .object = obj };
}
