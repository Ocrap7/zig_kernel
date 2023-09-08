pub const log = @import("./logger.zig");
pub const devices = @import("./devices/devices.zig");
const root = @import("root");

inline fn isKernel() bool {
    return @hasDecl(root, "_kernel_export_lib");
}

fn imported(comptime link_name: []const u8) *const fn () callconv(.C) void {
    return @extern(*const fn () callconv(.C) void, .{ .name = link_name });
}

pub const name = switch (isKernel()) {
    true => struct {
        // Put driver bridge functions here

        pub fn kernel_func() callconv(.C) void {
            log.info("Called kernel_func", .{}, @src());
        }
    },
    false => struct {
        // Put driver bridge interface here

        pub const kernel_func = imported("name.kernel_func");
    },
};


comptime {
    if (@hasDecl(root, "_kernel_export_lib")) {
        @export(name.kernel_func, .{ .name = "name.kernel_func" });
    }
}
