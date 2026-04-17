const std = @import("std");
const zls = @import("zls");

const Context = @import("../context.zig").Context;

const types = zls.lsp.types;

const allocator: std.mem.Allocator = std.testing.allocator;

test "workspace symbols - empty query returns all declarations sorted alphabetically" {
    var ctx: Context = try .init();
    defer ctx.deinit();

    try ctx.addWorkspace("Animal Shelter", "/animal_shelter/");

    _ = try ctx.addDocument(.{ .source =
        \\const SalamanderCrab = struct {
        \\    fn salamander_crab() void {}
        \\};
    , .base_directory = "/animal_shelter/" });

    _ = try ctx.addDocument(.{ .source =
        \\const Dog = struct {
        \\    const sheltie: Dog = .{};
        \\    var @"Mr Crabs" = @compileError("hold up");
        \\};
        \\test "walk the dog" {
        \\    const dog: Dog = .sheltie;
        \\    _ = dog; // nah
        \\}
    , .base_directory = "/animal_shelter/" });

    _ = try ctx.addDocument(.{ .source =
        \\const Lion = struct {
        \\    extern fn evolveToMonke() void;
        \\    fn roar() void {
        \\        var lion = "cool!";
        \\        const Lion2 = struct {
        \\            const lion_for_real = 0;
        \\        };
        \\    }
        \\};
    , .base_directory = "/animal_shelter/" });

    try testDocumentSymbol(&ctx, "",
        \\Variable @"Mr Crabs"
        \\Constant Dog
        \\Constant Lion
        \\Constant SalamanderCrab
        \\Function evolveToMonke
        \\Constant lion_for_real
        \\Function roar
        \\Function salamander_crab
        \\Constant sheltie
        \\Method walk the dog
    );
}

test "workspace symbols - empty query with no documents returns empty result" {
    var ctx: Context = try .init();
    defer ctx.deinit();

    try ctx.addWorkspace("Empty Project", "/empty_project/");

    try testDocumentSymbol(&ctx, "", "");
}

test "workspace symbols - empty query with single declaration" {
    var ctx: Context = try .init();
    defer ctx.deinit();

    try ctx.addWorkspace("Solo", "/solo/");

    _ = try ctx.addDocument(.{ .source =
        \\const OnlyOne = struct {};
    , .base_directory = "/solo/" });

    try testDocumentSymbol(&ctx, "",
        \\Constant OnlyOne
    );
}

test "workspace symbols - empty query with duplicate names across files" {
    var ctx: Context = try .init();
    defer ctx.deinit();

    try ctx.addWorkspace("Dupes", "/dupes/");

    _ = try ctx.addDocument(.{ .source =
        \\const Config = struct {};
        \\fn init() void {}
    , .base_directory = "/dupes/" });

    _ = try ctx.addDocument(.{ .source =
        \\const Config = struct {};
        \\fn setup() void {}
    , .base_directory = "/dupes/" });

    // Both Config entries should appear — duplicates are preserved, sorted alphabetically.
    // With identical names, sort is deterministic (stable within equal keys).
    try testDocumentSymbol(&ctx, "",
        \\Constant Config
        \\Constant Config
        \\Function init
        \\Function setup
    );
}

test "workspace symbols" {
    var ctx: Context = try .init();
    defer ctx.deinit();

    try ctx.addWorkspace("Animal Shelter", "/animal_shelter/");

    _ = try ctx.addDocument(.{ .source =
        \\const SalamanderCrab = struct {
        \\    fn salamander_crab() void {}
        \\};
    , .base_directory = "/animal_shelter/" });

    _ = try ctx.addDocument(.{ .source =
        \\const Dog = struct {
        \\    const sheltie: Dog = .{};
        \\    var @"Mr Crabs" = @compileError("hold up");
        \\};
        \\test "walk the dog" {
        \\    const dog: Dog = .sheltie;
        \\    _ = dog; // nah
        \\}
    , .base_directory = "/animal_shelter/" });

    _ = try ctx.addDocument(.{ .source =
        \\const Lion = struct {
        \\    extern fn evolveToMonke() void;
        \\    fn roar() void {
        \\        var lion = "cool!";
        \\        const Lion2 = struct {
        \\            const lion_for_real = 0;
        \\        };
        \\    }
        \\};
    , .base_directory = "/animal_shelter/" });

    _ = try ctx.addDocument(.{ .source =
        \\const PotatoDoctor = struct {};
    , .base_directory = "/farm/" });

    try testDocumentSymbol(&ctx, "Sal",
        \\Constant SalamanderCrab
        \\Function salamander_crab
    );
    try testDocumentSymbol(&ctx, "_cr___a_b_",
        \\Constant SalamanderCrab
        \\Function salamander_crab
        \\Variable @"Mr Crabs"
    );
    try testDocumentSymbol(&ctx, "dog",
        \\Constant Dog
        \\Method walk the dog
    );
    try testDocumentSymbol(&ctx, "potato_d", "");
    // Becomes S\x00\x00 which matches nothing
    try testDocumentSymbol(&ctx, "S", "");
    try testDocumentSymbol(&ctx, "lion",
        \\Constant Lion
        \\Constant lion_for_real
    );
    try testDocumentSymbol(&ctx, "monke",
        \\Function evolveToMonke
    );
}

fn testDocumentSymbol(ctx: *Context, query: []const u8, expected: []const u8) !void {
    const response = try ctx.server.sendRequestSync(
        ctx.arena.allocator(),
        "workspace/symbol",
        .{ .query = query },
    ) orelse {
        std.debug.print("Server returned `null` as the result\n", .{});
        return error.InvalidResponse;
    };

    var actual: std.ArrayList(u8) = .empty;
    defer actual.deinit(allocator);

    for (response.workspace_symbols) |workspace_symbol| {
        std.debug.assert(workspace_symbol.tags == null); // unsupported for now
        std.debug.assert(workspace_symbol.containerName == null); // unsupported for now
        try actual.print(allocator, "{t} {s}\n", .{
            workspace_symbol.kind,
            workspace_symbol.name,
        });
    }

    if (actual.items.len != 0) {
        _ = actual.pop(); // Final \n
    }

    try zls.testing.expectEqualStrings(expected, actual.items);
}
