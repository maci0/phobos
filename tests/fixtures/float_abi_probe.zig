extern "c" fn probe_value(index: c_int) f64;
extern "c" fn probe_add(a: f64, b: f64) f64;
extern "c" fn probe_check() c_int;

export fn probe_zig_value_bits(index: c_int) callconv(.c) u64 {
    return @bitCast(probe_value(index));
}

export fn probe_zig_add_bits(a: u64, b: u64) callconv(.c) u64 {
    return @bitCast(probe_add(@bitCast(a), @bitCast(b)));
}

pub fn main() u8 {
    return @intCast(probe_check());
}
