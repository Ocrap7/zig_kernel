const std = @import("std");
const root = @import("root");
const kernel = @import("kernel");
const testing = std.testing;

extern fn main() void;

comptime {
    _ = root;
}

export fn driver_main_stub() void {
    main();
}
