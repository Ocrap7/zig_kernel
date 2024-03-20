const std = @import("std");
pub const os = @import("os.zig");

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
    kernel_main() catch {
        const pl = PL011{};
        _ = pl.writeFn("Error in kernel_main") catch {};
    };
    while (true) {}
}

fn kernel_main() !void {
    std.log.info("Hello", .{});
    std.log.debug("Hello", .{});
    std.log.warn("Hello", .{});
    std.log.err("Hello", .{});
    @panic("Uhoh");
}
