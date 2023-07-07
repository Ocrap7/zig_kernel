const std = @import("std");
const uefi = @import("std").os.uefi;
const unistd = @cImport(@cInclude("drm/amdgpu_drm.h"));
const paging = @import("./paging.zig");

pub const Logger = struct {
    output_protocol: *uefi.protocols.SimpleTextOutputProtocol,

    pub const Writer = std.io.Writer(@This(), uefi.Status.EfiError, write);

    pub fn writer(file: *uefi.protocols.SimpleTextOutputProtocol) Writer {
        return .{ .context = .{ .output_protocol = file } };
    }

    pub fn write(self: Logger, bytes: []const u8) uefi.Status.EfiError!usize {
        for (bytes) |value| {
            _ = try self.output_protocol.outputString(&[_:0]u16{@as(u16, value)}).err();
        }
        return bytes.len;
    }
};

const Str = union {
    small: []const u8,
    wide: []const u16,
};

const Test = struct {
    a: u32,
};

pub fn main() uefi.Status {
    paging.getPageTable();
    // uefi.system_table.con_out is a pointer to a structure that implements
    // uefi.protocols.SimpleTextOutputProtocol that is associated with the
    // active console output device.
    const con_out = uefi.system_table.con_out.?;

    const logger = Logger.writer(con_out);
    // const logger = Logger{ .output_protocol = con_out };

    // Clear screen. reset() returns usize(0) on success, like most
    // EFI functions. reset() can also return something else in case a
    // device error occurs, but we're going to ignore this possibility now.
    _ = con_out.reset(false);
    // const std = @import("std");
    // std.debug.print(comptime fmt: []const u8, args: anytype);

    // EFI uses UCS-2 encoded null-terminated strings. UCS-2 encodes
    // code points in exactly 16 bit. Unlike UTF-16, it does not support all
    // Unicode code points.
    // _ = logger.output_protocol.outputString(&[_:0]u16{ 'H', 'e', 'l', 'l', 'o', ',', ' ' });
    // _ = logger.output_protocol.outputString(&[_:0]u16{ 'w', 'o', 'r', 'l', 'd', '\r', '\n' });

    // const p: []const u16 = @as([] const u16, "sdfsd");
    // const str = Str{.small = "poo"};
    const t = Test{.a = 5};
    _ = logger.print("fkls {}", .{t}) catch {};

    // EFI uses \r\n for line breaks (like Windows).


    // Boot services are EFI facilities that are only available during OS
    // initialization, i.e. before your OS takes over full control over the
    // hardware. Among these are functions to configure events, allocate
    // memory, load other EFI images, and access EFI protocols.
    const boot_services = uefi.system_table.boot_services.?;
    // There are also Runtime services which are available during normal
    // OS operation.

    // uefi.system_table.con_out and uefi.system_table.boot_services should be
    // set to null after you're done initializing everything. Until then, we
    // don't need to worry about them being inaccessible.

    // Wait 5 seconds.
    _ = boot_services.stall(5 * 1000 * 1000);

    return .Success;
}
