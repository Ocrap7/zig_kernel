
pub const PageTableMode = enum(u1) {
    user,
    kernel,
};

pub const PageSize = enum(u1) {
    small,
    large,
};

pub const PageTableEntry align(4096) = packed struct {
    present: bool,
    writable: bool,
    mode: PageTableMode,
    write_through: bool,
    cache_disable: bool,
    accessed: bool,
    dirty: bool,
    available: bool,
    size: PageSize,
    global: bool,

    os: u3,

    address: u40,

    os_high: u7,

    protection: u4,
    execute_disable: bool
};

pub const PAGE_TABLE_ENTRIES = 512;

pub const PageTable = struct {
    entries: [PAGE_TABLE_ENTRIES]PageTableEntry,
};

pub fn getPageTable() void {
    var address = asm volatile ("" : [ret] "={cr3}" (-> u32));
    _ = address;
}