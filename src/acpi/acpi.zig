const log = @import("../logger.zig").getLogger();
const alloc = @import("../allocator.zig");
const paging = @import("../paging.zig");

/// Setup acpi memory maps
pub fn init() !void {
    const map = alloc.getMemoryMap();

    for (map) |desc| {
        switch (desc.type) {
            .ACPIReclaimMemory => {
                _ = try paging.mapPages(desc.physical_start, desc.physical_start, desc.number_of_pages, .{ .writable = true });
            },
            else => {},
        }
    }
}

/// Common header that all ACPI tables contain
pub const DescriptionHeader = packed struct {
    signature: u32,
    length: u32,
    revision: u8,
    checksum: u8,
    oemid: u48,
    oem_table: u64,
    oem_revision: u32,
    creator_id: u32,
    creator_revision: u32,

    /// Returns the signature of the table as a string
    pub fn signatureStr(self: *DescriptionHeader) []const u8 {
        const self_ptr: [*]u8 = @ptrCast(&self.signature);
        return self_ptr[0..4];
    }

    /// Downcast into a concrete table type
    pub fn as(self: *DescriptionHeader, comptime return_val: type) *return_val {
        return @ptrCast(self);
    }

    /// Downcast into a concrete table type (const)
    pub fn asConst(self: *const DescriptionHeader, comptime return_val: type) *const return_val {
        return @ptrCast(self);
    }
};

/// `Root System Description Pointer`
pub const RSDP align(1) = packed struct { sig: u64, checksum: u8, oemid: u48, revision: u8, rsdt: u32, length: u32, xsdt: u64 };

/// `Root System Description Table`
pub const RSDT = packed struct {
    header: DescriptionHeader,
    entries_start: usize,

    pub fn entries(self: *align(1) const RSDT) []align(1) const u32 {
        const array: [*]align(1) const u32 = @ptrCast(&self.entries_start);
        return array[0 .. (self.header.length - @sizeOf(DescriptionHeader)) / @sizeOf(u32)];
    }
};

/// `Extended System Description Table`
pub const XSDT = packed struct {
    header: DescriptionHeader,
    entries_start: usize,

    pub fn entries(self: *align(1) const XSDT) []align(1) const *DescriptionHeader {
        const array: [*]align(1) const *DescriptionHeader = @ptrCast(&self.entries_start);
        return array[0 .. (self.header.length - @sizeOf(DescriptionHeader)) / @sizeOf(u64)];
    }

    pub fn madt(self: *align(1) const XSDT) ?*const MADT {
        for (self.entries()) |entry| {
            if (entry.signature == MADT.SIGNATURE)
                return entry.asConst(MADT);
        }
        return null;
    }
};

/// `Fixed ACPI Description Table`
pub const FADT = packed struct {
    header: DescriptionHeader,

    pub const SIGNATURE = 0x50434146;
};

/// `Multiple APIC Description Table`
pub const MADT = packed struct {
    pub const EntryTag = enum(u16) {
        local_apic = 0x0800,
        io_apic = 0x0C01,
        io_apic_source_override = 0x0A02,
        local_apic_nmi = 0x0604,
        _,
    };

    pub const LocalApic = packed struct {
        processor_id: u8,
        apic_id: u8,
        flags: u32,
    };
    pub const IoApic = packed struct { io_apic_id: u8, reserved: u8, io_apic_address: u32, gsi_base: u32 };
    pub const IoApicSourceOverride = packed struct {
        bus: u8,
        irq: u8,
        gsi: u32,
        flags: u16,
    };
    pub const LocalApicNMI = packed struct { io_apic_id: u8, flags: u16, lint: u8 };

    pub const Entry = union(enum(u8)) {
        local_apic: LocalApic,
        io_apic: IoApic,
        io_apic_source_override: IoApicSourceOverride,
        local_apic_nmi: LocalApicNMI,
        count: u8,

        pub fn len(self: *const Entry) u8 {
            return switch (self.*) {
                .local_apic => |_| 8,
                .io_apic => |_| 12,
                .io_apic_source_override => |_| 10,
                .local_apic_nmi => |_| 6,
                .count => |n| n,
            };

            // const i = @intFromEnum(self.*);
            // log.*.?.writer().print("len: {}\n", .{i}) catch {};
            // return @truncate(i & 0xFF);
        }
    };

    header: DescriptionHeader,
    apic_address: u32,
    flags: u32,
    entries_start: usize,

    pub const SIGNATURE = 0x43495041;

    pub fn len(self: *const MADT) usize {
        return self.header.length - 0x2C;
    }

    pub fn next_entry(self: *const MADT, offset: usize) Entry {
        var array: [*]const u8 = @ptrCast(&self.entries_start);
        array += offset;

        const entry_tag_ptr: *align(1) const EntryTag = @ptrCast(array);
        array += 2;

        switch (entry_tag_ptr.*) {
            .local_apic => {
                const ptr: *align(1) const LocalApic = @ptrCast(array);
                return .{ .local_apic = ptr.* };
            },
            .io_apic => {
                const ptr: *align(1) const IoApic = @ptrCast(array);
                return .{ .io_apic = ptr.* };
            },
            .io_apic_source_override => {
                const ptr: *align(1) const IoApicSourceOverride = @ptrCast(array);
                return .{ .io_apic_source_override = ptr.* };
            },
            .local_apic_nmi => {
                const ptr: *align(1) const LocalApicNMI = @ptrCast(array);
                return .{ .local_apic_nmi = ptr.* };
            },
            else => return .{ .count = @truncate(@intFromEnum(entry_tag_ptr.*) >> 8) },
        }
    }
};

pub const HPET = packed struct {
    header: DescriptionHeader,

    pub const SIGNATURE = 0x54455048;
};

pub const MCFG = packed struct {
    header: DescriptionHeader,

    pub const SIGNATURE = 0x4746434D;
};
