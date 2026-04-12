const c = @import("c.zig");

pub fn process() u32 {
    return c.helper();
}
