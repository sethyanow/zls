const mod_b = @import("mod_b");

pub fn entry(x: u32) u32 {
    return mod_b.doubled(x);
}
