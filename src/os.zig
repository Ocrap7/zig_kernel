const std = @import("std");
const PL011 = @import("drivers/pl011.zig").PL011;

pub const heap = @import("heap.zig");

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = error_return_trace;
    _ = ret_addr;

    const stderr = PL011.writer();
    stderr.print("\x1b[1;31mPANIC\x1b[0m: ({s}:{}): {s} \n", .{ @src().file, @src().line, msg }) catch unreachable;

    // _ = debug_info;

    asm volatile ("brk 0");

    while (true) {}
}
