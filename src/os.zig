const std = @import("std");
const log = @import("./logger.zig");

pub const heap = struct {
    const allocator = @import("./allocator.zig");
    pub const page_allocator = allocator.kernel_page_allocator;
};

pub const system = struct {};

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    log.panic("PANIC: {s} {?} {?}", .{msg, error_return_trace, ret_addr}, @src());
}
