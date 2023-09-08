pub const heap = struct {
    const allocator = @import("./allocator.zig");
    pub const page_allocator = allocator.virtual_page_allocator;
};

pub const system = struct {};
