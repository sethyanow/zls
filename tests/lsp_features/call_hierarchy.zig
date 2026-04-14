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

test "prepare on comptime block containing call returns Item" {
    try testPrepare(
        \\fn foo() void {}
        \\comptime {
        \\    <>foo();
        \\}
    , &.{
        .{
            .name = "comptime",
            .kind = .Function,
            .range_text =
            \\comptime {
            \\    foo();
            \\}
            ,
            .selection_text = "comptime",
        },
    });
}

test "prepare on comptime block with no calls returns null" {
    try testPrepare(
        \\comptime {
        \\    const <>x = 1;
        \\    _ = x;
        \\}
    , &.{});
}

test "prepare on whitespace between functions returns null" {
    try testPrepare(
        \\fn a() void {}
        \\<>
        \\fn b() void {}
    , &.{});
}

test "prepare on top-level variable declaration returns null" {
    try testPrepare(
        \\const <>x = 1;
    , &.{});
}

test "prepare on anonymous fn expression returns null" {
    // `const f = fn() void {}` is an anonymous fn literal — the fn_proto has no
    // name_token. Per the adversarial catalog, Task 1 skips these; future work
    // could resolve to the enclosing var decl's name.
    try testPrepare(
        \\const f = fn() void {<>};
        \\comptime { _ = f; }
    , &.{});
}

// -----------------------------------------------------------------------------
// Adversarial battery (post-implementation stress tests)
// -----------------------------------------------------------------------------

test "prepare: nested fn_decl — innermost wins" {
    // Inner fn declared inside an outer fn's container expression.
    // Per design, innermost callable matches when position is inside the inner fn.
    try testPrepare(
        \\fn outer() void {
        \\    const helper = struct {
        \\        fn <>inner() void {}
        \\    };
        \\    _ = helper;
        \\}
    , &.{
        .{
            .name = "inner",
            .kind = .Function,
            .range_text = "fn inner() void {}",
            .selection_text = "inner",
        },
    });
}

test "prepare: position on function name token matches the fn" {
    // Click on `foo` directly (name token), not inside body.
    try testPrepare(
        \\fn fo<>o() void {}
    , &.{
        .{
            .name = "foo",
            .kind = .Function,
            .range_text = "fn foo() void {}",
            .selection_text = "foo",
        },
    });
}

test "prepare: quoted identifier with multi-byte chars" {
    // `@"αβ"` is a valid Zig identifier; name is the full @-quoted token slice.
    try testPrepare(
        \\fn @"<>αβ"() void {}
    , &.{
        .{
            .name = "@\"αβ\"",
            .kind = .Function,
            .range_text = "fn @\"αβ\"() void {}",
            .selection_text = "@\"αβ\"",
        },
    });
}

test "prepare: recursive self-call inside comptime block" {
    // A function that calls itself — ensure the fn_decl is matched, not the call site.
    try testPrepare(
        \\fn rec() void { <>rec(); }
    , &.{
        .{
            .name = "rec",
            .kind = .Function,
            .range_text = "fn rec() void { rec(); }",
            .selection_text = "rec",
        },
    });
}

test "prepare: function named `comptime` does not collide with comptime-block handling" {
    // Semantically hostile: a fn whose name IS the string literal we use for comptime blocks.
    try testPrepare(
        \\fn @"<>comptime"() void {}
    , &.{
        .{
            .name = "@\"comptime\"",
            .kind = .Function,
            .range_text = "fn @\"comptime\"() void {}",
            .selection_text = "@\"comptime\"",
        },
    });
}

test "prepare: idempotent — two prepares on the same position return equivalent items" {
    var phr = try helper.collectClearPlaceholders(allocator, "fn <>foo() void {}");
    defer phr.deinit(allocator);
    var ctx: Context = try .init();
    defer ctx.deinit();

    const test_uri = try ctx.addDocument(.{ .source = phr.new_source });
    const position = offsets.locToRange(phr.new_source, phr.locations.items(.new)[0], .@"utf-16").start;

    const params: types.call_hierarchy.PrepareParams = .{
        .textDocument = .{ .uri = test_uri.raw },
        .position = position,
    };
    const first = try ctx.server.sendRequestSync(ctx.arena.allocator(), "textDocument/prepareCallHierarchy", params);
    const second = try ctx.server.sendRequestSync(ctx.arena.allocator(), "textDocument/prepareCallHierarchy", params);

    const a = (first orelse return error.InvalidResponse)[0];
    const b = (second orelse return error.InvalidResponse)[0];

    try std.testing.expectEqualStrings(a.name, b.name);
    try std.testing.expectEqual(a.kind, b.kind);
    try std.testing.expectEqualStrings(a.uri, b.uri);
    try std.testing.expectEqual(a.range.start.line, b.range.start.line);
    try std.testing.expectEqual(a.range.end.character, b.range.end.character);

    const a_node = a.data.?.object.get("node").?.integer;
    const b_node = b.data.?.object.get("node").?.integer;
    try std.testing.expectEqual(a_node, b_node);
}

test "CallHierarchyItem.data round-trips through lsp_kit serialization" {
    // Exercise the same JSON path the LSP transport uses: std.json.Stringify.valueAlloc
    // (cf. src/Server.zig:207, src/DiagnosticsCollection.zig:296).
    // The `data` field carries URI + node_index across prepare → incoming/outgoing, so
    // this is the handoff Task 2/3 relies on.
    var phr = try helper.collectClearPlaceholders(allocator, "fn <>foo() void {}");
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
    const items = response orelse return error.InvalidResponse;
    try std.testing.expectEqual(@as(usize, 1), items.len);
    const original_item = items[0];

    // Round-trip: serialize the full Item, then parse it back.
    const json_bytes = try std.json.Stringify.valueAlloc(
        ctx.arena.allocator(),
        original_item,
        .{ .emit_null_optional_fields = false },
    );

    const parsed = try std.json.parseFromSlice(
        types.call_hierarchy.Item,
        ctx.arena.allocator(),
        json_bytes,
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings(original_item.name, parsed.value.name);
    try std.testing.expectEqualStrings(original_item.uri, parsed.value.uri);

    const data = parsed.value.data orelse return error.DataFieldDropped;
    try std.testing.expect(data == .object);
    const obj = data.object;

    const uri_value = obj.get("uri") orelse return error.UriFieldMissing;
    try std.testing.expect(uri_value == .string);
    try std.testing.expectEqualStrings(test_uri.raw, uri_value.string);

    const node_value = obj.get("node") orelse return error.NodeFieldMissing;
    try std.testing.expect(node_value == .integer);
    try std.testing.expect(node_value.integer >= 0);
}

// -----------------------------------------------------------------------------
// incomingCalls — RED test for single caller (zls-239)
// -----------------------------------------------------------------------------

const ExpectedCaller = struct {
    /// Exact name field on the IncomingCall.from Item.
    name: []const u8,
    /// Each entry is the exact source slice the fromRange should cover.
    from_ranges: []const []const u8,
};

test "incoming: single caller, one call site" {
    try testIncomingCalls(
        \\fn <>target() void {}
        \\fn caller() void { target(); }
    , &.{
        .{
            .name = "caller",
            .from_ranges = &.{"target()"},
        },
    });
}

fn testIncomingCalls(source: []const u8, expected: []const ExpectedCaller) !void {
    var phr = try helper.collectClearPlaceholders(allocator, source);
    defer phr.deinit(allocator);

    var ctx: Context = try .init();
    defer ctx.deinit();

    const test_uri = try ctx.addDocument(.{ .source = phr.new_source });
    const position = offsets.locToRange(phr.new_source, phr.locations.items(.new)[0], .@"utf-16").start;

    // Phase 1: prepare to obtain the target Item (with Item.data encoded).
    const prepare_params: types.call_hierarchy.PrepareParams = .{
        .textDocument = .{ .uri = test_uri.raw },
        .position = position,
    };
    const prepared = try ctx.server.sendRequestSync(
        ctx.arena.allocator(),
        "textDocument/prepareCallHierarchy",
        prepare_params,
    );
    const items = prepared orelse {
        std.debug.print("prepareCallHierarchy returned null — test setup is wrong\n", .{});
        return error.PrepareFailed;
    };
    if (items.len == 0) return error.PrepareReturnedEmpty;
    const target_item = items[0];

    // Phase 2: incomingCalls on the prepared Item.
    const incoming_params: types.call_hierarchy.IncomingCallsParams = .{
        .item = target_item,
    };
    const response = try ctx.server.sendRequestSync(
        ctx.arena.allocator(),
        "callHierarchy/incomingCalls",
        incoming_params,
    );

    const calls: []const types.call_hierarchy.IncomingCall = response orelse {
        std.debug.print("incomingCalls returned null but expected {d} caller(s)\n", .{expected.len});
        return error.InvalidResponse;
    };

    try std.testing.expectEqual(expected.len, calls.len);
    for (expected, calls) |exp, got| {
        try std.testing.expectEqualStrings(exp.name, got.from.name);
        try std.testing.expectEqual(@as(usize, exp.from_ranges.len), got.fromRanges.len);
        for (exp.from_ranges, got.fromRanges) |exp_range, got_range| {
            const got_slice = offsets.rangeToSlice(phr.new_source, got_range, ctx.server.offset_encoding);
            try std.testing.expectEqualStrings(exp_range, got_slice);
        }
    }
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
