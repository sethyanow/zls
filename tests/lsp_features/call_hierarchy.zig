const std = @import("std");
const zls = @import("zls");

const helper = @import("../helper.zig");
const Context = @import("../context.zig").Context;

const types = zls.lsp.types;
const offsets = zls.offsets;

const allocator: std.mem.Allocator = std.testing.allocator;

const ExpectedItem = struct {
    name: []const u8,
    kind: types.SymbolKind,
    /// Exact slice of the source file that Item.range should cover.
    range_text: []const u8,
    /// Exact slice of the source file that Item.selectionRange should cover.
    selection_text: []const u8,
};

test "prepare on fn_decl returns function Item" {
    try testPrepare(
        \\fn <>foo() void {}
    , &.{
        .{
            .name = "foo",
            .kind = .Function,
            .range_text = "fn foo() void {}",
            .selection_text = "foo",
        },
    });
}

test "prepare on fn_proto (extern) returns function Item" {
    // The extern prototype's node range does not include the trailing `;`
    // (the semicolon is a separator token, not part of the fn_proto AST node).
    try testPrepare(
        \\extern fn <>extFn(a: i32) i32;
    , &.{
        .{
            .name = "extFn",
            .kind = .Function,
            .range_text = "extern fn extFn(a: i32) i32",
            .selection_text = "extFn",
        },
    });
}

test "prepare on test_decl with string name returns Item" {
    try testPrepare(
        \\test "<>my test" { _ = 1; }
    , &.{
        .{
            .name = "\"my test\"",
            .kind = .Function,
            .range_text = "test \"my test\" { _ = 1; }",
            .selection_text = "\"my test\"",
        },
    });
}

test "prepare on test_decl with identifier name returns Item" {
    try testPrepare(
        \\fn target() void {}
        \\test <>target { _ = 1; }
    , &.{
        .{
            .name = "target",
            .kind = .Function,
            .range_text = "test target { _ = 1; }",
            .selection_text = "target",
        },
    });
}

fn testPrepare(source: []const u8, expected: []const ExpectedItem) !void {
    var phr = try helper.collectClearPlaceholders(allocator, source);
    defer phr.deinit(allocator);

    var ctx: Context = try .init();
    defer ctx.deinit();

    const test_uri = try ctx.addDocument(.{ .source = phr.new_source });

    const position = offsets.locToRange(phr.new_source, phr.locations.items(.new)[0], .@"utf-16").start;

    const params: types.call_hierarchy.PrepareParams = .{
        .textDocument = .{ .uri = test_uri.raw },
        .position = position,
    };
    const response = try ctx.server.sendRequestSync(
        ctx.arena.allocator(),
        "textDocument/prepareCallHierarchy",
        params,
    );

    if (expected.len == 0) {
        try std.testing.expect(response == null);
        return;
    }

    const items: []const types.call_hierarchy.Item = response orelse {
        std.debug.print("Server returned `null` but expected {d} item(s)\n", .{expected.len});
        return error.InvalidResponse;
    };

    try std.testing.expectEqual(expected.len, items.len);
    for (expected, items) |exp, got| {
        try std.testing.expectEqualStrings(exp.name, got.name);
        try std.testing.expectEqual(exp.kind, got.kind);

        const range_slice = offsets.rangeToSlice(phr.new_source, got.range, ctx.server.offset_encoding);
        const selection_slice = offsets.rangeToSlice(phr.new_source, got.selectionRange, ctx.server.offset_encoding);
        try std.testing.expectEqualStrings(exp.range_text, range_slice);
        try std.testing.expectEqualStrings(exp.selection_text, selection_slice);
    }
}
