const std = @import("std");

const log = @import("./logger.zig");
const irq = @import("./irq.zig");
const alloc = @import("./allocator.zig");
const paging = @import("./paging.zig");
const config = @import("./config.zig");
const allocate = @import("./allocator.zig");

/// The saved cpu state of a task (registers)
pub const CPUState = struct {
    rax: u64 = 0,
    rbx: u64 = 0,
    rcx: u64 = 0,
    rdx: u64 = 0,

    rsi: u64 = 0,
    rdi: u64 = 0,

    rsp: u64,
    rbp: u64 = 0,

    rip: u64,

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

/// State of the task
pub const Status = enum {
    /// The process has been scheduled previously and is executing normally
    Running,
    /// The process has been added to the task list and will be scheduled next time it is encountered
    Ready,
    /// The process is waiting for some event
    Blocked,
    /// The process has explicitly yielded
    Yielded,
};

/// The overall state of the task
pub const Context = struct {
    cpu_state: CPUState,
    status: Status,

    address_space: *paging.PageTable,
    heap_base: u64,
};

var next_id: usize = 0;

/// This struct represents a task or process
pub const Task = struct {
    /// Unique id of the process
    id: usize,
    /// Allocator (kernel allocator)
    allocator: std.heap.ArenaAllocator,
    /// ENtry point of the process (TODO: this probably isn't needed)
    entry: *const fn () void,
    /// Saved context
    context: Context,

    /// Copy registers from `frame` into the context of `self`
    pub fn saveCPUFromFrame(self: *Task, frame: *const irq.ISRFrame) void {
        self.context.cpu_state = .{
            .rax = frame.rax,
            .rbx = frame.rbx,
            .rcx = frame.rcx,
            .rdx = frame.rdx,

            .rsi = frame.rsi,
            .rdi = frame.rdi,

            .rsp = frame.rsp,
            .rbp = frame.rbp,

            .rip = frame.rip,

            .rflags = frame.rflags,
        };
    }

    /// Load the registers from the context of `self` into `frame`
    pub fn loadCPUIntoFrame(self: *Task, frame: *irq.ISRFrame) void {
        frame.rax = self.context.cpu_state.rax;
        frame.rbx = self.context.cpu_state.rbx;
        frame.rcx = self.context.cpu_state.rcx;
        frame.rdx = self.context.cpu_state.rdx;

        frame.rsi = self.context.cpu_state.rsi;
        frame.rdi = self.context.cpu_state.rdi;

        frame.rsp = self.context.cpu_state.rsp;
        frame.rbp = self.context.cpu_state.rbp;

        frame.rip = self.context.cpu_state.rip;

        frame.rflags = self.context.cpu_state.rflags;
    }

    /// Load a task from elf code. The task will then need to be registered using `Schedular.addTask`
    pub fn load_driver(elf_code: []const u8) !Task {
        var code_buffer = std.io.FixedBufferStream([]const u8){ .buffer = elf_code, .pos = 0 };

        var allocator = std.heap.ArenaAllocator.init(allocate.kernel_page_allocator);

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
        paging.mapKernelExtra();

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

                    _ = try paging.mapPages(phys, @as(u64, header.p_vaddr), header.p_memsz / 4097 + 1, .{ .writable = true });

                    const mem: [*]u8 = @ptrFromInt(header.p_vaddr);
                    const mem_slice = mem[0..header.p_memsz];

                    if (header.p_filesz == header.p_memsz) {
                        @memcpy(mem_slice, elf_code[header.p_offset .. header.p_offset + header.p_filesz]);
                    } else {
                        @memset(mem_slice, 0);
                    }
                },
                else => {
                    log.warn("Not loading header of type {}", .{header.p_type}, @src());
                },
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

        const process_id = next_id;
        next_id += 1;

        return .{ 
            .id = process_id,
            .allocator = allocator,
            .entry = @ptrFromInt(headers.entry),
            .context = .{
                .cpu_state = .{
                    .rsp = config.PROCESS_STACK_START - 8,
                    .rflags = 0x200,
                    .rip = headers.entry
                },
                .status = .Ready,
                .address_space = address_space,
                .heap_base = config.PROCESS_HEAP_START
            }
        };
    }

    pub fn deinit(self: Task) void {
        self.allocator.deinit();
    }
};
