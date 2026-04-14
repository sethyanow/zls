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
// incomingCalls — adversarial decoder battery (zls-239)
// -----------------------------------------------------------------------------

/// Sends `callHierarchy/incomingCalls` with an Item whose `data` field is `data`.
/// Asserts the handler returns null (the decoder rejected the malformed payload).
/// All other Item fields are synthesized against a throwaway loaded document so
/// that lsp_kit JSON serialization succeeds and the handler reaches `decodeItemData`.
fn expectIncomingCallsDataRejected(data: ?types.LSPAny) !void {
    var ctx: Context = try .init();
    defer ctx.deinit();

    const uri = try ctx.addDocument(.{ .source = "fn dummy() void {}" });
    const zero_pos: types.Position = .{ .line = 0, .character = 0 };
    const zero_range: types.Range = .{ .start = zero_pos, .end = zero_pos };

    const item: types.call_hierarchy.Item = .{
        .name = "dummy",
        .kind = .Function,
        .uri = uri.raw,
        .range = zero_range,
        .selectionRange = zero_range,
        .data = data,
    };

    const response = try ctx.server.sendRequestSync(
        ctx.arena.allocator(),
        "callHierarchy/incomingCalls",
        types.call_hierarchy.IncomingCallsParams{ .item = item },
    );
    try std.testing.expect(response == null);
}

test "incoming decoder: data = null" {
    try expectIncomingCallsDataRejected(null);
}

test "incoming decoder: data is not a JSON object" {
    // Integer in place of object — decoder's switch falls into `else => return null`.
    try expectIncomingCallsDataRejected(.{ .integer = 42 });
}

test "incoming decoder: empty object (missing uri and node)" {
    var obj: std.json.ObjectMap = .init(std.testing.allocator);
    defer obj.deinit();
    try expectIncomingCallsDataRejected(.{ .object = obj });
}

test "incoming decoder: object missing node field" {
    var obj: std.json.ObjectMap = .init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("uri", .{ .string = "untitled:///Untitled-0.zig" });
    try expectIncomingCallsDataRejected(.{ .object = obj });
}

test "incoming decoder: object missing uri field" {
    var obj: std.json.ObjectMap = .init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("node", .{ .integer = 0 });
    try expectIncomingCallsDataRejected(.{ .object = obj });
}

test "incoming decoder: node value is a string, not integer" {
    var obj: std.json.ObjectMap = .init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("uri", .{ .string = "untitled:///Untitled-0.zig" });
    try obj.put("node", .{ .string = "0" });
    try expectIncomingCallsDataRejected(.{ .object = obj });
}

test "incoming decoder: uri value is an integer, not string" {
    var obj: std.json.ObjectMap = .init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("uri", .{ .integer = 42 });
    try obj.put("node", .{ .integer = 0 });
    try expectIncomingCallsDataRejected(.{ .object = obj });
}

test "incoming decoder: negative node integer" {
    var obj: std.json.ObjectMap = .init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("uri", .{ .string = "untitled:///Untitled-0.zig" });
    try obj.put("node", .{ .integer = -1 });
    try expectIncomingCallsDataRejected(.{ .object = obj });
}

test "incoming decoder: node integer overflows u32" {
    var obj: std.json.ObjectMap = .init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("uri", .{ .string = "untitled:///Untitled-0.zig" });
    try obj.put("node", .{ .integer = 9_999_999_999 });
    try expectIncomingCallsDataRejected(.{ .object = obj });
}

test "incoming decoder: uri does not map to a loaded handle" {
    var obj: std.json.ObjectMap = .init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("uri", .{ .string = "file:///this/path/does/not/exist.zig" });
    try obj.put("node", .{ .integer = 0 });
    try expectIncomingCallsDataRejected(.{ .object = obj });
}

test "incoming decoder: node points at non-callable tag (stale data)" {
    // Set up a real document, then manually construct an Item whose data.node
    // points at a var_decl (non-callable) instead of the fn_decl prepare would
    // have encoded. The handler should recognise the stale tag and return null.
    var ctx: Context = try .init();
    defer ctx.deinit();

    const uri = try ctx.addDocument(.{ .source = "const x = 42;\nfn foo() void {}" });
    const handle = ctx.server.document_store.getHandle(uri).?;
    const tree = handle.tree;

    // Scan nodes for the var_decl. We know it's there — "const x = 42;".
    var var_decl_node: std.zig.Ast.Node.Index = @enumFromInt(0);
    var found = false;
    for (0..tree.nodes.len) |i| {
        const idx: std.zig.Ast.Node.Index = @enumFromInt(@as(u32, @intCast(i)));
        switch (tree.nodeTag(idx)) {
            .simple_var_decl, .local_var_decl, .global_var_decl, .aligned_var_decl => {
                var_decl_node = idx;
                found = true;
                break;
            },
            else => {},
        }
    }
    try std.testing.expect(found);

    var obj: std.json.ObjectMap = .init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("uri", .{ .string = uri.raw });
    try obj.put("node", .{ .integer = @intCast(@intFromEnum(var_decl_node)) });

    const zero_pos: types.Position = .{ .line = 0, .character = 0 };
    const zero_range: types.Range = .{ .start = zero_pos, .end = zero_pos };
    const item: types.call_hierarchy.Item = .{
        .name = "x",
        .kind = .Function,
        .uri = uri.raw,
        .range = zero_range,
        .selectionRange = zero_range,
        .data = .{ .object = obj },
    };

    const response = try ctx.server.sendRequestSync(
        ctx.arena.allocator(),
        "callHierarchy/incomingCalls",
        types.call_hierarchy.IncomingCallsParams{ .item = item },
    );
    try std.testing.expect(response == null);
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

test "incoming: single caller, multiple call sites collapse into one IncomingCall" {
    try testIncomingCalls(
        \\fn <>t() void {}
        \\fn c() void {
        \\    t();
        \\    t();
        \\    t();
        \\}
    , &.{
        .{
            .name = "c",
            .from_ranges = &.{ "t()", "t()", "t()" },
        },
    });
}

// -----------------------------------------------------------------------------
// Adversarial stress battery (zls-239, post-TDD)
// -----------------------------------------------------------------------------

test "incoming adversarial: target with zero callers returns empty slice" {
    // Empty pattern: the function is defined but nothing calls it. Handler
    // should return an empty (non-null) slice — applicable, no callers.
    try testIncomingCalls(
        \\fn <>orphan() void {}
    , &.{});
}

test "incoming adversarial: disconnected callers across three files" {
    // Disconnected pattern: target in file A, independent callers in files B and C.
    // Both callers must appear with URIs that distinguish them from each other.
    const source_a = "pub fn <>target() void {}";
    const source_b =
        \\const a = @import("Untitled-0.zig");
        \\fn b_caller() void { a.target(); }
    ;
    const source_c =
        \\const a = @import("Untitled-0.zig");
        \\fn c_caller() void { a.target(); }
    ;

    var phr = try helper.collectClearPlaceholders(allocator, source_a);
    defer phr.deinit(allocator);

    var ctx: Context = try .init();
    defer ctx.deinit();

    const uri_a = try ctx.addDocument(.{ .source = phr.new_source });
    const uri_b = try ctx.addDocument(.{ .source = source_b });
    const uri_c = try ctx.addDocument(.{ .source = source_c });

    const position = offsets.locToRange(phr.new_source, phr.locations.items(.new)[0], .@"utf-16").start;
    const prepared = try ctx.server.sendRequestSync(
        ctx.arena.allocator(),
        "textDocument/prepareCallHierarchy",
        types.call_hierarchy.PrepareParams{
            .textDocument = .{ .uri = uri_a.raw },
            .position = position,
        },
    );
    const items = prepared orelse return error.PrepareFailed;

    const response = try ctx.server.sendRequestSync(
        ctx.arena.allocator(),
        "callHierarchy/incomingCalls",
        types.call_hierarchy.IncomingCallsParams{ .item = items[0] },
    );
    const calls = response orelse return error.InvalidResponse;
    try std.testing.expectEqual(@as(usize, 2), calls.len);

    // Each caller lives in its own file; assert both URIs appear exactly once.
    var found_b = false;
    var found_c = false;
    for (calls) |call| {
        if (std.mem.eql(u8, call.from.uri, uri_b.raw)) {
            try std.testing.expect(!found_b);
            found_b = true;
            try std.testing.expectEqualStrings("b_caller", call.from.name);
        } else if (std.mem.eql(u8, call.from.uri, uri_c.raw)) {
            try std.testing.expect(!found_c);
            found_c = true;
            try std.testing.expectEqualStrings("c_caller", call.from.name);
        } else {
            std.debug.print("unexpected caller uri: {s}\n", .{call.from.uri});
            return error.UnexpectedCaller;
        }
    }
    try std.testing.expect(found_b);
    try std.testing.expect(found_c);
}

test "incoming adversarial: quoted-identifier caller name preserves wrapping" {
    // Encoding boundary: the caller uses an @"..."-quoted identifier. The resulting
    // IncomingCall.from.name should include the full token slice (including
    // `@"..."`), matching Task 1's prepareCallHierarchy name-token behavior
    // so round-tripping preserves the human identity.
    try testIncomingCalls(
        \\fn <>target() void {}
        \\fn @"weird-name!"() void { target(); }
    ,
        &.{
            .{
                .name = "@\"weird-name!\"",
                .from_ranges = &.{"target()"},
            },
        },
    );
}

test "incoming adversarial: idempotent — two calls on same Item" {
    // "Second run" pattern: if the handler mutates DocumentStore state or the
    // CallBuilder accumulates in a wrong place, the second call would drift.
    // Assert both calls return the same count and names.
    var phr = try helper.collectClearPlaceholders(allocator,
        \\fn <>target() void {}
        \\fn caller() void { target(); target(); }
    );
    defer phr.deinit(allocator);

    var ctx: Context = try .init();
    defer ctx.deinit();

    const uri = try ctx.addDocument(.{ .source = phr.new_source });
    const position = offsets.locToRange(phr.new_source, phr.locations.items(.new)[0], .@"utf-16").start;

    const prepared = try ctx.server.sendRequestSync(
        ctx.arena.allocator(),
        "textDocument/prepareCallHierarchy",
        types.call_hierarchy.PrepareParams{
            .textDocument = .{ .uri = uri.raw },
            .position = position,
        },
    );
    const items = prepared orelse return error.PrepareFailed;

    const params = types.call_hierarchy.IncomingCallsParams{ .item = items[0] };

    const first = try ctx.server.sendRequestSync(ctx.arena.allocator(), "callHierarchy/incomingCalls", params);
    const second = try ctx.server.sendRequestSync(ctx.arena.allocator(), "callHierarchy/incomingCalls", params);

    const a = first orelse return error.InvalidResponse;
    const b = second orelse return error.InvalidResponse;

    try std.testing.expectEqual(a.len, b.len);
    try std.testing.expectEqual(@as(usize, 1), a.len);
    try std.testing.expectEqualStrings(a[0].from.name, b[0].from.name);
    try std.testing.expectEqualStrings(a[0].from.uri, b[0].from.uri);
    try std.testing.expectEqual(a[0].fromRanges.len, b[0].fromRanges.len);
    try std.testing.expectEqual(@as(usize, 2), a[0].fromRanges.len);
}

test "incoming adversarial: dense — six distinct callers each call target once" {
    // Dense pattern: six fn_decls all calling target. All six should appear
    // as separate IncomingCalls with single fromRanges (no cross-bucket leak).
    try testIncomingCalls(
        \\fn <>t() void {}
        \\fn c1() void { t(); }
        \\fn c2() void { t(); }
        \\fn c3() void { t(); }
        \\fn c4() void { t(); }
        \\fn c5() void { t(); }
        \\fn c6() void { t(); }
    , &.{
        .{ .name = "c1", .from_ranges = &.{"t()"} },
        .{ .name = "c2", .from_ranges = &.{"t()"} },
        .{ .name = "c3", .from_ranges = &.{"t()"} },
        .{ .name = "c4", .from_ranges = &.{"t()"} },
        .{ .name = "c5", .from_ranges = &.{"t()"} },
        .{ .name = "c6", .from_ranges = &.{"t()"} },
    });
}

test "incoming: test_decl returns empty slice (not null)" {
    // test declarations can be invoked by the test runner but not by user code,
    // so incomingCalls is applicable but produces no callers — empty, not null.
    try testIncomingCalls(
        \\test "<>named" { _ = 1; }
    , &.{});
}

test "incoming: comptime block returns empty slice (not null)" {
    // comptime blocks likewise have no user-code callers.
    try testIncomingCalls(
        \\fn foo() void {}
        \\<>comptime {
        \\    foo();
        \\}
    , &.{});
}

test "incoming: recursive self-call" {
    try testIncomingCalls(
        \\fn <>rec() void {
        \\    rec();
        \\}
    , &.{
        .{
            .name = "rec",
            .from_ranges = &.{"rec()"},
        },
    });
}

test "incoming: cross-file caller via @import" {
    const source_a =
        \\pub fn <>target() void {}
    ;
    const source_b =
        \\const a = @import("Untitled-0.zig");
        \\fn caller() void {
        \\    a.target();
        \\}
    ;

    var phr = try helper.collectClearPlaceholders(allocator, source_a);
    defer phr.deinit(allocator);

    var ctx: Context = try .init();
    defer ctx.deinit();

    const uri_a = try ctx.addDocument(.{ .source = phr.new_source });
    const uri_b = try ctx.addDocument(.{ .source = source_b });

    const position = offsets.locToRange(phr.new_source, phr.locations.items(.new)[0], .@"utf-16").start;

    // Prepare at target in file A.
    const prepared = try ctx.server.sendRequestSync(
        ctx.arena.allocator(),
        "textDocument/prepareCallHierarchy",
        types.call_hierarchy.PrepareParams{
            .textDocument = .{ .uri = uri_a.raw },
            .position = position,
        },
    );
    const items = prepared orelse return error.PrepareFailed;
    try std.testing.expectEqual(@as(usize, 1), items.len);

    // incomingCalls should find the caller in file B.
    const response = try ctx.server.sendRequestSync(
        ctx.arena.allocator(),
        "callHierarchy/incomingCalls",
        types.call_hierarchy.IncomingCallsParams{ .item = items[0] },
    );
    const calls = response orelse return error.InvalidResponse;
    try std.testing.expectEqual(@as(usize, 1), calls.len);

    try std.testing.expectEqualStrings("caller", calls[0].from.name);
    try std.testing.expectEqualStrings(uri_b.raw, calls[0].from.uri);
    try std.testing.expectEqual(@as(usize, 1), calls[0].fromRanges.len);

    // The fromRange should cover the call expression `a.target()` in file B.
    const got_slice = offsets.rangeToSlice(source_b, calls[0].fromRanges[0], ctx.server.offset_encoding);
    try std.testing.expectEqualStrings("a.target()", got_slice);
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
