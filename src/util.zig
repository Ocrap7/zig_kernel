
pub fn kb(comptime value: anytype) @TypeOf(value) {
    return value * 1024;
}

pub fn mb(comptime value: anytype) @TypeOf(value) {
    return value * 1024 * 1024;
}

pub fn gb(comptime value: anytype) @TypeOf(value) {
    return value * 1024 * 1024 * 1024;
}

pub fn tb(comptime value: anytype) @TypeOf(value) {
    return value * 1024 * 1024 * 1024 * 1024;
}
