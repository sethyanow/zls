// zls-029 R-I2 fixture: references b.zig by file path rather than by
// module name (as a.zig does via "mod_b"). Both imports resolve to the
// same URI, exercising the URI-comparison semantic in findReferences on
// @import string literals.
const b = @import("b.zig");

pub fn wrap(x: u32) u32 {
    return b.doubled(x);
}
