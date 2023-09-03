const log = @import("./logger.zig");
const apic = @import("./lapic.zig");

pub const IOApic = struct {
    pub const DeliveryMode = enum(u3) {
        Fixed = 0b000,
        Lowest = 0b001,
        SMI = 0b010,
        NMI = 0b100,
        INIT = 0b101,
        ExtINIT = 0b111,
    };

    pub const DestinationMode = enum(u1) {
        Physical = 0,
        Logical = 1,
    };

    pub const Polarity = enum(u1) {
        ActiveHigh,
        ActiveLow,
    };

    pub const TriggerMode = enum(u1) {
        Edge,
        Level,
    };

    pub const RedirectionEntry = packed struct {
        /// The Interrupt vector that will be raised on the specified CPU(s).
        vector: u8,
        /// How the interrupt will be sent to the CPU(s).
        delivery_mode: DeliveryMode = .Fixed,
        /// Specify how the Destination field shall be interpreted.
        destination_mode: DestinationMode = .Physical,
        /// If clear, the IRQ is just relaxed and waiting for something to happen (or it has fired and already processed by Local APIC(s)).
        /// If set, it means that the IRQ has been sent to the Local APICs but it's still waiting to be delivered.
        delivery_status: bool = false,
        /// For ISA IRQs assume Active High unless otherwise specified in Interrupt Source Override descriptors of the MADT or in the MP Tables.
        polarity: Polarity = .ActiveHigh,
        remoteIRR: u1 = 0,
        /// For ISA IRQs assume Edge unless otherwise specified in Interrupt Source Override descriptors of the MADT or in the MP Tables.
        trigger_mode: TriggerMode = .Edge,
        // Temporarily disable this IRQ by setting this, and reenable it by clearing.
        masked: bool,
        unused: u39 = 0,
        /// This field is interpreted according to the Destination Format bit.
        /// If Physical destination is choosen, then this field is limited to bits 56 - 59 (only 16 CPUs addressable). You put here the APIC ID of the CPU that you want to receive the interrupt.
        destination: u8,
    };

    pub const Info = packed struct(u32) {
        version: u9,
        _: u7,
        max_entries: u8,
        _1: u8,
    };

    pub const Register = union(enum(u32)) {
        IOAPICID = 0,
        IOAPICVER = 1,
        IOAPICARB = 2,
        Redirection: u16,
    };

    base: usize,

    pub fn enable_vector(self: *IOApic, vector: u8, irq: u16) void {
        const lapic_id = apic.cpuApic().read(.LapicId, u8);

        self.write(.{ .Redirection = irq }, RedirectionEntry{
            .vector = vector,
            .destination = lapic_id & 0xF,
            .masked = false,
        });
    }

    pub fn info(self: *IOApic) IOApic.Info {
        return self.read(.IOAPICVER, IOApic.Info);
    }

    /// Reads a value from the ioapic register
    pub fn read(self: *IOApic, register: Register, comptime return_ty: type) return_ty {
        // Volatile is needed on these two ptrs so that the first read isn't optimized out
        const iosel: *volatile u32 = @ptrFromInt(self.base);
        const iodata: *volatile u32 = @ptrFromInt(self.base + 0x10);

        const offset: u32 = switch (register) {
            .IOAPICID => 0,
            .IOAPICVER => 1,
            .IOAPICARB => 2,
            .Redirection => |i| {
                var values: [2]u32 = .{ 0, 0 };

                iosel.* = 0x10 + i * 2;
                values[0] = iodata.*;

                iosel.* = 0x10 + i * 2 + 1;
                values[1] = iodata.*;

                const value: *return_ty = @ptrCast(@alignCast(&values));

                return value.*;
            },
        };

        iosel.* = offset;
        const iodata_val: *volatile return_ty = @ptrCast(@alignCast(iodata));
        return iodata_val.*;
    }

    /// Write some value to the specified ioapic register
    pub fn write(self: *IOApic, register: Register, value: anytype) void {
        // Volatile is needed on these two ptrs so that the first write isn't optimized out
        const iosel: *volatile u32 = @ptrFromInt(self.base);
        const iodata: *volatile u32 = @ptrFromInt(self.base + 0x10);

        const offset: u32 = switch (register) {
            .IOAPICID => 0,
            .IOAPICVER => 1,
            .IOAPICARB => 2,
            .Redirection => |i| {
                const values: [*]const u32 = @ptrCast(@alignCast(&value));

                iosel.* = 0x10 + i * 2;
                iodata.* = values[0];

                iosel.* = 0x10 + i * 2 + 1;
                iodata.* = values[1];

                return;
            },
        };

        iosel.* = offset;
        const iodata_val: *volatile @TypeOf(value) = @ptrCast(@alignCast(iodata));
        iodata_val.* = value;
    }
};

pub fn get(base: usize) IOApic {
    return IOApic{ .base = base };
}

pub fn init(base: usize, vector_offset: u8) IOApic {
    var ioapic = IOApic{ .base = base };

    const info = ioapic.read(.IOAPICVER, IOApic.Info);
    const lapic_id = apic.cpuApic().read(.LapicId, u8);

    for (0..info.max_entries + 1) |i| {
        ioapic.write(.{ .Redirection = @truncate(i) }, IOApic.RedirectionEntry{
            .vector = @as(u8, @truncate(i)) + vector_offset,
            .destination = lapic_id & 0xF,
            .masked = true,
        });
    }

    log.info("IOApic info: {}", .{info}, @src());

    return ioapic;
}
