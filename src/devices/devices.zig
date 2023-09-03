const std = @import("std");
pub const serial = @import("./serial.zig");


pub fn init_default() void {
    serial.init();

    // std.heap.page_allocator
    // const v = std.AutoHashMap(u8, IRQHandler).init();
}
