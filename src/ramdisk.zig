//! RD File Format:
//! bytes-range:
//! 0-7: Number of files
//! n-n+7: file length
//! n+8-n+8+len: File data

const std = @import("std");

pub const Entry = extern struct {
    offset: u64,
    len: u64,
    _name: [16]u8,

    fn asBytes(self: *const Entry) []const u8 {
        const self_ptr: [*]const u8 = @ptrCast(self);

        return self_ptr[0..@sizeOf(Entry)];
    }

    fn calc_name_len(self: *const Entry) usize {
        var name_len: usize = 0;
        while (name_len < 16 and self._name[name_len] != 0) : (name_len += 1) {}

        return name_len;
    }

    fn name(self: *const Entry) []const u8 {
        const name_len = self.calc_name_len();

        return self._name[0..name_len];
    }
};

pub const File = struct {
    name: []const u8,
    data: []const u8,
};

comptime {
    std.debug.assert(@sizeOf(Entry) == 32);
    std.debug.assert(@sizeOf(RamDisk) == 40);
}

pub const RamDisk = extern struct {
    file_count: u64,
    entry: Entry,

    pub fn entries(self: *const RamDisk) []const Entry {
        const ptr: [*]const Entry = @ptrCast(&self.entry);
        return ptr[0..self.file_count];
    }

    pub fn fileStart(self: *const RamDisk) [*]const u8 {
        const ptr: [*]const Entry = @ptrCast(&self.entry);
        const u8_ptr: [*]const u8 = @ptrCast(&ptr[self.file_count + 1]);

        return u8_ptr;
    }

    pub fn searchFile(self: *const RamDisk, name: []const u8) ?File {
        for (self.entries()) |entry| {
            if (std.mem.eql(u8, entry.name(), name)) {
                return self.getFile(&entry);
            }
        }

        return null;
    }

    pub fn getFile(self: *const RamDisk, entry: *const Entry) File {
        const u8_ptr: [*]const u8 = @ptrCast(self);
        const name_len = entry.calc_name_len();

        return .{
            .name = entry._name[0..name_len],
            .data = u8_ptr[entry.offset .. entry.offset + entry.len],
        };
    }

    pub fn fromBuffer(buffer: []align(@alignOf(RamDisk)) const u8) *const RamDisk {
        return @ptrCast(buffer.ptr);
    }

    const Buffer = std.ArrayListAligned(u8, @alignOf(RamDisk));

    pub fn createFromFiles(files: []const File, allocator: std.mem.Allocator) !Buffer {
        const file_count = files.len;
        _ = file_count;
        var buffer = try Buffer.initCapacity(allocator, files.len * 1024 + 8 + @sizeOf(Entry) * files.len);
        try buffer.appendNTimes(0, 8); // Reserve file count

        std.mem.writeIntSliceLittle(u64, buffer.items[0..8], @as(u64, files.len)); // Write file count

        var offset = buffer.items.len + files.len * @sizeOf(Entry);

        for (files) |file| {
            if (file.name.len > 16) {
                @panic("File name length should be 16 or less!");
            }
            var entry = Entry{ .len = file.data.len, .offset = offset, ._name = [_]u8{0} ** 16 };
            @memcpy(entry._name[0..file.name.len], file.name);

            try buffer.appendSlice(entry.asBytes());

            offset += file.data.len;
        }

        for (files) |file| {
            try buffer.appendSlice(file.data);
        }

        return buffer;
    }
};

test "entries slice" {
    var allocator = std.heap.GeneralPurposeAllocator(.{}){};

    const file_data = [_]u8{ 69, 55, 99 };
    const file2_data = [_]u8{ 89, 23, 45, 45, 12 };

    const file = File{
        .name = "file",
        .data = &file_data,
    };
    const file2 = File{
        .name = "thisismaxnamelen",
        .data = &file2_data,
    };

    const buffer = try RamDisk.createFromFiles(&[_]File{ file, file2 }, allocator.allocator());
    const rd = RamDisk.fromBuffer(buffer.items);

    const entries = rd.entries();
    try std.testing.expectEqual(@as(u64, 2), rd.file_count);
    try std.testing.expectEqual(.{ .len = 3, .offset = 40 }, entries[0]);
    try std.testing.expectEqual(.{ .len = 5, .offset = 43 }, entries[1]);

    const rfile = rd.getFile(&entries[0]);
    try std.testing.expectEqual(@as(usize, 4), rfile.name.len);
    try std.testing.expectEqual(@as(usize, 3), rfile.data.len);
    try std.testing.expectEqual(@as(u8, 69), rfile.data[0]);
    try std.testing.expectEqual(@as(u8, 55), rfile.data[1]);
    try std.testing.expectEqual(@as(u8, 99), rfile.data[2]);

    const rfile2 = rd.getFile(&entries[1]);
    try std.testing.expectEqual(@as(usize, 16), rfile2.name.len);
    try std.testing.expectEqual(@as(usize, 5), rfile2.data.len);
    try std.testing.expectEqual(@as(u8, 89), rfile2.data[0]);
    try std.testing.expectEqual(@as(u8, 23), rfile2.data[1]);
    try std.testing.expectEqual(@as(u8, 45), rfile2.data[2]);
    try std.testing.expectEqual(@as(u8, 45), rfile2.data[3]);
    try std.testing.expectEqual(@as(u8, 12), rfile2.data[4]);
}
