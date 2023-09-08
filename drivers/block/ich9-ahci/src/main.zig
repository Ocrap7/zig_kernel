const driver = @import("driver");
const kernel = @import("kernel");
const std = @import("std");

comptime {
    _ = driver;
}

export fn main() void {
    kernel.name.kernel_func();
    while (true) {}
}
