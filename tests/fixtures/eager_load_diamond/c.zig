const d = @import("d.zig");

pub fn transform() u32 {
    return d.shared() + 1;
}
