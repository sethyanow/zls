const b = @import("b.zig");
const c = @import("c.zig");

pub fn run() u32 {
    return b.process() + c.transform();
}
