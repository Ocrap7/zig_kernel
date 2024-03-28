const std = @import("std");
pub const os = @import("os.zig");

const config = @import("./config.zig");
const paging = @import("paging.zig");
const device_tree = @import("device_tree.zig");

const PL011 = @import("drivers/pl011.zig").PL011;

pub export const main_kernel_stack linksection(".bss") = [_]usize{0} ** (1024 * 1024);

export fn extern_kernel_main() callconv(.Naked) noreturn {
    asm volatile (
        \\b %[kernel_main]
        :
        : [kernel_main] "X" (&kernel_main_handle_error),
    );
}

pub const std_options = struct {
    pub const logFn = kernelLog;
};

pub fn kernelLog(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix2 = if (scope == .default) "\x1b[0m: " else "(" ++ @tagName(scope) ++ "): ";
    const level_txt = comptime switch (message_level) {
        .info => "INFO@",
        .warn => "WARN@",
        .err => "ERROR",
        .debug => "DEBUG",
    };
    const level_col = switch (message_level) {
        .info => "\x1b[1;32m",
        .warn => "\x1b[1;33m",
        .err => "\x1b[1;31m",
        .debug => "\x1b[1;35m",
    };

    const stderr = PL011.writer();
    stderr.print(level_col ++ level_txt ++ prefix2 ++ format ++ "\n", args) catch return;
}

fn kernel_main_handle_error() noreturn {
    kernel_main() catch |e| {
        var writer = PL011.writer();
        writer.print("Error in kernel_main {}", .{e}) catch undefined;
    };
    while (true) {}
}

extern const heap_base: opaque {};

fn kernel_main() !void {
    var reg = paging.MAIRegister{};
    reg.setNormal(0, .{}, .{});
    reg.setNormal(1, .{
        .read = true,
        .write = true,
        .write_back = true,
        .non_transient = true,
    }, .{
        .read = true,
        .write = true,
        .write_back = true,
        .non_transient = true,
    });
    reg.setDevice(2, .nGnRE);
    reg.setDevice(3, .nGnRE);
    reg.apply();

    os.heap.preInit(@intFromPtr(&heap_base), config.HEAP_MAP_SIZE);
    try paging.init();
    try os.heap.init(@intFromPtr(&heap_base));

    const dtree = device_tree.DeviceTree.init();

    std.log.info("Device Tree {}", .{device_tree.device_tree});
    std.log.info("Device Tree  bytes {*}", .{dtree.structs_table.ptr});

    const p = paging.PageTableEntry(.@"4K"){ .table = .{ .attrs = 0, .address = 0 } };

    std.log.info("{}", .{p.table});

    // var tok_it = dtree.iterator();
    // while (tok_it.next()) |tok| {
    //     switch (tok) {
    //         .begin_node => |nd| std.log.info("{s}", .{nd}),
    //         .property => |nd| std.log.info("    {s} {any}", .{ nd.name, nd.data[0..@min(nd.data.len, 10)] }),
    //         .end_node => std.log.info("", .{}),
    //         else => std.log.info("Token {}", .{tok}),
    //     }
    // }

    for (dtree.reserve_table) |ent| {
        std.log.info("Reserve: {x}-{x}", .{ ent.address, ent.size });
    }
    // for (dtree.structs_table) |b| {
    //     const val = std.mem.readIntBig(u32, @as(*const [4]u8, @ptrCast(&b)));
    //     std.log.info("Device Tree  bytes {x} {} {c}", .{
    //         val,
    //         if ((val > 0 and val <= 4) or val == 9) @as(device_tree.TokenKind, @enumFromInt(val)) else .nop,
    //         if (val <= 255) @as(u8, @truncate(val)) else 0,
    //     });
    // }
}
