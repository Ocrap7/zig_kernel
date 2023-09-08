const std = @import("std");

const log = @import("./logger.zig");
const alloc = @import("./allocator.zig");
const paging = @import("./paging.zig");
const config = @import("./config.zig");
const allocate = @import("./allocator.zig");

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

    address_space: *paging.PageTable,
    heap_base: u64,
    context: Context,

    pub fn load_driver(elf_code: []const u8) !Task {
        var code_buffer = std.io.FixedBufferStream([]const u8){ .buffer = elf_code, .pos = 0 };

        var allocator = std.heap.ArenaAllocator.init(allocate.virtual_page_allocator);

        const address_space: *paging.PageTable = &(try allocator.allocator().alignedAlloc(paging.PageTable, 4096, 1))[0];

        const physAddr = switch (paging.translateToPhysical(@intFromPtr(address_space))) {
            .success => |addr| addr,
            else => log.panic("Unable to translate physical address", .{}, @src()),
        };
        log.info("Allocated task address space: 0x{x} -> 0x{x} {}", .{ @intFromPtr(address_space), physAddr, @alignOf(paging.PageTable) }, @src());

        address_space.* = .{};

        address_space.setRecursiveEntryOn();
        paging.remapKernel(paging.getPageTable(), address_space);
        paging.PageTable.loadPhysical(physAddr);

        const headers = try std.elf.Header.read(&code_buffer);
        var iter = headers.program_header_iterator(&code_buffer);

        while (try iter.next()) |header| {
            switch (header.p_type) {
                std.elf.PT_LOAD => {
                    const flag_write = header.p_flags & std.elf.PF_W > 0;
                    _ = flag_write;

                    // `memory` points to the kernel's heap
                    // we then get the physical address that this maps to and map the code address to it
                    // TODO: find a way to not use the kernel's address
                    const memory = try allocator.allocator().alignedAlloc(u8, 4096, header.p_memsz);
                    const phys = switch (paging.translateToPhysical(@intFromPtr(memory.ptr))) {
                        .success => |addr| addr,
                        else => return error.TranslationError,
                    };
                    log.info("Map {x} {x}", .{ header.p_vaddr, @intFromPtr(memory.ptr) }, @src());

                    _ = try paging.mapPages(phys, @as(u64, header.p_vaddr), header.p_memsz / 4097 + 1, .{ .writable = true });

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

        const kernel_page_count: usize = config.PROCESS_STACK_LENGTH / 4096;

        for (0..kernel_page_count) |page| {
            const addr = alloc.physical_page_allocator.rawAlloc(4096, 12, @returnAddress()) orelse {
                log.panic("Unable to allocate process stack", .{}, @src());
            };

            switch (paging.mapPage(@intFromPtr(addr), config.PROCESS_STACK_START - (page) * 4096, .{ .writable = true })) {
                .success => |_| {},
                else => |err| {
                    log.panic("Error mapping process stack: {}", .{err}, @src());
                },
            }
        }

        return .{ .address_space = address_space, .allocator = allocator, .entry = @ptrFromInt(headers.entry), .heap_base = config.PROCESS_HEAP_START, .context = .{ .rsp = config.PROCESS_STACK_START, .rflags = 0x200 } };
    }

    pub fn deinit(self: Task) void {
        self.allocator.deinit();
    }
};
