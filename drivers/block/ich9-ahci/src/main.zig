const driver = @import("driver");
const kernel = @import("kernel");
const std = @import("std");

comptime {
    _ = driver;
}

export fn main() void {
    const v = "ahci";

    while (true) {
        kernel.name.kernel_func(v.ptr, v.len);
    }
}
