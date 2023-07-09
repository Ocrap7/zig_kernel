const std = @import("std");
const uefi = @import("std").os.uefi;

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

var GLOBAL_LOGGER: ?Logger = null;

pub fn setLogger(logger: Logger) void {
    GLOBAL_LOGGER = logger;
}

pub fn getLogger() *?Logger {
    // var log = GLOBAL_LOGGER;

    // return log;
    return &GLOBAL_LOGGER;
}
