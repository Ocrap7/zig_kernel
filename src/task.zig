const std = @import("std");

const log = @import("./logger.zig");
const paging = @import("./paging.zig");

pub const Context = struct {
    rax: u64 = 0,
    rbx: u64 = 0,
    rcx: u64 = 0,
    rdx: u64 = 0,

    rsi: u64 = 0,
    rdi: u64 = 0,

    rsp: u64,
    rbp: u64 = 0,

    rflags: u64,

    r8: u64 = 0,
    r9: u64 = 0,
    r10: u64 = 0,
    r11: u64 = 0,
    r12: u64 = 0,
    r13: u64 = 0,
    r14: u64 = 0,
    r15: u64 = 0,
};

pub const Task = struct {
    allocator: std.heap.ArenaAllocator,
    entry: *const fn () void,

    pub fn load_driver(elf_code: []const u8) !Task {
        var code_buffer = std.io.FixedBufferStream([]const u8){ .buffer = elf_code, .pos = 0 };

        var allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);

        const headers = try std.elf.Header.read(&code_buffer);
        var iter = headers.program_header_iterator(&code_buffer);

        while (try iter.next()) |header| {
            switch (header.p_type) {
                std.elf.PT_LOAD => {
                    const flag_write = header.p_flags & std.elf.PF_W > 0;

                    const memory = try allocator.allocator().alloc(u8, header.p_memsz);

                    switch (paging.mapPages(@intFromPtr(memory.ptr), @as(u64, header.p_vaddr), header.p_memsz / 4097 + 1, .{ .writable = flag_write })) {
                        .success => {},
                        else => |err| log.panic("Poop {}", .{err}, @src()),
                    }

                    const mem: [*]u8 = @ptrFromInt(header.p_vaddr);
                    const mem_slice = mem[0..header.p_memsz];

                    if (header.p_filesz == header.p_memsz) {
                        @memcpy(mem_slice, elf_code[header.p_offset .. header.p_offset + header.p_filesz]);
                    } else {
                        @memset(mem_slice, 0);
                    }
                },
                else => {},
            }
        }

        return .{ .allocator = allocator, .entry = @ptrFromInt(headers.entry) };
    }

    pub fn deinit(self: Task) void {
        self.allocator.deinit();
    }
};
