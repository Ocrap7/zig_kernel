const driver = @import("driver");
const kernel = @import("kernel");
const std = @import("std");

comptime {
    _ = driver;
}

fn handler(frame: *kernel.isr.ISRFrame) bool {
    _ = frame;
    _ = kernel.regs.in(0x60, u8);

    return true;
}

export fn main() void {
    _ = kernel.isr.register_isr(1, handler);
    const v = "ps2";
    // kernel.task.yield();

    while (true) {
        kernel.name.kernel_func(v.ptr, v.len);
    }
}
