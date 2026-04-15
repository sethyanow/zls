const std = @import("std");
const zls = @import("zls");

const helper = @import("../helper.zig");
const helper_build = @import("../helper_build.zig");
const Context = @import("../context.zig").Context;
const ErrorBuilder = @import("../ErrorBuilder.zig");

const types = zls.lsp.types;
const offsets = zls.offsets;

const allocator: std.mem.Allocator = std.testing.allocator;

test "references" {
    try testSymbolReferences(
        \\const <0> = 0;
        \\const foo = <0>;
    );
    try testSymbolReferences(
        \\var <0> = 0;
        \\var foo = <0>;
    );
    try testSymbolReferences(
        \\const <0> = struct {};
        \\var foo: <0> = <0>{};
    );
    try testSymbolReferences(
        \\const <0> = enum {};
        \\var foo: <0> = undefined;
    );
    try testSymbolReferences(
        \\const <0> = union {};
        \\var foo: <0> = <0>{};
    );
    try testSymbolReferences(
        \\fn <0>() void {}
        \\var foo = <0>();
    );
    try testSymbolReferences(
        \\const <0> = error{};
        \\fn bar() <0>!void {}
    );
}

test "global scope" {
    try testSymbolReferences(
        \\const foo = <0>;
        \\const <0> = 0;
        \\const bar = <0>;
    );
}

test "local scope" {
    try testSymbolReferences(
        \\fn foo(<0>: u32, bar: u32) void {
        \\    return <0> + bar;
        \\}
    );
    try testSymbolReferences(
        \\const foo = outer: {
        \\    _ = inner: {
        \\        const <0> = 0;
        \\        break :inner <0>;
        \\    };
        \\    const <1> = 0;
        \\    break :outer <1>;
        \\};
        \\const bar = foo;
    );
}

test "destructuring" {
    try testSymbolReferences(
        \\const blk = {
        \\    const <0>, const foo = .{ 1, 2 };
        \\    const bar = <0>;
        \\};
    );
    try testSymbolReferences(
        \\const blk = {
        \\    const foo, const <0> = .{ 1, 2 };
        \\    const bar = <0>;
        \\};
    );
}

test "for/while capture" {
    try testSymbolReferences(
        \\const blk = {
        \\    for ("") |<0>| {
        \\        _ = <0>;
        \\    }
        \\    while (false) |<1>| {
        \\        _ = <1>;
        \\    }
        \\};
    );
}

test "break/continue operands" {
    try testSymbolReferences(
        \\comptime {
        \\    const <0> = 0;
        \\    sw: switch (0) {
        \\        0 => continue :sw <0>,
        \\        else => break :sw <0>,
        \\    }
        \\}
    );
}

test "enum field access" {
    try testSymbolReferences(
        \\const E = enum {
        \\  <0>,
        \\  bar
        \\};
        \\const e = E.<0>;
    );
}

test "switch case with enum literal" {
    try testSymbolReferences(
        \\const E = enum {
        \\    <0>,
        \\    bar,
        \\};
        \\
        \\test {
        \\    const e = E.<0>;
        \\    switch (e) {
        \\        .<0> => {},
        \\        .bar => {},
        \\    }
        \\}
    );
}

test "struct field access" {
    try testSymbolReferences(
        \\const S = struct {<0>: u32 = 3};
        \\pub fn foo() bool {
        \\    const s: S = .{};
        \\    return s.<0> == s.<0>;
        \\}
    );
}

test "struct init result location from function return type" {
    try testSymbolReferences(
        \\fn foo() struct { <0>: i32 } {
        \\    return .{ .<0> = 1 };
        \\}
        \\
        \\test {
        \\    var x = foo();
        \\    x.<0> = 2;
        \\}
    );
}

test "struct decl access" {
    try testSymbolReferences(
        \\const S = struct {
        \\    fn <0>(self: S) void {}
        \\};
        \\pub fn foo() bool {
        \\    const s: S = .{};
        \\    s.<0>();
        \\    s.<0>();
        \\    <1>();
        \\}
        \\fn <1>() void {}
    );
}

test "struct one field init" {
    try testSymbolReferences(
        \\const S = struct { <0>: u32 };
        \\const s = S{ .<0> = 0 };
        \\const s2: S = .{ .<0> = 0 };
    );
}

test "struct multi-field init" {
    try testSymbolReferences(
        \\const S = struct { <0>: u32, a: bool };
        \\const s = S{ .<0> = 0, .a = true };
        \\const s2: S = .{ .<0> = 0, .a = true };
    );
}

test "decl literal on generic type" {
    try testSymbolReferences(
        \\fn Box(comptime T: type) type {
        \\    return struct {
        \\        item: T,
        \\        const <0>: @This() = undefined;
        \\    };
        \\};
        \\test {
        \\    const box: Box(u8) = .<0>;
        \\}
    );
}

test "while continue expression" {
    try testSymbolReferences(
        \\ pub fn foo() void {
        \\     var <0>: u32 = 0;
        \\     while (true) : (<0> += 1) {}
        \\ }
    );
}

test "test with identifier" {
    try testSymbolReferences(
        \\pub fn <0>() bool {}
        \\test <0> {}
        \\test "placeholder" {}
        \\test {}
    );
}

test "label" {
    try testSymbolReferences(
        \\const foo = <0>: {
        \\    break :<0> 0;
        \\};
    );
    try testSymbolReferences(
        \\const foo = <0>: {
        \\    const <1> = 0;
        \\    _ = <1>;
        \\    break :<0> 0;
        \\};
    );
    try testSymbolReferences(
        \\comptime {
        \\    <0>: switch (0) {
        \\        else => break :<0>,
        \\    }
        \\}
    );
}

test "asm" {
    try testSymbolReferences(
        \\fn foo(<0>: u32) void {
        \\    asm ("bogus"
        \\        : [ret] "={rax}" (-> void),
        \\        : [bar] "{rax}" (<0>),
        \\    );
        \\}
    );
    try testSymbolReferences(
        \\fn foo(comptime <0>: type) void {
        \\    asm ("bogus"
        \\        : [ret] "={rax}" (-> <0>),
        \\    );
        \\}
    );
}

test "function header" {
    try testSymbolReferences(
        \\fn foo(<0>: anytype) @TypeOf(<0>) {}
    );
    try testSymbolReferences(
        \\fn foo(<0>: type, bar: <0>) <0> {}
    );
}

test "switch case capture - union field" {
    try testSymbolReferences(
        \\const foo = switch (undefined) {
        \\    .foo => |<0>| <0>,
        \\};
    );
    try testSymbolReferences(
        \\const foo = switch (undefined) {
        \\    .foo => |<0>, _| <0>,
        \\};
    );
    try testSymbolReferences(
        \\const foo = switch (undefined) {
        \\    inline .foo => |<0>, _| <0>,
        \\};
    );
}

test "switch case capture - union tag" {
    try testSymbolReferences(
        \\const foo = switch (undefined) {
        \\    .foo => |_, <0>| <0>,
        \\};
    );
    try testSymbolReferences(
        \\const foo = switch (undefined) {
        \\    inline .foo => |_, <0>| <0>,
        \\};
    );
}

test "cross-file reference" {
    try testMultiFileSymbolReferences(&.{
        // Untitled-0.zig
        \\pub const <0> = struct {};
        ,
        // Untitled-1.zig
        \\const file = @import("Untitled-0.zig");
        \\const <0> = file.<0>;
        \\const renamed = file.<0>;
        \\comptime {
        \\    _ = <0>;
        \\    _ = renamed;
        \\}
        ,
    }, true);
}

test "cross-file - transitive import" {
    try testMultiFileSymbolReferences(&.{
        // Untitled-0.zig
        \\pub const <0> = struct {};
        ,
        // Untitled-1.zig
        \\pub const file = @import("Untitled-0.zig");
        ,
        // Untitled-2.zig
        \\const file = @import("Untitled-1.zig").file;
        \\const foo: file.<0> = undefined;
        ,
    }, true);
}

test "cross-file - alias" {
    try testMultiFileSymbolReferences(&.{
        // Untitled-0.zig
        \\pub const <0> = struct {
        \\    fn foo(_: <0>) void {}
        \\    var bar: <0> = undefined;
        \\};
        ,
        // Untitled-1.zig
        \\const <0> = @import("Untitled-0.zig").<0>;
        \\comptime {
        \\    _ = <0>;
        \\}
        ,
    }, true);
}

fn testSymbolReferences(source: []const u8) !void {
    return testMultiFileSymbolReferences(&.{source}, true);
}

/// source files have the following name pattern: `untitled-{d}.zig`
fn testMultiFileSymbolReferences(sources: []const []const u8, include_decl: bool) !void {
    const placeholder_name = "placeholder";

    var ctx: Context = try .init();
    defer ctx.deinit();

    const File = struct { source: []const u8, new_source: []const u8 };
    const LocPair = struct { file_index: usize, old: offsets.Loc, new: offsets.Loc };

    var files: std.StringArrayHashMapUnmanaged(File) = .empty;
    defer {
        for (files.values()) |file| allocator.free(file.new_source);
        files.deinit(allocator);
    }

    var loc_set: std.StringArrayHashMapUnmanaged(std.MultiArrayList(LocPair)) = .empty;
    defer {
        for (loc_set.values()) |*locs| locs.deinit(allocator);
        loc_set.deinit(allocator);
    }

    try files.ensureTotalCapacity(allocator, sources.len);
    for (sources, 0..) |source, file_index| {
        var phr = try helper.collectReplacePlaceholders(allocator, source, placeholder_name);
        defer phr.deinit(allocator);

        const uri = try ctx.addDocument(.{ .source = phr.new_source });
        files.putAssumeCapacityNoClobber(uri.raw, .{ .source = source, .new_source = phr.new_source });
        phr.new_source = ""; // `files` takes ownership of `new_source` from `phr`

        for (phr.locations.items(.old), phr.locations.items(.new)) |old, new| {
            const name = offsets.locToSlice(source, old);
            const gop = try loc_set.getOrPutValue(allocator, name, .{});
            try gop.value_ptr.append(allocator, .{ .file_index = file_index, .old = old, .new = new });
        }
    }

    var error_builder: ErrorBuilder = .init(allocator);
    defer error_builder.deinit();
    errdefer error_builder.writeDebug();

    for (files.keys(), files.values()) |file_uri, file| {
        try error_builder.addFile(file_uri, file.new_source);
    }

    for (loc_set.values()) |locs| {
        error_builder.clearMessages();

        for (locs.items(.file_index), locs.items(.new)) |file_index, new_loc| {
            const file = files.values()[file_index];
            const file_uri = files.keys()[file_index];

            const middle = new_loc.start + (new_loc.end - new_loc.start) / 2;
            const params: types.reference.Params = .{
                .textDocument = .{ .uri = file_uri },
                .position = offsets.indexToPosition(file.new_source, middle, ctx.server.offset_encoding),
                .context = .{ .includeDeclaration = include_decl },
            };
            const response = try ctx.server.sendRequestSync(ctx.arena.allocator(), "textDocument/references", params);

            try error_builder.msgAtLoc("asked for references here", file_uri, new_loc, .info, .{});

            const actual_locations: []const types.Location = response orelse {
                std.debug.print("Server returned `null` as the result\n", .{});
                return error.InvalidResponse;
            };

            // keeps track of expected locations that have been given by the server
            // used to detect double references and missing references
            var visited: std.DynamicBitSetUnmanaged = try .initEmpty(allocator, locs.len);
            defer visited.deinit(allocator);

            for (actual_locations) |response_location| {
                const actual_file_index = files.getIndex(response_location.uri) orelse {
                    std.debug.print("received location to unknown file `{s}` as the result\n", .{response_location.uri});
                    return error.InvalidReference;
                };
                const actual_file_source = files.values()[actual_file_index].new_source;
                const actual_loc = offsets.rangeToLoc(actual_file_source, response_location.range, ctx.server.offset_encoding);

                const index = found_index: {
                    for (locs.items(.new), locs.items(.file_index), 0..) |expected_loc, expected_file_index, idx| {
                        if (expected_file_index != actual_file_index) continue;
                        if (expected_loc.start != actual_loc.start) continue;
                        if (expected_loc.end != actual_loc.end) continue;
                        break :found_index idx;
                    }
                    try error_builder.msgAtLoc("server returned unexpected reference!", response_location.uri, actual_loc, .err, .{});
                    return error.UnexpectedReference;
                };

                if (visited.isSet(index)) {
                    try error_builder.msgAtLoc("server returned duplicate reference!", response_location.uri, actual_loc, .err, .{});
                    return error.DuplicateReference;
                } else {
                    visited.set(index);
                }
            }

            var has_unvisited = false;
            var unvisited_it = visited.iterator(.{ .kind = .unset });
            while (unvisited_it.next()) |index| {
                const unvisited_file_index = locs.items(.file_index)[index];
                const unvisited_uri = files.keys()[unvisited_file_index];
                const unvisited_loc = locs.items(.new)[index];
                try error_builder.msgAtLoc("expected reference here!", unvisited_uri, unvisited_loc, .err, .{});
                has_unvisited = true;
            }

            if (has_unvisited) return error.ExpectedReference;
        }
    }
}

test "matching control flow - unlabeled loop" {
    try testSimpleReferences(
        \\const foo = for<cursor> (0..1) |i| {
        \\    <loc>break</loc> i;
        \\};
    );
    try testSimpleReferences(
        \\const foo = <loc>for</loc> (0..1) |i| {
        \\    break<cursor> i;
        \\};
    );

    try testSimpleReferences(
        \\const foo = while<cursor> (true) {
        \\    <loc>continue</loc>;
        \\};
    );
    try testSimpleReferences(
        \\const foo = <loc>for</loc> (0..1) |i| {
        \\    continue<cursor> i;
        \\};
    );
}

test "matching control flow - labeled loop" {
    try testSimpleReferences(
        \\const foo = blk: for<cursor> (0..1) |i| {
        \\    if (i == 0) {
        \\        <loc>continue</loc>;
        \\    } else {
        \\        <loc>break</loc> :blk 5;
        \\    }
        \\};
    );
    try testSimpleReferences(
        \\const foo = blk: <loc>for</loc> (0..1) |i| {
        \\    if (i == 0) {
        \\        continue<cursor>;
        \\    } else {
        \\        break :blk 5;
        \\    }
        \\};
    );
    try testSimpleReferences(
        \\const foo = blk: <loc>while</loc> (true) {
        \\    if (i == 0) {
        \\        continue;
        \\    } else {
        \\        break<cursor> :blk 5;
        \\    }
        \\};
    );
}

test "matching control flow - nested loop with outer label" {
    try testSimpleReferences(
        \\const foo = outer: for<cursor> (0..1) |i| {
        \\    for (0..1) |j| {
        \\        if (i == j) {
        \\            break;
        \\        } else {
        \\            <loc>break</loc> :outer 5;
        \\        }
        \\    }
        \\};
    );
    try testSimpleReferences(
        \\const foo = outer: for (0..1) |i| {
        \\    <loc>for</loc> (0..1) |j| {
        \\        if (i == j) {
        \\            break<cursor>;
        \\        } else {
        \\            break :outer 5;
        \\        }
        \\    }
        \\};
    );
    try testSimpleReferences(
        \\const foo = outer: <loc>for</loc> (0..1) |i| {
        \\    for (0..1) |j| {
        \\        if (i == j) {
        \\            break;
        \\        } else {
        \\            break<cursor> :outer 5;
        \\        }
        \\    }
        \\};
    );
}

test "matching control flow - nested loop with inner label" {
    try testSimpleReferences(
        \\const foo = for (0..1) |i| {
        \\    inner: for<cursor> (0..1) |j| {
        \\        if (i == j) {
        \\            <loc>break</loc>;
        \\        } else {
        \\            <loc>break</loc> :inner 5;
        \\        }
        \\    }
        \\};
    );
    try testSimpleReferences(
        \\const foo = for (0..1) |i| {
        \\    inner: <loc>for</loc> (0..1) |j| {
        \\        if (i == j) {
        \\            break<cursor>;
        \\        } else {
        \\            break :outer 5;
        \\        }
        \\    }
        \\};
    );
    try testSimpleReferences(
        \\const foo = for (0..1) |i| {
        \\    inner: <loc>for</loc> (0..1) |j| {
        \\        if (i == j) {
        \\            break;
        \\        } else {
        \\            break<cursor> :inner 5;
        \\        }
        \\    }
        \\};
    );
}

test "matching control flow - labeled switch" {
    try testSimpleReferences(
        \\const foo = blk: switch<cursor> (undefined) {
        \\    .foo => <loc>break</loc> :blk 5,
        \\    .bar => <loc>continue</loc> :blk 5,
        \\};
    );
    try testSimpleReferences(
        \\const foo = blk: <loc>switch</loc> (undefined) {
        \\    .foo => break<cursor> :blk 5,
        \\    .bar => continue :blk 5,
        \\};
    );
    try testSimpleReferences(
        \\const foo = blk: <loc>switch</loc> (undefined) {
        \\    .foo => break :blk 5,
        \\    .bar => continue<cursor> :blk 5,
        \\};
    );
}

test "matching control flow - unlabeled switch" {
    try testSimpleReferences(
        \\const foo = switch<cursor> (undefined) {
        \\    .foo => break 5,
        \\    .foo => continue 5,
        \\};
    );
    try testSimpleReferences(
        \\const foo = switch (undefined) {
        \\    .foo => break<cursor> 5,
        \\    .foo => continue 5,
        \\};
    );
    try testSimpleReferences(
        \\const foo = switch (undefined) {
        \\    .foo => break 5,
        \\    .foo => continue<cursor> 5,
        \\};
    );
}

test "escaped identifier with same name as primitive" {
    try testSimpleReferences(
        \\const @"null"<cursor> = undefined;
        \\const foo = null;
        \\const bar = <loc>@"null"</loc>;
    );
    try testSimpleReferences(
        \\const @"i32"<cursor> = undefined;
        \\const foo = i32;
        \\const bar = <loc>@"i32"</loc>;
    );
}

fn testSimpleReferences(source: []const u8) !void {
    var phr = try helper.collectClearPlaceholders(allocator, source);
    defer phr.deinit(allocator);

    std.debug.assert(phr.locations.len % 2 == 1);
    var expected_locations: std.ArrayList(offsets.Loc) = try .initCapacity(allocator, phr.locations.len / 2);
    defer expected_locations.deinit(allocator);

    const cursor_index = for (phr.locations.items(.old), phr.locations.items(.new), 0..) |old, new, i| {
        const name = offsets.locToSlice(source, old);
        if (!std.mem.eql(u8, name, "<cursor>")) continue;
        phr.locations.orderedRemove(i);
        std.debug.assert(new.start == new.end);
        break new.start;
    } else @panic("missing <cursor> placeholder");

    {
        var i: usize = 0;
        while (i != phr.locations.len) : (i += 2) {
            std.debug.assert(std.mem.eql(u8, "<loc>", offsets.locToSlice(source, phr.locations.items(.old)[i])));
            std.debug.assert(std.mem.eql(u8, "</loc>", offsets.locToSlice(source, phr.locations.items(.old)[i + 1])));
            const start_loc = phr.locations.items(.new)[i];
            const end_loc = phr.locations.items(.new)[i + 1];
            std.debug.assert(start_loc.start == start_loc.end);
            std.debug.assert(end_loc.start == end_loc.end);
            expected_locations.appendAssumeCapacity(.{ .start = start_loc.start, .end = end_loc.start });
        }
    }

    var ctx: Context = try .init();
    defer ctx.deinit();

    const file_uri = try ctx.addDocument(.{ .source = phr.new_source });

    var error_builder: ErrorBuilder = .init(allocator);
    defer error_builder.deinit();
    errdefer error_builder.writeDebug();

    try error_builder.addFile(file_uri.raw, phr.new_source);
    try error_builder.msgAtIndex("requested references here", file_uri.raw, cursor_index, .info, .{});

    const params: types.reference.Params = .{
        .textDocument = .{ .uri = file_uri.raw },
        .position = offsets.indexToPosition(phr.new_source, cursor_index, ctx.server.offset_encoding),
        .context = .{ .includeDeclaration = false },
    };
    const actual_locations: []const types.Location = try ctx.server.sendRequestSync(ctx.arena.allocator(), "textDocument/references", params) orelse {
        std.debug.print("Server returned `null` as the result\n", .{});
        return error.InvalidResponse;
    };

    // keeps track of expected locations that have been given by the server
    // used to detect double references and missing references
    var visited: std.DynamicBitSetUnmanaged = try .initEmpty(allocator, expected_locations.items.len);
    defer visited.deinit(allocator);

    for (actual_locations) |response_location| {
        std.debug.assert(std.mem.eql(u8, response_location.uri, file_uri.raw));
        const actual_loc = offsets.rangeToLoc(phr.new_source, response_location.range, ctx.server.offset_encoding);

        const index = found_index: {
            for (expected_locations.items, 0..) |expected_loc, idx| {
                if (expected_loc.start != actual_loc.start) continue;
                if (expected_loc.end != actual_loc.end) continue;
                break :found_index idx;
            }
            try error_builder.msgAtLoc("server returned unexpected reference!", file_uri.raw, actual_loc, .err, .{});
            return error.UnexpectedReference;
        };

        if (visited.isSet(index)) {
            try error_builder.msgAtLoc("server returned duplicate reference!", file_uri.raw, actual_loc, .err, .{});
            return error.DuplicateReference;
        } else {
            visited.set(index);
        }
    }

    var has_unvisited = false;
    var unvisited_it = visited.iterator(.{ .kind = .unset });
    while (unvisited_it.next()) |index| {
        const unvisited_loc = expected_locations.items[index];
        try error_builder.msgAtLoc("expected reference here!", file_uri.raw, unvisited_loc, .err, .{});
        has_unvisited = true;
    }

    if (has_unvisited) return error.ExpectedReference;
}

test "eager transitive import loading" {
    // R5: Opening a file with file:// URI eagerly loads transitive imports.
    // Fixture chain: a.zig -> b.zig -> c.zig
    // Open only a.zig, assert c.zig is in the DocumentStore.

    const io = std.testing.io;

    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);

    const a_path = try std.Io.Dir.path.resolve(allocator, &.{ cwd, "tests/fixtures/eager_load/a.zig" });
    defer allocator.free(a_path);
    const c_path = try std.Io.Dir.path.resolve(allocator, &.{ cwd, "tests/fixtures/eager_load/c.zig" });
    defer allocator.free(c_path);

    const a_uri: zls.Uri = try .fromPath(allocator, a_path);
    defer a_uri.deinit(allocator);
    const c_uri: zls.Uri = try .fromPath(allocator, c_path);
    defer c_uri.deinit(allocator);

    var ctx: Context = try .init();
    defer ctx.deinit();

    // Open only a.zig — do NOT open b.zig or c.zig
    _ = try ctx.server.sendNotificationSync(ctx.arena.allocator(), "textDocument/didOpen", .{
        .textDocument = .{
            .uri = a_uri.raw,
            .languageId = .{ .custom_value = "zig" },
            .version = 1,
            .text = @embedFile("../fixtures/eager_load/a.zig"),
        },
    });

    // c.zig should be in the store via transitive eager loading: a -> b -> c
    const c_handle = ctx.server.document_store.getHandle(c_uri);
    try std.testing.expect(c_handle != null);
}

test "on-demand import loading in reference search" {
    // R6: gatherWorkspaceReferenceCandidates fallback path reloads imports
    // not in the store during the reference search iteration.
    // Fixture chain: a.zig -> b.zig -> c.zig (all exist on disk).
    // Open a.zig (R5 loads b and c), purge b.zig, then findReferences on
    // `value` in c.zig. Analysis resolves `value` locally (no cross-file load).
    // Without R6: b not iterated, per_file_dependants[c]={}, only c searched.
    // With R6: a's import of b triggers reload, b iterated, b's import of c
    // recorded, dependant map complete, b.zig's reference to c.value found.

    const io = std.testing.io;

    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);

    const a_path = try std.Io.Dir.path.resolve(allocator, &.{ cwd, "tests/fixtures/eager_load/a.zig" });
    defer allocator.free(a_path);
    const b_path = try std.Io.Dir.path.resolve(allocator, &.{ cwd, "tests/fixtures/eager_load/b.zig" });
    defer allocator.free(b_path);
    const c_path = try std.Io.Dir.path.resolve(allocator, &.{ cwd, "tests/fixtures/eager_load/c.zig" });
    defer allocator.free(c_path);

    const a_uri: zls.Uri = try .fromPath(allocator, a_path);
    defer a_uri.deinit(allocator);
    const b_uri: zls.Uri = try .fromPath(allocator, b_path);
    defer b_uri.deinit(allocator);
    const c_uri: zls.Uri = try .fromPath(allocator, c_path);
    defer c_uri.deinit(allocator);

    var ctx: Context = try .init();
    defer ctx.deinit();

    // Open a.zig (R5 eagerly loads b.zig and c.zig)
    _ = try ctx.server.sendNotificationSync(ctx.arena.allocator(), "textDocument/didOpen", .{
        .textDocument = .{
            .uri = a_uri.raw,
            .languageId = .{ .custom_value = "zig" },
            .version = 1,
            .text = @embedFile("../fixtures/eager_load/a.zig"),
        },
    });

    // Verify b.zig was loaded by R5
    try std.testing.expect(ctx.server.document_store.getHandle(b_uri) != null);

    // Purge b.zig — the middle of the import chain
    _ = try ctx.server.sendNotificationSync(ctx.arena.allocator(), "textDocument/didClose", .{
        .textDocument = .{ .uri = b_uri.raw },
    });
    try std.testing.expect(ctx.server.document_store.getHandle(b_uri) == null);

    // Force the fallback path in gatherWorkspaceReferenceCandidates by
    // marking handles as having no associated build file. Without this,
    // file:// URIs inside the project tree find the project's build.zig,
    // whose config is unresolved async, causing the function to return empty.
    {
        var handle_it: zls.DocumentStore.HandleIterator = .{ .store = &ctx.server.document_store };
        while (handle_it.next()) |handle| {
            handle.impl.associated_build_file = .none;
        }
    }

    // findReferences on `value` defined in c.zig.
    // Analysis resolves `value` locally in c.zig — no cross-file load triggered.
    // The fallback path iterates handles (a, c). a's file_imports = [b].
    // R6 reloads b mid-iteration. b's file_imports = [c] → per_file_dependants[c] = [b].
    // Dependant walk from c finds b, then a. All three files searched.
    const c_source = @embedFile("../fixtures/eager_load/c.zig");
    const value_pos = offsets.indexToPosition(
        c_source,
        std.mem.indexOf(u8, c_source, "value").?,
        ctx.server.offset_encoding,
    );

    const response = try ctx.server.sendRequestSync(
        ctx.arena.allocator(),
        "textDocument/references",
        types.reference.Params{
            .textDocument = .{ .uri = c_uri.raw },
            .position = value_pos,
            .context = .{ .includeDeclaration = true },
        },
    );

    const locations: []const types.Location = response orelse {
        std.debug.print("Server returned `null` for findReferences\n", .{});
        return error.InvalidResponse;
    };

    // b.zig references c.value — proving R6 reloaded b and the dependant map is complete
    var found_b = false;
    for (locations) |loc| {
        if (std.mem.eql(u8, loc.uri, b_uri.raw)) {
            found_b = true;
            break;
        }
    }
    try std.testing.expect(found_b);
}

test "ensureHandleLoaded skips URIs already in store" {
    // Contract: calling ensureHandleLoaded on a URI that's already in the
    // handles map must not call getOrLoadHandle (which would await the
    // future). It must return immediately and not add a duplicate.

    const io = std.testing.io;

    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);

    const a_path = try std.Io.Dir.path.resolve(allocator, &.{ cwd, "tests/fixtures/eager_load/a.zig" });
    defer allocator.free(a_path);

    const a_uri: zls.Uri = try .fromPath(allocator, a_path);
    defer a_uri.deinit(allocator);

    var ctx: Context = try .init();
    defer ctx.deinit();

    // Open a.zig — adds a (and via R5 b, c) to the store
    _ = try ctx.server.sendNotificationSync(ctx.arena.allocator(), "textDocument/didOpen", .{
        .textDocument = .{
            .uri = a_uri.raw,
            .languageId = .{ .custom_value = "zig" },
            .version = 1,
            .text = @embedFile("../fixtures/eager_load/a.zig"),
        },
    });

    const count_before = ctx.server.document_store.handles.count();
    try std.testing.expect(ctx.server.document_store.getHandle(a_uri) != null);

    // Calling ensureHandleLoaded on the existing URI must be a no-op
    try ctx.server.document_store.ensureHandleLoaded(a_uri);

    const count_after = ctx.server.document_store.handles.count();
    try std.testing.expectEqual(count_before, count_after);
    try std.testing.expect(ctx.server.document_store.getHandle(a_uri) != null);
}

test "ensureHandleLoaded ignores non-file scheme URIs" {
    // Contract: non-file URIs (untitled://, etc.) cannot be loaded from
    // disk, so ensureHandleLoaded must be a no-op for them — no error,
    // no addition to the store.

    var ctx: Context = try .init();
    defer ctx.deinit();

    const fake_uri: zls.Uri = try .parse(ctx.arena.allocator(), "untitled:///does-not-exist.zig");

    const count_before = ctx.server.document_store.handles.count();

    try ctx.server.document_store.ensureHandleLoaded(fake_uri);

    const count_after = ctx.server.document_store.handles.count();
    try std.testing.expectEqual(count_before, count_after);
}

test "ensureHandleLoaded loads file:// URIs not in store" {
    // Contract: calling ensureHandleLoaded on a file:// URI that's not in
    // the store must load it from disk and add it to the handles map.

    const io = std.testing.io;

    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);

    const c_path = try std.Io.Dir.path.resolve(allocator, &.{ cwd, "tests/fixtures/eager_load/c.zig" });
    defer allocator.free(c_path);

    const c_uri: zls.Uri = try .fromPath(allocator, c_path);
    defer c_uri.deinit(allocator);

    var ctx: Context = try .init();
    defer ctx.deinit();

    // c.zig is not in the store
    try std.testing.expect(ctx.server.document_store.getHandle(c_uri) == null);

    try ctx.server.document_store.ensureHandleLoaded(c_uri);

    // Now it is
    try std.testing.expect(ctx.server.document_store.getHandle(c_uri) != null);
}

test "adversarial: self-referential import does not deadlock" {
    // self_ref.zig contains `@import("self_ref.zig")` — a self-loop in
    // the parsed AST. Zig rejects this at semantic analysis, but the
    // parser and collectImports both accept it. Before the ensureHandleLoaded
    // fix, R5's eager loading would call getOrLoadHandle(self_uri) which
    // would re-enter createAndStoreDocument, find the handle existing with
    // event unset, and deadlock on the await.

    const io = std.testing.io;

    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);

    const self_path = try std.Io.Dir.path.resolve(allocator, &.{ cwd, "tests/fixtures/eager_load/self_ref.zig" });
    defer allocator.free(self_path);

    const self_uri: zls.Uri = try .fromPath(allocator, self_path);
    defer self_uri.deinit(allocator);

    var ctx: Context = try .init();
    defer ctx.deinit();

    _ = try ctx.server.sendNotificationSync(ctx.arena.allocator(), "textDocument/didOpen", .{
        .textDocument = .{
            .uri = self_uri.raw,
            .languageId = .{ .custom_value = "zig" },
            .version = 1,
            .text = @embedFile("../fixtures/eager_load/self_ref.zig"),
        },
    });

    try std.testing.expect(ctx.server.document_store.getHandle(self_uri) != null);
}

test "adversarial: circular import chain does not deadlock" {
    // cycle_a.zig imports cycle_b.zig imports cycle_a.zig.
    // Zig rejects the cycle at semantic analysis; parser accepts it.
    // Opening cycle_a should load cycle_b, and cycle_b's eager loading
    // should hit cycle_a already in store (Option 1 fix: event.set before
    // recursive loading). ensureHandleLoaded skips via contains check.

    const io = std.testing.io;

    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);

    const a_path = try std.Io.Dir.path.resolve(allocator, &.{ cwd, "tests/fixtures/eager_load/cycle_a.zig" });
    defer allocator.free(a_path);
    const b_path = try std.Io.Dir.path.resolve(allocator, &.{ cwd, "tests/fixtures/eager_load/cycle_b.zig" });
    defer allocator.free(b_path);

    const a_uri: zls.Uri = try .fromPath(allocator, a_path);
    defer a_uri.deinit(allocator);
    const b_uri: zls.Uri = try .fromPath(allocator, b_path);
    defer b_uri.deinit(allocator);

    var ctx: Context = try .init();
    defer ctx.deinit();

    _ = try ctx.server.sendNotificationSync(ctx.arena.allocator(), "textDocument/didOpen", .{
        .textDocument = .{
            .uri = a_uri.raw,
            .languageId = .{ .custom_value = "zig" },
            .version = 1,
            .text = @embedFile("../fixtures/eager_load/cycle_a.zig"),
        },
    });

    // Both cycle_a and cycle_b should be loaded
    try std.testing.expect(ctx.server.document_store.getHandle(a_uri) != null);
    try std.testing.expect(ctx.server.document_store.getHandle(b_uri) != null);
}

test "adversarial: import of nonexistent file is handled gracefully" {
    // R5 eager loading and ensureHandleLoaded must not crash when an
    // @import points to a file that doesn't exist on disk. getOrLoadHandle
    // returns null for missing files; ensureHandleLoaded's `_ = try`
    // swallows the null without propagating.

    const io = std.testing.io;

    // Use an untitled:// URI with inline content that imports a nonexistent file.
    // This avoids needing a fixture file that imports a phantom.
    var ctx: Context = try .init();
    defer ctx.deinit();

    // Use addDocument which uses untitled:// — eager loading for non-file
    // schemes is a no-op via isFileScheme early return in ensureHandleLoaded.
    // For a file:// scenario, we'd need a fixture. Instead, verify the
    // analogous file:// path using c.zig which exists but with an artificial
    // "missing" sibling in file_imports.
    //
    // Simpler: create a fixture that imports a nonexistent file.
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);

    const parent_path = try std.Io.Dir.path.resolve(allocator, &.{ cwd, "tests/fixtures/eager_load/ghost_parent.zig" });
    defer allocator.free(parent_path);

    const parent_uri: zls.Uri = try .fromPath(allocator, parent_path);
    defer parent_uri.deinit(allocator);

    // didOpen must succeed even though ghost_parent imports a nonexistent file
    _ = try ctx.server.sendNotificationSync(ctx.arena.allocator(), "textDocument/didOpen", .{
        .textDocument = .{
            .uri = parent_uri.raw,
            .languageId = .{ .custom_value = "zig" },
            .version = 1,
            .text = @embedFile("../fixtures/eager_load/ghost_parent.zig"),
        },
    });

    try std.testing.expect(ctx.server.document_store.getHandle(parent_uri) != null);
}

test "unresolved build file falls through to fallback path" {
    // Regression: gatherWorkspaceReferenceCandidates used to return .empty when
    // a handle's associated_build_file was .unresolved (build runner still
    // running or failed). With no client refresh signal for references, every
    // cold-start cross-file query in a build.zig project returned empty until
    // the background worker happened to finish. Fix falls through to the
    // fallback path (same behaviour as .none) so Phase 1's eager-loaded handles
    // get walked regardless of build config state.

    const io = std.testing.io;

    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);

    const a_path = try std.Io.Dir.path.resolve(allocator, &.{ cwd, "tests/fixtures/eager_load/a.zig" });
    defer allocator.free(a_path);
    const b_path = try std.Io.Dir.path.resolve(allocator, &.{ cwd, "tests/fixtures/eager_load/b.zig" });
    defer allocator.free(b_path);

    const a_uri: zls.Uri = try .fromPath(allocator, a_path);
    defer a_uri.deinit(allocator);
    const b_uri: zls.Uri = try .fromPath(allocator, b_path);
    defer b_uri.deinit(allocator);

    var ctx: Context = try .init();
    defer ctx.deinit();

    // Open a.zig — R5 eager loading pulls b.zig and c.zig into the store.
    _ = try ctx.server.sendNotificationSync(ctx.arena.allocator(), "textDocument/didOpen", .{
        .textDocument = .{
            .uri = a_uri.raw,
            .languageId = .{ .custom_value = "zig" },
            .version = 1,
            .text = @embedFile("../fixtures/eager_load/a.zig"),
        },
    });

    try std.testing.expect(ctx.server.document_store.getHandle(b_uri) != null);

    // Construct a fake BuildFile whose impl.config is null. isAssociatedWith
    // will hit `tryLockConfig orelse return .unknown`, so getAssociatedBuildFile
    // returns .unresolved on every call — the exact state that used to cause
    // the early-bail.
    const fake_uri: zls.Uri = try .fromPath(allocator, a_path);
    var fake_bf = zls.DocumentStore.BuildFile{ .uri = fake_uri };
    defer fake_bf.uri.deinit(allocator);

    // Force every loaded handle into the .unresolved state pointing at the
    // fake build file. Each handle's AssociatedBuildFile.State.deinit (via
    // the store's handle deinit) will free the slice and bitset we allocate
    // here.
    {
        var handle_it: zls.DocumentStore.HandleIterator = .{ .store = &ctx.server.document_store };
        while (handle_it.next()) |handle| {
            const potential = try allocator.alloc(*zls.DocumentStore.BuildFile, 1);
            potential[0] = &fake_bf;
            const checked = try std.DynamicBitSetUnmanaged.initEmpty(allocator, 1);
            handle.impl.associated_build_file = .{ .unresolved = .{
                .potential_build_files = potential,
                .has_been_checked = checked,
            } };
        }
    }

    // findReferences on `doubled` declared in b.zig. a.zig contains `b.doubled`.
    // Before fix: .unresolved → return .empty → only the definition in b.zig.
    // After fix:  falls through to fallback → a.zig walked → reference found.
    const b_source = @embedFile("../fixtures/eager_load/b.zig");
    const doubled_pos = offsets.indexToPosition(
        b_source,
        std.mem.indexOf(u8, b_source, "doubled").?,
        ctx.server.offset_encoding,
    );

    const response = try ctx.server.sendRequestSync(
        ctx.arena.allocator(),
        "textDocument/references",
        types.reference.Params{
            .textDocument = .{ .uri = b_uri.raw },
            .position = doubled_pos,
            .context = .{ .includeDeclaration = true },
        },
    );

    const locations: []const types.Location = response orelse {
        std.debug.print("Server returned `null` for findReferences\n", .{});
        return error.InvalidResponse;
    };

    var found_a = false;
    for (locations) |loc| {
        if (std.mem.eql(u8, loc.uri, a_uri.raw)) {
            found_a = true;
            break;
        }
    }
    try std.testing.expect(found_a);
}

test "callsiteReferences thin wrapper preserves top-level callsites (zls-239)" {
    // Regression guard: the thin wrapper from zls-239 projects
    // CallSite -> NodeWithHandle for backward compatibility with
    // src/analysis.zig:1775's callsite-based type inference.
    // It MUST preserve every call site, including ones whose enclosing
    // scope is not a function (e.g. calls inside a top-level comptime block).
    // If the wrapper filtered those out, type-inference coverage would
    // silently regress across the workspace.
    const source =
        \\fn target() void {}
        \\fn fn_caller() void {
        \\    target();
        \\}
        \\comptime {
        \\    target();
        \\}
    ;

    var ctx: Context = try .init();
    defer ctx.deinit();

    const uri = try ctx.addDocument(.{ .source = source });
    const handle = ctx.server.document_store.getHandle(uri).?;
    const tree = handle.tree;

    // Find the fn_decl for `target` — the first fn_decl in the tree.
    var target_node: ?std.zig.Ast.Node.Index = null;
    for (0..tree.nodes.len) |i| {
        const idx: std.zig.Ast.Node.Index = @enumFromInt(@as(u32, @intCast(i)));
        if (tree.nodeTag(idx) == .fn_decl) {
            target_node = idx;
            break;
        }
    }
    try std.testing.expect(target_node != null);

    var analyser = ctx.server.initAnalyser(ctx.arena.allocator(), handle);
    defer analyser.deinit();

    const decl_handle: zls.Analyser.DeclWithHandle = .{
        .decl = .{ .ast_node = target_node.? },
        .handle = handle,
    };

    const refs = try zls.references.callsiteReferences(&analyser, decl_handle, false);

    // Expected: 2 call sites — one from `fn_caller` and one from the top-level
    // comptime block. If the wrapper filtered the comptime-block caller (whose
    // CallSite.caller_fn_node is null), we'd see only 1.
    try std.testing.expectEqual(@as(usize, 2), refs.items.len);
}

test "findReferences across module-name import, fallback path (zls-mxw)" {
    // Same feature, fallback path. Build-system is bypassed by leaving
    // `root_handle.associated_build_file = .none`, which short-circuits the
    // `no_build_file` block in `gatherWorkspaceReferenceCandidates`. The
    // fallback iterates every handle and records `handle imports X` edges
    // into `per_file_dependants` — my fix makes that loop also walk
    // `handle.resolved_imports`, so module-name edges participate in the
    // reverse walk that finds callers of a target.
    //
    // Cursor is in b.zig on `doubled` — the classic "who calls me?" query.

    const io = std.testing.io;

    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);

    const a_path = try std.Io.Dir.path.resolve(allocator, &.{ cwd, "tests/fixtures/module_imports/a.zig" });
    defer allocator.free(a_path);
    const b_path = try std.Io.Dir.path.resolve(allocator, &.{ cwd, "tests/fixtures/module_imports/b.zig" });
    defer allocator.free(b_path);
    const build_zig_path = try std.Io.Dir.path.resolve(allocator, &.{ cwd, "tests/fixtures/module_imports/build.zig" });
    defer allocator.free(build_zig_path);

    const a_uri: zls.Uri = try .fromPath(allocator, a_path);
    defer a_uri.deinit(allocator);
    const b_uri: zls.Uri = try .fromPath(allocator, b_path);
    defer b_uri.deinit(allocator);

    var ctx: Context = try .init();
    defer ctx.deinit();

    _ = try ctx.server.sendNotificationSync(ctx.arena.allocator(), "textDocument/didOpen", .{
        .textDocument = .{
            .uri = b_uri.raw,
            .languageId = .{ .custom_value = "zig" },
            .version = 1,
            .text = @embedFile("../fixtures/module_imports/b.zig"),
        },
    });
    _ = try ctx.server.sendNotificationSync(ctx.arena.allocator(), "textDocument/didOpen", .{
        .textDocument = .{
            .uri = a_uri.raw,
            .languageId = .{ .custom_value = "zig" },
            .version = 1,
            .text = @embedFile("../fixtures/module_imports/a.zig"),
        },
    });

    const a_handle = ctx.server.document_store.getHandle(a_uri) orelse return error.AHandleMissing;

    const config_json = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "dependencies": {{}},
        \\  "modules": {{
        \\    "{s}": {{
        \\      "import_table": {{
        \\        "mod_b": "{s}"
        \\      }},
        \\      "c_macros": [],
        \\      "include_dirs": []
        \\    }},
        \\    "{s}": {{
        \\      "import_table": {{}},
        \\      "c_macros": [],
        \\      "include_dirs": []
        \\    }}
        \\  }},
        \\  "compilations": [],
        \\  "top_level_steps": [],
        \\  "available_options": {{}}
        \\}}
    , .{ a_path, b_path, b_path });
    defer allocator.free(config_json);

    var fb = try helper_build.makeResolved(allocator, build_zig_path, config_json);
    defer fb.deinit();

    try helper_build.stampResolved(&ctx.server.document_store, a_handle, fb.build_file, a_path);

    // Warm the cache while a_handle is still .resolved — uriFromImportStr
    // needs the build-file path to resolve "mod_b".
    _ = try ctx.server.document_store.uriFromImportStr(
        ctx.arena.allocator(),
        a_handle,
        "mod_b",
    );

    // Force fallback path by marking ONLY the root handle (b_handle) as
    // .none. `gatherWorkspaceReferenceCandidates` gates on `root_handle`'s
    // state — .none short-circuits the no_build_file block. Keeping a_handle
    // at .resolved preserves mod_b → b.zig resolution during the actual
    // reference walk (collectReferences on a.zig reads a_handle's build
    // file to match `mod_b.doubled` against the target symbol).
    //
    // Overwriting .resolved with .none leaks the prior state's
    // root_source_file; leaving a_handle alone avoids the leak. b_handle
    // starts as .init (never stamped), so forcing .none is a clean write.
    const b_handle_for_force = ctx.server.document_store.getHandle(b_uri) orelse return error.BHandleMissing;
    b_handle_for_force.impl.associated_build_file = .none;

    const b_source = @embedFile("../fixtures/module_imports/b.zig");
    const doubled_pos = offsets.indexToPosition(
        b_source,
        std.mem.indexOf(u8, b_source, "doubled").?,
        ctx.server.offset_encoding,
    );

    const response = try ctx.server.sendRequestSync(
        ctx.arena.allocator(),
        "textDocument/references",
        types.reference.Params{
            .textDocument = .{ .uri = b_uri.raw },
            .position = doubled_pos,
            .context = .{ .includeDeclaration = true },
        },
    );

    const locations: []const types.Location = response orelse {
        std.debug.print("Server returned `null` for findReferences\n", .{});
        return error.InvalidResponse;
    };

    var found_a = false;
    for (locations) |loc| {
        if (std.mem.eql(u8, loc.uri, a_uri.raw)) {
            found_a = true;
            break;
        }
    }
    try std.testing.expect(found_a);
}

test "resolved_imports cleared on handle re-parse (zls-mxw R-M4)" {
    // R-M4: when a handle's tree is replaced (re-parse via didChange),
    // its resolved_imports set must be cleared. Without the clear, stale
    // URIs (e.g., an import string that was renamed) would live forever
    // and pollute reverse reference search. Directly inspects the field
    // before and after re-parse.

    const io = std.testing.io;

    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);

    const a_path = try std.Io.Dir.path.resolve(allocator, &.{ cwd, "tests/fixtures/module_imports/a.zig" });
    defer allocator.free(a_path);
    const b_path = try std.Io.Dir.path.resolve(allocator, &.{ cwd, "tests/fixtures/module_imports/b.zig" });
    defer allocator.free(b_path);
    const build_zig_path = try std.Io.Dir.path.resolve(allocator, &.{ cwd, "tests/fixtures/module_imports/build.zig" });
    defer allocator.free(build_zig_path);

    const a_uri: zls.Uri = try .fromPath(allocator, a_path);
    defer a_uri.deinit(allocator);

    var ctx: Context = try .init();
    defer ctx.deinit();

    _ = try ctx.server.sendNotificationSync(ctx.arena.allocator(), "textDocument/didOpen", .{
        .textDocument = .{
            .uri = a_uri.raw,
            .languageId = .{ .custom_value = "zig" },
            .version = 1,
            .text = @embedFile("../fixtures/module_imports/a.zig"),
        },
    });

    const a_handle = ctx.server.document_store.getHandle(a_uri) orelse return error.AHandleMissing;

    const config_json = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "dependencies": {{}},
        \\  "modules": {{
        \\    "{s}": {{
        \\      "import_table": {{
        \\        "mod_b": "{s}"
        \\      }},
        \\      "c_macros": [],
        \\      "include_dirs": []
        \\    }},
        \\    "{s}": {{
        \\      "import_table": {{}},
        \\      "c_macros": [],
        \\      "include_dirs": []
        \\    }}
        \\  }},
        \\  "compilations": [],
        \\  "top_level_steps": [],
        \\  "available_options": {{}}
        \\}}
    , .{ a_path, b_path, b_path });
    defer allocator.free(config_json);

    var fb = try helper_build.makeResolved(allocator, build_zig_path, config_json);
    defer fb.deinit();

    try helper_build.stampResolved(&ctx.server.document_store, a_handle, fb.build_file, a_path);

    _ = try ctx.server.document_store.uriFromImportStr(
        ctx.arena.allocator(),
        a_handle,
        "mod_b",
    );

    try std.testing.expect(a_handle.resolved_imports.count() > 0);

    // Trigger a re-parse via didChange. Handle pointer stays the same
    // (store uses stable pointers); tree and dependent state rebuild.
    _ = try ctx.server.sendNotificationSync(ctx.arena.allocator(), "textDocument/didChange", .{
        .textDocument = .{ .uri = a_uri.raw, .version = 2 },
        .contentChanges = &.{
            .{ .text_document_content_change_whole_document = .{ .text =
                \\const mod_b = @import("mod_b");
                \\
                \\pub fn entry(x: u32) u32 {
                \\    return mod_b.doubled(x) + 0;
                \\}
                \\
            } },
        },
    });

    try std.testing.expectEqual(@as(usize, 0), a_handle.resolved_imports.count());
}

test "findReferences across module-name import, build-system path (zls-mxw)" {
    // Phase 2 R2/R3 gap exposed by zls-pun demo:
    // `handle.file_imports` excludes module-name imports because `collectImports`
    // filters on `.zig` suffix (DocumentStore.zig:519). Both paths of
    // `gatherWorkspaceReferenceCandidates` iterate only `file_imports`, so a
    // caller importing `@import("mod_b")` is invisible to reverse reference
    // search.
    //
    // Fix: `resolved_imports` cache populated by `uriFromImportStr` and
    // unioned into the candidate walk.
    //
    // This test exercises the build-system path. The cursor is in a.zig on
    // `doubled` in the `mod_b.doubled(x)` call. LSP resolves to b.zig::doubled,
    // so `root_handle = a_handle` and `target_handle = b_handle`. Without the
    // fix, the walk starting at a.zig's module root (a_path) plus the target-
    // module-root addition (b_path) still wouldn't union a_handle's
    // resolved-import edges — if a.zig had other module imports beyond mod_b,
    // they'd be silently missed. The fix makes every module-import edge
    // visible to the walk.
    //
    // Fixture: a.zig does `@import("mod_b")`, calls `mod_b.doubled`. b.zig
    // defines `doubled`. findReferences from a.zig's call site must find
    // the call in a.zig (+ declaration in b.zig when includeDeclaration).

    const io = std.testing.io;

    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);

    const a_path = try std.Io.Dir.path.resolve(allocator, &.{ cwd, "tests/fixtures/module_imports/a.zig" });
    defer allocator.free(a_path);
    const b_path = try std.Io.Dir.path.resolve(allocator, &.{ cwd, "tests/fixtures/module_imports/b.zig" });
    defer allocator.free(b_path);
    const build_zig_path = try std.Io.Dir.path.resolve(allocator, &.{ cwd, "tests/fixtures/module_imports/build.zig" });
    defer allocator.free(build_zig_path);

    const a_uri: zls.Uri = try .fromPath(allocator, a_path);
    defer a_uri.deinit(allocator);
    const b_uri: zls.Uri = try .fromPath(allocator, b_path);
    defer b_uri.deinit(allocator);

    var ctx: Context = try .init();
    defer ctx.deinit();

    // Open both files. No eager-load edge between them: a.zig's only import is
    // "mod_b" (not .zig-suffixed), so `collectImports` skips it. Must didOpen
    // b.zig explicitly.
    _ = try ctx.server.sendNotificationSync(ctx.arena.allocator(), "textDocument/didOpen", .{
        .textDocument = .{
            .uri = b_uri.raw,
            .languageId = .{ .custom_value = "zig" },
            .version = 1,
            .text = @embedFile("../fixtures/module_imports/b.zig"),
        },
    });
    _ = try ctx.server.sendNotificationSync(ctx.arena.allocator(), "textDocument/didOpen", .{
        .textDocument = .{
            .uri = a_uri.raw,
            .languageId = .{ .custom_value = "zig" },
            .version = 1,
            .text = @embedFile("../fixtures/module_imports/a.zig"),
        },
    });

    const a_handle = ctx.server.document_store.getHandle(a_uri) orelse return error.AHandleMissing;
    const b_handle = ctx.server.document_store.getHandle(b_uri) orelse return error.BHandleMissing;

    // Build a fake resolved BuildConfig matching the fixture. mod_a imports mod_b.
    const config_json = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "dependencies": {{}},
        \\  "modules": {{
        \\    "{s}": {{
        \\      "import_table": {{
        \\        "mod_b": "{s}"
        \\      }},
        \\      "c_macros": [],
        \\      "include_dirs": []
        \\    }},
        \\    "{s}": {{
        \\      "import_table": {{}},
        \\      "c_macros": [],
        \\      "include_dirs": []
        \\    }}
        \\  }},
        \\  "compilations": [],
        \\  "top_level_steps": [],
        \\  "available_options": {{}}
        \\}}
    , .{ a_path, b_path, b_path });
    defer allocator.free(config_json);

    var fb = try helper_build.makeResolved(allocator, build_zig_path, config_json);
    defer fb.deinit();

    try helper_build.stampResolved(&ctx.server.document_store, a_handle, fb.build_file, a_path);
    try helper_build.stampResolved(&ctx.server.document_store, b_handle, fb.build_file, b_path);

    // Warm the resolved_imports cache. In real ZLS usage this happens
    // organically via hover / goto / analysis before the user asks
    // findReferences. Done explicitly here for deterministic cache state.
    const resolve_result = try ctx.server.document_store.uriFromImportStr(
        ctx.arena.allocator(),
        a_handle,
        "mod_b",
    );
    switch (resolve_result) {
        .one => {},
        else => return error.ModBDidNotResolve,
    }

    // Cursor on `doubled` in a.zig's `mod_b.doubled(x)` call.
    const a_source = @embedFile("../fixtures/module_imports/a.zig");
    const doubled_pos = offsets.indexToPosition(
        a_source,
        std.mem.indexOf(u8, a_source, "doubled").?,
        ctx.server.offset_encoding,
    );

    const response = try ctx.server.sendRequestSync(
        ctx.arena.allocator(),
        "textDocument/references",
        types.reference.Params{
            .textDocument = .{ .uri = a_uri.raw },
            .position = doubled_pos,
            .context = .{ .includeDeclaration = true },
        },
    );

    const locations: []const types.Location = response orelse {
        std.debug.print("Server returned `null` for findReferences\n", .{});
        return error.InvalidResponse;
    };

    var found_a = false;
    for (locations) |loc| {
        if (std.mem.eql(u8, loc.uri, a_uri.raw)) {
            found_a = true;
            break;
        }
    }
    try std.testing.expect(found_a);
}
