const std = @import("std");
const Allocator = std.mem.Allocator;

const paging = @import("./paging.zig");
const util = @import("./util.zig");
const config = @import("./config.zig");

pub fn preInit(physical_heap_base: usize, size: usize) void {
    physical_page_allocator_ctx = .{
        .base = physical_heap_base,
        .capacity = size,
        .next_addr = physical_heap_base,
        .virtual_start = physical_heap_base,
    };
}

/// Initialize virtual mapping to physical heap.
/// We need full access to physical memory for linked list allocation
pub fn init(physical_heap_base: usize) !void {
    const aligned = std.mem.alignBackward(u64, physical_heap_base, util.gb(1));
    const offset = physical_heap_base - aligned;

    // @TODO: this might use allocations which we haven't set up to use virtual addresses yet
    try paging.mapRangeRecursively(
        .@"4K",
        physical_page_allocator,
        .{ .lower_attrs = .{ .attr_index = 0 } },
        config.HEAP_MAP_BASE,
        physical_heap_base,
        config.HEAP_MAP_SIZE,
    );

    physical_page_allocator_ctx.virtual_start = config.HEAP_MAP_BASE + offset;
    physical_page_allocator_ctx.use_virtual = true;

    // Map first and only node to full heap size (minus what we've already allocated before virtual allocation)
    const node = physical_page_allocator_ctx.nextNode().?;
    node.* = .{
        .next = null,
        .size = physical_page_allocator_ctx.capacity - physical_page_allocator_ctx.offset(),
    };

    physical_page_allocator_ctx.head = node;
}

pub const AllocationNode = struct {
    next: ?*AllocationNode,
    size: usize,
};

pub const PhysicalPageAllocator = struct {
    base: usize,
    capacity: usize,
    next_addr: usize,
    virtual_start: usize,
    use_virtual: bool = false,
    head: *AllocationNode = undefined,

    const Self = @This();

    inline fn offset(self: *Self) u64 {
        return self.next_addr - self.base;
    }

    fn nextNode(self: *Self) ?*AllocationNode {
        if (self.next_addr >= self.base + self.capacity) return null;

        return @ptrFromInt(self.virtual_start + self.offset());
    }

    fn alloc(
        ptr: *anyopaque,
        len: usize,
        log2_ptr_align: u8,
        ret_addr: usize,
    ) ?[*]u8 {
        _ = ret_addr;
        _ = log2_ptr_align;

        const self: *PhysicalPageAllocator = @ptrCast(@alignCast(ptr));
        if (len > std.math.maxInt(usize) - (std.mem.page_size - 1)) return null;
        const aligned_len = std.mem.alignForward(usize, len, std.mem.page_size);
        std.log.debug("Allocated {} bytes ", .{aligned_len});

        if (self.use_virtual) {
            // Using linked list allocation

            var last_next: ?**AllocationNode = &self.head;
            var current: ?*AllocationNode = self.head;

            // Find next node with big enough size
            while (current != null and current.?.size < aligned_len) {
                last_next = if (current.?.next) |*n| n else null;
                current = current.?.next.?;
            }

            if (current == null or current.?.size < aligned_len) return null;

            // - Current will be the memory we return
            // - We make the next node be the memory after current memory (current + aligned_len)
            const next_addr = @intFromPtr(current) + aligned_len;
            const next_node_ptr: *AllocationNode = @ptrFromInt(next_addr);

            next_node_ptr.* = .{
                .next = current.?.next,
                .size = current.?.size - aligned_len,
            };
            last_next.?.* = next_node_ptr;

            return @ptrCast(current.?);
        } else {
            const addr = self.next_addr;
            self.next_addr += aligned_len;

            return @ptrFromInt(addr);
        }
    }

    fn resize(
        _: *anyopaque,
        buf: []u8,
        log2_old_align: u8,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        _ = buf;
        _ = log2_old_align;
        _ = new_len;
        _ = ret_addr;
        return false;
    }

    fn free(
        _: *anyopaque,
        buf: []u8,
        log2_old_align: u8,
        ret_addr: usize,
    ) void {
        _ = buf;
        _ = log2_old_align;
        _ = ret_addr;
    }
};

pub const physical_page_allocator = Allocator{
    .ptr = &physical_page_allocator_ctx,
    .vtable = &raw_c_allocator_vtable,
};

var physical_page_allocator_ctx: PhysicalPageAllocator = undefined;

const raw_c_allocator_vtable = Allocator.VTable{
    .alloc = PhysicalPageAllocator.alloc,
    .resize = PhysicalPageAllocator.resize,
    .free = PhysicalPageAllocator.free,
};

pub const page_allocator = physical_page_allocator;
