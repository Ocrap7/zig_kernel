const std = @import("std");
const uefi = @import("std").os.uefi;

const regs = @import("./registers.zig");
const SerialLogger = @import("./devices/devices.zig").serial.Logger;

/// UEFI logger for the `SimpleTextOutputProtocol`
pub const Logger = struct {
    console: *uefi.protocols.SimpleTextOutputProtocol,

    pub const Writer = std.io.Writer(@This(), uefi.Status.EfiError, write);

    pub fn writer(self: Logger) Writer {
        return .{ .context = self };
    }

    pub fn write(self: Logger, bytes: []const u8) uefi.Status.EfiError!usize {
        for (bytes) |value| {
            if (value == '\n')
                _ = try self.console.outputString(&[_:0]u16{'\r'}).err();
            _ = try self.console.outputString(&[_:0]u16{@as(u16, value)}).err();
        }
        return bytes.len;
    }
};

/// If set, the program is in the kernel binary
pub var KERNEL: bool = false;

/// This should be called once at the start of the kernel entry point
pub fn set_kernel() void {
    KERNEL = true;
}

/// Raw print; only print the formatted string
pub fn print(comptime format: []const u8, args: anytype) void {
    if (KERNEL) {
        const logger = SerialLogger{};
        logger.writer().print(format, args) catch {};
    } else {
        GLOBAL_LOGGER.writer().print(format, args) catch {};
        regs.cli();
    }
}

/// Log an info message. This will prepend the source file/line, and the word INFO in green, before the formatted string
pub fn info(comptime format: []const u8, args: anytype, src: std.builtin.SourceLocation) void {
    if (KERNEL) {
        const logger = SerialLogger{};

        logger.writer().print("\x1b[32;7m{s}:{}\x1b[0m \x1b[1;32mINFO: \x1b[0m", .{ src.file, src.line }) catch {};
        logger.writer().print(format, args) catch {};

        logger.writer().print("\n", .{}) catch {};
    } else if (uefi.system_table.con_out) |out| {
        const logger = Logger{ .console = out };

        _ = out.setAttribute(uefi.protocols.SimpleTextOutputProtocol.green);
        logger.writer().print("{s}:{} INFO:", .{ src.file, src.line }) catch {};

        _ = out.setAttribute(uefi.protocols.SimpleTextOutputProtocol.white);
        logger.writer().print(format, args) catch {};
        _ = out.outputString(&[_:0]u16{ '\r', '\n' });

        regs.cli();
    }
}

/// Log a warning message. This will prepend the source file/line, and the word WARN in yellow, before the formatted string
pub fn warn(comptime format: []const u8, args: anytype, src: std.builtin.SourceLocation) void {
    if (KERNEL) {
        const logger = SerialLogger{};

        logger.writer().print("\x1b[33;7m{s}:{}\x1b[0m \x1b[1;33mWARN: \x1b[0m", .{ src.file, src.line }) catch {};
        logger.writer().print(format, args) catch {};

        logger.writer().print("\n", .{}) catch {};
    } else if (uefi.system_table.con_out) |out| {
        const logger = Logger{ .console = out };

        _ = out.setAttribute(uefi.protocols.SimpleTextOutputProtocol.green);
        logger.writer().print("{s}:{}: ", .{ src.file, src.line }) catch {};

        _ = out.setAttribute(uefi.protocols.SimpleTextOutputProtocol.white);
        logger.writer().print(format, args) catch {};
        _ = out.outputString(&[_:0]u16{ '\r', '\n' });

        regs.cli();
    }
}

/// Create a kernel panic. This will prepend the source file/line, and the word PANIC in red, before the formatted string
/// This will halt the processor and/or spin forever
pub fn panic(comptime format: []const u8, args: anytype, src: std.builtin.SourceLocation) noreturn {
    if (KERNEL) {
        const logger = SerialLogger{};

        logger.writer().print("\x1b[31;7m{s}:{}\x1b[0m \x1b[1;31mPANIC: \x1b[0m", .{src.file, src.line}) catch {};
        logger.writer().print(format, args) catch {};

        logger.writer().print("\n", .{}) catch {};
    } else if (uefi.system_table.std_err) |err| {
        _ = err.setAttribute(uefi.protocols.SimpleTextOutputProtocol.red);

        const logger = Logger{ .console = err };
        logger.writer().print(format, args) catch {};
        _ = err.outputString(&[_:0]u16{ '\r', '\n' });

        logger.writer().print("\nexplicit panic: ", .{}) catch {};
        _ = err.setAttribute(uefi.protocols.SimpleTextOutputProtocol.white);

        logger.writer().print("{s}:{} @ {s}\n", .{ src.file, src.line, src.fn_name }) catch {};
    }

    asm volatile ("hlt");

    while (true) {}
}

var GLOBAL_LOGGER: Logger = undefined;

/// Init the uefi logger
pub fn init() void {
    GLOBAL_LOGGER = .{ .console = uefi.system_table.con_out.? };
}
