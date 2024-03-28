const util = @import("./util.zig");

/// Base virtual address of virtual heap mapping.
/// NOTE: this address should only be used in physical frame allocation NOT by applications
pub const HEAP_MAP_BASE: u64 = util.tb(1);

/// Heap size for page frame allocation
/// NOTE: this size should only be used in physical frame allocation NOT by applications
pub const HEAP_MAP_SIZE: u64 = util.gb(1);