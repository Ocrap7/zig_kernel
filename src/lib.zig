pub const log = if (isKernel()) @import("./logger.zig") else struct {};
pub const devices = if (isKernel()) @import("./devices/devices.zig") else struct {};
pub const events = if (isKernel()) @import("./events.zig") else struct {};
pub const irq = if (isKernel()) @import("./irq.zig") else struct {};
pub const regs = @import("./registers.zig");

const root = @import("root");

fn isKernel() bool {
    comptime {
        return @hasDecl(root, "_kernel_export_lib");
    }
}

fn imported(comptime link_name: []const u8) *const fn () callconv(.C) void {
    comptime {
        return @extern(*const fn () callconv(.C) void, .{ .name = link_name });
    }
}

fn lib_func(comptime link_name: []const u8, comptime func: anytype) *const @TypeOf(func) {
    comptime {
        switch (@typeInfo(@TypeOf(func))) {
            .Fn => {
                if (isKernel()) {
                    @export(func, .{ .name = link_name });
                    return func;
                } else {
                    return @extern(*const @TypeOf(func), .{ .name = link_name });
                }
            },
            else => @compileError("Expected function type!"),
        }
    }
}

fn keepNamespace(comptime namespace: type) void {
    comptime {
        const std = @import("std");
        std.mem.doNotOptimizeAway(namespace);

        switch (@typeInfo(@TypeOf(namespace{}))) {
            .Struct => |strct| {
                for (strct.decls) |decl| {
                    std.mem.doNotOptimizeAway(@field(namespace, decl.name));
                }
            },
            else => @compileError("Expected struct!"),
        }
    }
}

pub const isr = struct {
    fn register_isr_impl(irq_pin: u16, handler: *const fn () bool) callconv(.C) u8 {
        return events.instance().register_listener(irq_pin, handler) catch log.panic("Unable to register isr", .{}, @src());
    }

    pub const register_isr = lib_func("isr.register_isr", register_isr_impl);
};

pub const name = struct {
    fn kernel_func_impl() callconv(.C) void {
        log.info("Called kernel_func", .{}, @src());
    }

    pub const kernel_func = lib_func("name.kernel_func", kernel_func_impl);
};

comptime {
    keepNamespace(name);
    keepNamespace(isr);
}
