const driver = @import("driver");
const kernel = @import("kernel");
const std = @import("std");

comptime {
    _ = driver;
}

fn handler() bool {
    kernel.name.kernel_func();
    _ = kernel.regs.in(0x60, u8);

    return true;
}

export fn main() void {
    _ = kernel.isr.register_isr(1, handler);

    while (true) {}
}

