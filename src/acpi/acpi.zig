const log = @import("../logger.zig").getLogger();

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

    pub fn signatureStr(self: *DescriptionHeader) []const u8 {
        const self_ptr: [*]u8 = @ptrCast(&self.signature);
        return self_ptr[0..4];
    }

    pub fn as(self: *DescriptionHeader, comptime return_val: type) *return_val {
        return @ptrCast(self);
    }
};

pub const RSDP = packed struct {
    header: DescriptionHeader,
    entries_start: usize,

    pub fn entries(self: *RSDP) []u32 {
        const array: [*]u32 = @ptrCast(&self.entries_start);
        return array[0..(self.header.length - @sizeOf(DescriptionHeader)) / @sizeOf(u32)];
    }
};

pub const XSDT = packed struct {
    header: DescriptionHeader,
    entries_start: usize,

    pub fn entries(self: *XSDT) []*DescriptionHeader {
        const array: [*]*DescriptionHeader = @ptrCast(@alignCast(&self.entries_start));
        return array[0..(self.header.length - @sizeOf(DescriptionHeader)) / @sizeOf(u64)];
    }

    pub fn madt(self: *XSDT) ?*MADT {
        var madts: ?*MADT = null;
        for (self.entries()) |entry| {
            if (entry.signature == MADT.SIGNATURE) madts = entry.as(MADT);
        }
        return madts;
    }
};

// pub const 
pub const FACP = packed struct {
    header: DescriptionHeader,

    pub const SIGNATURE = 0x50434146;
};

pub const MADT = packed struct {
    pub const Entry = union(enum(u16)) {
        local_apic: packed struct { processor_id: u8, apic_id: u8, flags: u32, } = 0x0801,
        io_apic: packed struct { io_apic_id: u8, reserved: u8, io_apic_address: u32, gsi_base: u32 } = 0x0C01,
        io_apic_source_override: packed struct { bus: u8, irq: u8, gsi: u32, flags: u16, } = 0x0A02,
        local_apic_nmi: packed struct { io_apic_id: u8, flags: u16, lint: u8 } = 0x0604,
        _,

        pub fn len(self: *const Entry) u8 {
            // return switch (self.*) {
            //     .local_apic => |_| 8,
            //     .io_apic => |_| 12,
            //     .io_apic_source_override => |_| 12,
            //     .local_apic_nmi => |_| 6,
            // };

            const i = @intFromEnum(self.*);
            log.*.?.writer().print("len: {}\n", .{i}) catch {};
            return @truncate(i & 0xFF);
        }
    };

    header: DescriptionHeader,
    apic_address: u32,
    flags: u32,
    entries_start: usize,

    pub const SIGNATURE = 0x43495041;

    pub fn length(self: *MADT) usize {

        return self.header.length - 0x2C;
    }

    pub fn next_entry(self: *MADT, offset: usize) *const Entry {
        var array: [*]u8 = @ptrCast(@alignCast(&self.entries_start));
        array += offset;

                var p = Entry{.local_apic = .{.processor_id = 1, .apic_id = 2, .flags = 3, }};
        const ptr: [*] u8 = @ptrCast(&p);
        log.*.?.writer().print("Next: {} {} {} {}\n", .{ptr[0], ptr[1], ptr[2], ptr[7]}) catch {};

        log.*.?.writer().print("Next: {} {}\n", .{array[0], array[1]}) catch {};

        const entry_ptr: *Entry = @ptrCast(@alignCast(array));
        return entry_ptr;
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

pub const WAET = packed struct {
    header: DescriptionHeader,

    pub const SIGNATURE = 0x54454157;
};
