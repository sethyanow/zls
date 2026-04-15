//! Test helper for tests that need ZLS's build-system code paths to behave as
//! if `build.zig` had already been executed by the custom build runner.
//!
//! Extends the `.unresolved` BuildFile scaffolding pattern at
//! `tests/lsp_features/references.zig:1119-1142` to the `.resolved` case, by
//! populating `BuildFile.impl.config` with a `std.json.Parsed(BuildConfig)`
//! constructed from an inline JSON string.
//!
//! Reusable across tests — module-import reverse reference (zls-mxw),
//! findReferences on `@import` string literals (zls-029), and any future
//! feature that relies on `uriFromImportStr` hitting the build-config path.
//!
//! Usage:
//! ```zig
//! var fb = try helper_build.makeResolved(allocator, build_zig_path, json);
//! defer fb.deinit();
//!
//! try helper_build.stampResolved(store, a_handle, fb.build_file, a_root_path);
//! try helper_build.stampResolved(store, b_handle, fb.build_file, b_root_path);
//! ```

const std = @import("std");
const zls = @import("zls");

const DocumentStore = zls.DocumentStore;
const Uri = zls.Uri;

/// A fake resolved BuildFile. Owns the heap-allocated `BuildFile` and its
/// `impl.config` arena. Call `deinit` after all handles stamped at `.resolved`
/// referencing this BuildFile have been freed (i.e. after `ctx.deinit()`).
pub const FakeBuild = struct {
    build_file: *DocumentStore.BuildFile,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *FakeBuild) void {
        if (self.build_file.impl.config) |*cfg| cfg.deinit();
        self.build_file.uri.deinit(self.allocator);
        self.allocator.destroy(self.build_file);
        self.* = undefined;
    }
};

/// Parse `config_json` into a `BuildConfig` and attach it to a fresh heap-allocated
/// BuildFile. `build_zig_path` is the filesystem path of the fake build.zig — need
/// not exist on disk (the build runner is never invoked).
///
/// The returned `FakeBuild` owns both the BuildFile and the parsed arena.
pub fn makeResolved(
    allocator: std.mem.Allocator,
    build_zig_path: []const u8,
    config_json: []const u8,
) !FakeBuild {
    var parsed = try std.json.parseFromSlice(
        DocumentStore.BuildConfig,
        allocator,
        config_json,
        .{},
    );
    errdefer parsed.deinit();

    const build_file = try allocator.create(DocumentStore.BuildFile);
    errdefer allocator.destroy(build_file);

    build_file.* = .{
        .uri = try Uri.fromPath(allocator, build_zig_path),
        .impl = .{ .config = parsed },
    };

    return .{ .build_file = build_file, .allocator = allocator };
}

/// Stamp a handle's `associated_build_file` to `.resolved`, pointing at the given
/// fake BuildFile. `root_source_file` must be a key in
/// `build_file.impl.config.?.value.modules.map` — `uriFromImportStr` uses it to
/// look up the module's `import_table`.
///
/// The `root_source_file` string is duped with `store.allocator` because the
/// state's internal deinit frees it from there when the handle is destroyed.
///
/// Precondition: the handle must not have already transitioned to `.unresolved`
/// or `.resolved` state — that would leak its prior owned allocations. Safe for
/// freshly-loaded handles where the state is still `.init`. In practice this
/// means calling `stampResolved` immediately after `didOpen` / `addDocument`,
/// before any analysis pass has touched the handle's associated build file.
pub fn stampResolved(
    store: *DocumentStore,
    handle: *DocumentStore.Handle,
    build_file: *DocumentStore.BuildFile,
    root_source_file: []const u8,
) !void {
    handle.impl.associated_build_file = .{ .resolved = .{
        .build_file = build_file,
        .root_source_file = try store.allocator.dupe(u8, root_source_file),
    } };
}
