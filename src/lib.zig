// These can only be imported if we are in the kernel so the code dosen't get inserted into drivers
const log = if (isKernel()) @import("./logger.zig") else struct {};
const devices = if (isKernel()) @import("./devices/devices.zig") else struct {};
const schedular = if (isKernel()) @import("./schedular.zig") else struct {};
const events = if (isKernel()) @import("./events.zig") else struct {};
const irq = if (isKernel()) @import("./irq.zig") else struct {};
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

/// Stop optimizing declerations within a namespace
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
    /// Importing this from ./irq.zig includes everything
    pub const ISRFrame = extern struct {
        rdi: u64,
        rsi: u64,
        rdx: u64,
        rcx: u64,
        rbx: u64,
        rax: u64,

        rbp: u64,

        vector: u64,
        error_code: u64,

        rip: u64,
        cs: u64,
        rflags: u64,
        rsp: u64,
        ss: u64,
    };

    fn register_isr_impl(irq_pin: u16, handler: *const fn (*ISRFrame) bool) callconv(.C) u8 {
        const proc = schedular.instance().current_process;

        return events.instance().register_listener(irq_pin, .{ .callback = @ptrCast(handler), .process = proc }) catch log.panic("Unable to register isr", .{}, @src());
    }

    /// Register an interrupt callback for irq specified by `irq_pin`.
    /// `handler` will be called when the interrupt is fired.
    /// 
    /// The handler function should return `true` if it was handled successfully and `false` if it is ignored.
    /// If the handler did handle the interrupt (returns `true`), no other handlers will get notified. 
    /// NOTE: This does not mean that the interrupt wasn't processed by a handler before this one
    pub const register_isr = lib_func("isr.register_isr", register_isr_impl);
};

pub const task = struct {
    fn yield_impl() callconv(.C) void {
        // TODO: set errors
        if (schedular.instance().current_process) |proc| {
            proc.data.context.status = .Yielded;
        }
    }

    /// Yield control to other tasks (this process will not be scheduled again).
    /// The task can still receive interrupts/events
    pub const yield = lib_func("task.yield", yield_impl);
};

pub const name = struct {
    fn kernel_func_impl(value: [*]const u8, len: usize) callconv(.C) void {
        log.info("Called kernel_func {s}", .{value[0..len]}, @src());
    }

    pub const kernel_func = lib_func("name.kernel_func", kernel_func_impl);
};

comptime {
    keepNamespace(name);
    keepNamespace(isr);
    keepNamespace(task);
}
