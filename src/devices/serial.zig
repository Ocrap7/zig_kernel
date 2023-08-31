const std = @import("std");

const log = @import("../logger.zig");
const regs = @import("../registers.zig");

const PORT: u16 = 0x3F8;

/// Initialize the serial port. Values are pulled from OSDEV as they don't really matter for now
pub fn init() void {
    regs.out(PORT + 1, @as(u8, 0x00));
    regs.out(PORT + 3, @as(u8, 0x80));
    regs.out(PORT, @as(u8, 0x03));
    regs.out(PORT + 1, @as(u8, 0x00));
    regs.out(PORT + 3, @as(u8, 0x03));
    regs.out(PORT + 2, @as(u8, 0xC7));
    regs.out(PORT + 4, @as(u8, 0x0B));
    regs.out(PORT + 4, @as(u8, 0x1E));
    regs.out(PORT, @as(u8, 0xAE));

    if (regs.in(PORT, u8) != 0xAE) {
        log.panic("Faulty serial port", .{}, @src());
    }

    regs.out(PORT + 4, @as(u8, 0x07));
}

pub fn read() u8 {
    while (regs.in(PORT + 5, u8) & 1 == 0) {}

    return regs.in(PORT, u8);
}

pub fn write(c: u8) void {
    while (regs.in(PORT + 5, u8) & 0x20 == 0) {}

    regs.out(PORT, c);
}

const SerialError = error{};

/// Serial logger so we can easily write to the port
pub const Logger = struct {
    pub const Writer = std.io.Writer(@This(), SerialError, write_str);

    pub fn writer(self: Logger) Writer {
        return .{ .context = self };
    }

    pub fn write_str(self: Logger, bytes: []const u8) SerialError!usize {
        _ = self;
        for (bytes) |value| {
            write(value);
        }
        return bytes.len;
    }
};
