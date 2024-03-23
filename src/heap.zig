const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn init(physical_heap_base: usize) void {
    physical_page_allocator_ctx = .{ .next_addr = physical_heap_base };
}

pub const PhysicalPageAllocator = struct {
    next_addr: usize,

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

        const addr = self.next_addr;
        self.next_addr += aligned_len;

        std.log.debug("Allocated {} bytes", .{aligned_len});
        return @ptrFromInt(addr);
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
