//! Fixture build.zig for module-import reverse reference tests (zls-mxw).
//!
//! This file is not executed by the test suite. The BuildConfig is constructed
//! directly from JSON via `tests/helper_build.zig`. The shape here mirrors what
//! the custom build runner would have produced, so anyone inspecting the fixture
//! can see the scenario:
//!
//!   - `mod_a` (root `a.zig`) imports `mod_b` by module name
//!   - `mod_b` (root `b.zig`) declares the target symbol
//!
//! Cross-file references from `b.zig` to `a.zig` require walking the module-
//! import edge, which is what `resolved_imports` makes visible.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod_b = b.addModule("mod_b", .{
        .root_source_file = b.path("b.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod_a = b.addModule("mod_a", .{
        .root_source_file = b.path("a.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod_a.addImport("mod_b", mod_b);
}
