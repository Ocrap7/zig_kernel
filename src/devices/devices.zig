pub const serial = @import("./serial.zig");

pub fn init_default() void {
    serial.init();
}
