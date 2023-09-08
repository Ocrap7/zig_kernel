const regs = @import("./registers.zig");
const log = @import("./logger.zig");

var CPU_APIC: Apic = undefined;

const Apic = struct {
    control_base: usize = 0xFEE00000,

    pub const Register = enum(u16) {
        LapicId = 0x20,
        LapicVersion = 0x30,
        TaskPriority = 0x80,
        ArbitrationPriority = 0x90,
        ProcessorPriority = 0xA0,
        EOI = 0xB0,
        RemoteRead = 0xC0,
        LocalDestination = 0xD0,
        DestinationFormat = 0xE0,
        SpuriousVector = 0xF0,
        InService = 0x100,
        TriggerMode = 0x180,
        InterruptRequest = 0x200,
        ErrorStatus = 0x280,
        CMCI = 0x2F0,
        IntCommandLow = 0x300,
        IntCommandHigh = 0x310,
        LVTTimer = 0x320,
        LVTThermalSensor = 0x330,
        LVTPCINT = 0x340,
        LVTLINT0 = 0x350,
        LVTLINT1 = 0x360,
        LVTError = 0x370,
        InitialCount = 0x380,
        CurrentCount = 0x390,
        DivideConfiguration = 0x3E0,
    };

    pub fn read(self: *const Apic, register: Register, comptime return_ty: type) return_ty {
        const ptr: *volatile return_ty = @ptrFromInt(self.control_base + @as(usize, @intFromEnum(register)));
        return ptr.*;
    }

    pub fn write(self: *Apic, register: Register, comptime value: anytype) void {
        const ptr: *volatile @TypeOf(value) = @ptrFromInt(self.control_base + @as(usize, @intFromEnum(register)));
        ptr.* = value;
    }
};

pub const DEFAULT_BASE: usize = 0xFEE00000;

/// Initialize the cpu's apic. `apic_base` should be a physical address to the base register of the apic
pub fn init(control_base: usize, virtual: usize) *Apic {
    if (control_base & @as(usize, 0xFFF) > 0) {
        log.warn("Attempted to set APIC base to non page aligned address 0x{x}", .{control_base}, @src());
    }

    log.info("Local APIC initialize at base 0x{x:0>8}", .{control_base}, @src());

    regs.setMSR(0x1B, (control_base & 0xFFFFFF0000) | 0x800); // IA32_APIC_BASE_MSR
    CPU_APIC = .{ .control_base = virtual };

    return &CPU_APIC;
}

pub fn setDefaultConfig() void {
    var apic = cpuApic();
    apic.write(.SpuriousVector, @as(packed struct(u32) { offset: u8, enable: bool, _: u23 = 0 }, .{ .offset = 0xFF, .enable = true }));

    apic.write(.LVTTimer, @as(u32, 0x20 | 0x20000));
    apic.write(.DivideConfiguration, @as(u32, 0xA));
    apic.write(.InitialCount, @as(u32, 0x00FFFFFF));

    apic.write(.LVTPCINT, @as(u32, 0x10000));

    apic.write(.LVTLINT0, @as(u32, 0x10000));
    apic.write(.LVTLINT1, @as(u32, 0x10000));

    apic.write(.ErrorStatus, @as(u32, 0));
    apic.write(.ErrorStatus, @as(u32, 0));

    apic.write(.EOI, @as(u32, 0));

    apic.write(.IntCommandLow, @as(u32, 0x88500));
    apic.write(.IntCommandHigh, @as(u32, 0x0));

    while (apic.read(.IntCommandLow, u32) & 0x1000 != 0) {}

    apic.write(.TaskPriority, @as(u32, 0));
}

/// Returns a reference to the cpu's apic
pub fn cpuApic() *Apic {
    return &CPU_APIC;
}
