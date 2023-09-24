const std = @import("std");
const uefi = @import("std").os.uefi;
const regs = @import("./registers.zig");
const log = @import("./logger.zig");
const assert = std.debug.assert;

pub const TSS = extern struct {
    _res0: u32 align(4) = 0,
    rsp: [3]u64 align(4) = .{0} ** 3,
    _res1: u64 align(4) = 0,
    ist: [7]u64 align(4) = .{0} ** 7,
    _res2: u64 align(4) = 0,
    _res3: u16 align(2) = 0,
    iopb: u16 align(2) = @sizeOf(@This()),
};

comptime {
    assert(@sizeOf(TSS) == 104);
}

var GLOBAL_TSS = TSS{};

const IST_VEC: u8 = 1;

pub fn setInterruptIst(value: u64) void {
    GLOBAL_TSS.ist[IST_VEC & 0b111 - 1] = value;
}

pub fn getIstInterruptVec() u8 {
    return IST_VEC & 0b111;
}

pub const Access = packed struct(u8) {
    accessed: bool = false,
    rw: bool = false,
    conforming: bool = false,
    executable: bool = false,
    type: enum(u1) {
        system_segment = 0,
        user_segment = 1,
    } = .system_segment,
    dpl: enum(u2) {
        kernel = 0,
        user = 3,
    } = .kernel,
    present: bool = false,

    pub fn kernel_code() @This() {
        return .{
            .executable = true,
            .type = .user_segment,
            .present = true,
            .rw = true,
        };
    }

    pub fn kernel_data() @This() {
        return .{
            .type = .user_segment,
            .present = true,
            .rw = true,
        };
    }

    pub fn user_code() @This() {
        return .{
            .executable = true,
            .type = .user_segment,
            .present = true,
            .rw = true,
            .dpl = .user,
        };
    }

    pub fn user_data() @This() {
        return .{
            .type = .user_segment,
            .present = true,
            .rw = true,
            .dpl = .user,
        };
    }

    pub fn tss() @This() {
        return .{
            .present = true,
            .executable = true,
            .accessed = true,
            // .rw = true,
        };
    }
};

const Flags = packed struct(u4) {
    _: u1 = 0,
    long_mode: bool = false,
    db: bool = false,
    page_blocks: bool = false,
};

pub const Entry = packed struct(u64) {
    limit_low: u16 = 0xFFFF,
    base_low: u24 = 0,
    access: Access,
    limit_high: u4 = 0xF,
    flags: Flags = .{},
    base_high: u8 = 0,

    fn null_segment() @This() {
        return .{
            .limit_low = 0,
            .access = .{},
            .limit_high = 0,
            .flags = .{},
        };
    }

    fn kernel_code() @This() {
        return .{
            .access = Access.kernel_code(),
            .flags = .{ .page_blocks = true, .long_mode = true },
        };
    }

    fn kernel_data() @This() {
        return .{
            .access = Access.kernel_data(),
            .flags = .{ .page_blocks = true, .long_mode = true },
        };
    }

    fn user_code() @This() {
        return .{
            .access = Access.user_code(),
            .flags = .{ .page_blocks = true, .long_mode = true },
        };
    }

    fn user_data() @This() {
        return .{
            .access = Access.user_data(),
            .flags = .{ .page_blocks = true, .long_mode = true },
        };
    }

    pub fn kernel_code_selector() u16 {
        return 0x08;
    }

    pub fn kernel_data_selector() u16 {
        return 0x10;
    }

    pub fn user_code_selector() u16 {
        return 0x20;
    }

    pub fn user_data_selector() u16 {
        return 0x28;
    }

    pub fn tss_selector() u16 {
        return 0x30;
    }
};

pub const SystemEntry = packed struct(u128) {
    limit_low: u16 = 0xFFFF,
    base_low: u24 = 0,
    access: Access,
    limit_high: u4 = 0xF,
    flags: Flags = .{},
    base_high: u40 = 0,
    _: u32 = 0,

    fn tss() @This() {
        const tss_addr = @intFromPtr(&GLOBAL_TSS);
        const tss_size = @sizeOf(TSS);

        return .{
            .limit_low = tss_size,
            .limit_high = 0,
            .base_low = @truncate(tss_addr & 0xFFFFFF),
            .base_high = @truncate(tss_addr >> 24),
            .access = Access.tss(),
            .flags = .{ .long_mode = false, .page_blocks = false },
        };
    }

    fn low(self: SystemEntry) Entry {
        const ptr: *const Entry = @ptrCast(&self);
        return ptr.*;
    }

    fn high(self: SystemEntry) Entry {
        const ptr: [*]const Entry = @ptrCast(&self);
        return ptr[1];
    }
};

pub var GLOBAL_GDT: [8]Entry align(4096) = undefined;
pub var DESCRIPTOR: Descriptor = undefined;

pub const Descriptor = packed struct {
    size: u16,
    offset: u64,
};

pub fn init_gdt() void {
    GLOBAL_GDT = .{
        Entry.null_segment(), // 0x00
        Entry.kernel_code(), // 0x08
        Entry.kernel_data(), // 0x10
        Entry.null_segment(), // 0x18
        Entry.user_data(), // 0x20
        Entry.user_code(), // 0x28
        SystemEntry.tss().low(), // 0x30
        SystemEntry.tss().high(), // 0x30
    };

    DESCRIPTOR = .{
        .size = @sizeOf(Entry) * 8 - 1,
        .offset = @intFromPtr(&GLOBAL_GDT),
    };

    asm volatile ("lgdt (%[gdtr])"
        :
        : [gdtr] "r" (&DESCRIPTOR),
    );

    regs.load_tss(Entry.tss_selector());

    regs.set_data_segments(Entry.kernel_data_selector());
    regs.set_cs(Entry.kernel_code_selector());
}

test "kernel access segments" {
    try std.testing.expect(@as(u8, 0x9A) == @as(u8, @bitCast(Access.kernel_code())));
    try std.testing.expect(@as(u4, 0xA) == @as(u4, @bitCast(Entry.kernel_code().flags)));

    try std.testing.expect(@as(u8, 0x92) == @as(u8, @bitCast(Access.kernel_data())));
    try std.testing.expect(@as(u4, 0xC) == @as(u4, @bitCast(Entry.kernel_data().flags)));
}

test "user access segments" {
    try std.testing.expect(@as(u8, 0xFA) == @as(u8, @bitCast(Access.user_code())));
    try std.testing.expect(@as(u4, 0xA) == @as(u4, @bitCast(Entry.user_code().flags)));

    try std.testing.expect(@as(u8, 0xF2) == @as(u8, @bitCast(Access.user_data())));
    try std.testing.expect(@as(u4, 0xC) == @as(u4, @bitCast(Entry.user_data().flags)));
}

test "tss access" {
    try std.testing.expect(@as(u8, 0x89) == @as(u8, @bitCast(Access.tss())));
}

test "null segment" {
    try std.testing.expect(@as(u64, 0x0) == @as(u64, @bitCast(Entry.null_segment())));
}
