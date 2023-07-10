const regs = @import("./registers.zig");
const acpi = @import("./acpi/acpi.zig");
const log = @import("./logger.zig").getLogger();

const GateType = enum(u4) {
    Interrupt = 0xE,
    Trap = 0xF,
};

const IDTEntry = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u3 = 0,
    gate_type: GateType = .Interrupt,
    dpl: enum(u2) {
        kernel = 0,
        user = 3,  
    } = .kernel,
    present: bool = false,
    offset_high: u48,
};

const IDT = struct {
    entries: [255]IDTEntry = .{ .{ .offset_low = 0, .selector = 0, .offset_high = 0 } } ** 255,

    pub fn kernelErrorISR(self: *IDT, index: u8, isr: *const fn (*const ISRFrame, u64) callconv(.Interrupt) void) void {
        const isr_val = @intFromPtr(isr);
        self.entries[index] = .{
            .offset_low = @truncate(isr_val & 0xFFFF),
            .offset_high = @truncate(isr_val >> 16),
            .present = true,
            .selector = 0x38,
        };
    }

    
     pub fn kernelISR(self: *IDT, index: u8, isr: *const fn (*const ISRFrame) callconv(.Interrupt) void) void {
        const isr_val = @intFromPtr(isr);
        self.entries[index] = .{
            .offset_low = @truncate(isr_val & 0xFFFF),
            .offset_high = @truncate(isr_val >> 16),
            .present = true,
            .selector = 0x38,
        };
    }
};

var GLOBAL_IDT = IDT{};

const ISRFrame = packed struct {
    
};

const Apic = struct {
    pub const CONTROL_BASE: usize = 0xFEE00000;
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
        InterruptCommand = 0x300,
        LVTTimer = 0x320,
        LVTThermalSensor = 0x330,
        LVTLINT0 = 0x350,
        LVTLINT1 = 0x360,
        LVTError = 0x370,
        InitialCount = 0x380,
        CurrentCount = 0x390,
        DivideConfiguration = 0x3E0,
    };   

    pub fn read(register: Register, comptime return_ty: type) return_ty {
        const ptr: *return_ty = @ptrFromInt(CONTROL_BASE + @as(usize, @intFromEnum(register)));
        return ptr.*;
    }

    pub fn write(register: Register, comptime value: anytype) void {
        const ptr: *@TypeOf(value) = @ptrFromInt(CONTROL_BASE + @as(usize, @intFromEnum(register)));
        ptr.* = value;
    }
};

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
        vector: u8,
        delivery_mode: DeliveryMode,
        destination_mode: DestinationMode,
        delivery_status: bool,
        polarity: Polarity,
        remoteIRR: u1,
        trigger_mode: TriggerMode,
        masked: bool,
        unused: u39,              
        destination: u8,
    };

    pub const Register = union(enum(u32)) {
        IOAPICID = 0,
        IOAPICVER = 1,
        IOAPICARB = 2,
        Redirection: u16,
    };

    base: usize,

    pub fn read(self: *IOApic, register: Register, comptime return_ty: type) return_ty {
        const iosel: *u32 = @ptrFromInt(self.base);
        const iodata: *u32 = @ptrFromInt(self.base + 0x10);

        const offset: u32 = switch (register) {
            .IOAPICID => 0,
            .IOAPICVER => 1,
            .IOAPICARB => 2,
            .Redirection => |i| {
                var val: [2]u32 = .{0, 0};

                iosel.* = 0x10 + i * 2;
                val[0] = iodata.*;

                iosel.* = 0x10 + i * 2 + 1;
                val[1] = iodata.*;

                const value: *return_ty = @ptrCast(@alignCast(&val));

                return value.*;
            }
        };

        iosel.* = offset;
        const iodata_val: *return_ty = @ptrCast(@alignCast(iodata));
        return iodata_val.*;
    }

    pub fn write(self: *IOApic, register: Register, value: anytype) void {
        const iosel: *u32 = @ptrFromInt(self.base);
        const iodata: *u32 = @ptrFromInt(self.base + 0x10);

        const offset: u32 = switch (register) {
            .IOAPICID => 0,
            .IOAPICVER => 1,
            .IOAPICARB => 2,
            .Redirection => |i| {
                const values: [*]u32 = @ptrCast(@alignCast(&value));

                iosel.* = 0x10 + i * 2;
                iosel.* = values[0];

                iosel.* = 0x10 + i * 2 + 1;
                iosel.* = values[1];
            }
        };

        iosel.* = offset;
        const iodata_val: *@TypeOf(value) = @ptrCast(@alignCast(iodata));
        iodata_val.* = value;
    }
};

fn isr_handler(vector: u8, frame: *const ISRFrame, error_code: ?u64) void {
    _ = vector;
    _ = frame;
    _ = error_code;

    Apic.write(.EOI, @as(u64, 0));
}

comptime {
    // @compileLog(@typeInfo(acpi.MADT).Struct.fields.);
    // @compileLog(@offsetOf(acpi.MADT, "entries_start"));
}

pub fn init(xsdt: *acpi.XSDT) void {
    if (regs.CpuFeatures.get().apic) @panic("CPU does not support APIC");
    Apic.write(.SpuriousVector, @as(packed struct { offset: u8, enable: bool }, .{ .offset = 0xFF, .enable = true }));


    
    var madtn: ?*acpi.MADT = null;
    for (xsdt.entries()) |entry| {
        // write.print("XSDT Entry: {X} {s}\n", .{entry.signature, entry.signatureStr()}) catch {};
        if (entry.signature == acpi.MADT.SIGNATURE) madtn = @ptrCast(entry);
    }
    const madt = madtn orelse @panic("no madt");
    const bin: [*]u8 = @ptrCast(@alignCast(madt));
    const bins = bin[0x2C..madt.header.length];
    
    log.*.?.writer().print("MADT Entry: {} {any} \n", .{madt,bins}) catch {};

    var offset: usize = 0;
    while (offset < madt.length()) {
        const entry = madt.next_entry(offset);
        log.*.?.writer().print("MADT Entry: {X} {} {}\n", .{@intFromEnum(entry.*), offset, entry.len()}) catch {};
        offset += entry.len();
    }

    // const madt = xsdt.madt() orelse @panic("No MADT");
    // _ = madt;

    var ioapic = IOApic{.base = 0x0};
    _ = ioapic.read(.{.Redirection = 2}, IOApic.RedirectionEntry);
    
    init_idt();    
}

fn init_idt() void {
    GLOBAL_IDT.kernelErrorISR(0, isr0);
    GLOBAL_IDT.kernelErrorISR(1, isr1);
    GLOBAL_IDT.kernelErrorISR(2, isr2);
    GLOBAL_IDT.kernelErrorISR(3, isr3);
    GLOBAL_IDT.kernelErrorISR(4, isr4);
    GLOBAL_IDT.kernelErrorISR(5, isr5);
    GLOBAL_IDT.kernelErrorISR(6, isr6);
    GLOBAL_IDT.kernelErrorISR(7, isr7);
    GLOBAL_IDT.kernelErrorISR(8, isr8);
    GLOBAL_IDT.kernelErrorISR(9, isr9);
    GLOBAL_IDT.kernelErrorISR(10, isr10);
    GLOBAL_IDT.kernelErrorISR(11, isr11);
    GLOBAL_IDT.kernelErrorISR(12, isr12);
    GLOBAL_IDT.kernelErrorISR(13, isr13);
    GLOBAL_IDT.kernelErrorISR(14, isr14);
    GLOBAL_IDT.kernelErrorISR(15, isr15);
    GLOBAL_IDT.kernelErrorISR(16, isr16);
    GLOBAL_IDT.kernelErrorISR(17, isr17);
    GLOBAL_IDT.kernelErrorISR(18, isr18);
    GLOBAL_IDT.kernelErrorISR(19, isr19);
    GLOBAL_IDT.kernelErrorISR(20, isr20);
    GLOBAL_IDT.kernelErrorISR(21, isr21);
    GLOBAL_IDT.kernelErrorISR(22, isr22);
    GLOBAL_IDT.kernelErrorISR(23, isr23);
    GLOBAL_IDT.kernelErrorISR(24, isr24);
    GLOBAL_IDT.kernelErrorISR(25, isr25);
    GLOBAL_IDT.kernelErrorISR(26, isr26);
    GLOBAL_IDT.kernelErrorISR(27, isr27);
    GLOBAL_IDT.kernelErrorISR(28, isr28);
    GLOBAL_IDT.kernelErrorISR(29, isr29);
    GLOBAL_IDT.kernelErrorISR(30, isr30);
    GLOBAL_IDT.kernelErrorISR(31, isr31);
    GLOBAL_IDT.kernelISR(32, isr32);
    GLOBAL_IDT.kernelISR(33, isr33);
    GLOBAL_IDT.kernelISR(34, isr34);
    GLOBAL_IDT.kernelISR(35, isr35);
    GLOBAL_IDT.kernelISR(36, isr36);
    GLOBAL_IDT.kernelISR(37, isr37);
    GLOBAL_IDT.kernelISR(38, isr38);
    GLOBAL_IDT.kernelISR(39, isr39);
    GLOBAL_IDT.kernelISR(40, isr40);
    GLOBAL_IDT.kernelISR(41, isr41);
    GLOBAL_IDT.kernelISR(42, isr42);
    GLOBAL_IDT.kernelISR(43, isr43);
    GLOBAL_IDT.kernelISR(44, isr44);
    GLOBAL_IDT.kernelISR(45, isr45);
    GLOBAL_IDT.kernelISR(46, isr46);
    GLOBAL_IDT.kernelISR(47, isr47);
    GLOBAL_IDT.kernelISR(48, isr48);
    GLOBAL_IDT.kernelISR(49, isr49);
    GLOBAL_IDT.kernelISR(50, isr50);
    GLOBAL_IDT.kernelISR(51, isr51);
    GLOBAL_IDT.kernelISR(52, isr52);
    GLOBAL_IDT.kernelISR(53, isr53);
    GLOBAL_IDT.kernelISR(54, isr54);
    GLOBAL_IDT.kernelISR(55, isr55);
    GLOBAL_IDT.kernelISR(56, isr56);
    GLOBAL_IDT.kernelISR(57, isr57);
    GLOBAL_IDT.kernelISR(58, isr58);
    GLOBAL_IDT.kernelISR(59, isr59);
    GLOBAL_IDT.kernelISR(60, isr60);
    GLOBAL_IDT.kernelISR(61, isr61);
    GLOBAL_IDT.kernelISR(62, isr62);
    GLOBAL_IDT.kernelISR(63, isr63);
    GLOBAL_IDT.kernelISR(64, isr64);
    GLOBAL_IDT.kernelISR(65, isr65);
    GLOBAL_IDT.kernelISR(66, isr66);
    GLOBAL_IDT.kernelISR(67, isr67);
    GLOBAL_IDT.kernelISR(68, isr68);
    GLOBAL_IDT.kernelISR(69, isr69);
    GLOBAL_IDT.kernelISR(70, isr70);
    GLOBAL_IDT.kernelISR(71, isr71);
    GLOBAL_IDT.kernelISR(72, isr72);
    GLOBAL_IDT.kernelISR(73, isr73);
    GLOBAL_IDT.kernelISR(74, isr74);
    GLOBAL_IDT.kernelISR(75, isr75);
    GLOBAL_IDT.kernelISR(76, isr76);
    GLOBAL_IDT.kernelISR(77, isr77);
    GLOBAL_IDT.kernelISR(78, isr78);
    GLOBAL_IDT.kernelISR(79, isr79);
    GLOBAL_IDT.kernelISR(80, isr80);
    GLOBAL_IDT.kernelISR(81, isr81);
    GLOBAL_IDT.kernelISR(82, isr82);
    GLOBAL_IDT.kernelISR(83, isr83);
    GLOBAL_IDT.kernelISR(84, isr84);
    GLOBAL_IDT.kernelISR(85, isr85);
    GLOBAL_IDT.kernelISR(86, isr86);
    GLOBAL_IDT.kernelISR(87, isr87);
    GLOBAL_IDT.kernelISR(88, isr88);
    GLOBAL_IDT.kernelISR(89, isr89);
    GLOBAL_IDT.kernelISR(90, isr90);
    GLOBAL_IDT.kernelISR(91, isr91);
    GLOBAL_IDT.kernelISR(92, isr92);
    GLOBAL_IDT.kernelISR(93, isr93);
    GLOBAL_IDT.kernelISR(94, isr94);
    GLOBAL_IDT.kernelISR(95, isr95);
    GLOBAL_IDT.kernelISR(96, isr96);
    GLOBAL_IDT.kernelISR(97, isr97);
    GLOBAL_IDT.kernelISR(98, isr98);
    GLOBAL_IDT.kernelISR(99, isr99);
    GLOBAL_IDT.kernelISR(100, isr100);
    GLOBAL_IDT.kernelISR(101, isr101);
    GLOBAL_IDT.kernelISR(102, isr102);
    GLOBAL_IDT.kernelISR(103, isr103);
    GLOBAL_IDT.kernelISR(104, isr104);
    GLOBAL_IDT.kernelISR(105, isr105);
    GLOBAL_IDT.kernelISR(106, isr106);
    GLOBAL_IDT.kernelISR(107, isr107);
    GLOBAL_IDT.kernelISR(108, isr108);
    GLOBAL_IDT.kernelISR(109, isr109);
    GLOBAL_IDT.kernelISR(110, isr110);
    GLOBAL_IDT.kernelISR(111, isr111);
    GLOBAL_IDT.kernelISR(112, isr112);
    GLOBAL_IDT.kernelISR(113, isr113);
    GLOBAL_IDT.kernelISR(114, isr114);
    GLOBAL_IDT.kernelISR(115, isr115);
    GLOBAL_IDT.kernelISR(116, isr116);
    GLOBAL_IDT.kernelISR(117, isr117);
    GLOBAL_IDT.kernelISR(118, isr118);
    GLOBAL_IDT.kernelISR(119, isr119);
    GLOBAL_IDT.kernelISR(120, isr120);
    GLOBAL_IDT.kernelISR(121, isr121);
    GLOBAL_IDT.kernelISR(122, isr122);
    GLOBAL_IDT.kernelISR(123, isr123);
    GLOBAL_IDT.kernelISR(124, isr124);
    GLOBAL_IDT.kernelISR(125, isr125);
    GLOBAL_IDT.kernelISR(126, isr126);
    GLOBAL_IDT.kernelISR(127, isr127);
    GLOBAL_IDT.kernelISR(128, isr128);
    GLOBAL_IDT.kernelISR(129, isr129);
    GLOBAL_IDT.kernelISR(130, isr130);
    GLOBAL_IDT.kernelISR(131, isr131);
    GLOBAL_IDT.kernelISR(132, isr132);
    GLOBAL_IDT.kernelISR(133, isr133);
    GLOBAL_IDT.kernelISR(134, isr134);
    GLOBAL_IDT.kernelISR(135, isr135);
    GLOBAL_IDT.kernelISR(136, isr136);
    GLOBAL_IDT.kernelISR(137, isr137);
    GLOBAL_IDT.kernelISR(138, isr138);
    GLOBAL_IDT.kernelISR(139, isr139);
    GLOBAL_IDT.kernelISR(140, isr140);
    GLOBAL_IDT.kernelISR(141, isr141);
    GLOBAL_IDT.kernelISR(142, isr142);
    GLOBAL_IDT.kernelISR(143, isr143);
    GLOBAL_IDT.kernelISR(144, isr144);
    GLOBAL_IDT.kernelISR(145, isr145);
    GLOBAL_IDT.kernelISR(146, isr146);
    GLOBAL_IDT.kernelISR(147, isr147);
    GLOBAL_IDT.kernelISR(148, isr148);
    GLOBAL_IDT.kernelISR(149, isr149);
    GLOBAL_IDT.kernelISR(150, isr150);
    GLOBAL_IDT.kernelISR(151, isr151);
    GLOBAL_IDT.kernelISR(152, isr152);
    GLOBAL_IDT.kernelISR(153, isr153);
    GLOBAL_IDT.kernelISR(154, isr154);
    GLOBAL_IDT.kernelISR(155, isr155);
    GLOBAL_IDT.kernelISR(156, isr156);
    GLOBAL_IDT.kernelISR(157, isr157);
    GLOBAL_IDT.kernelISR(158, isr158);
    GLOBAL_IDT.kernelISR(159, isr159);
    GLOBAL_IDT.kernelISR(160, isr160);
    GLOBAL_IDT.kernelISR(161, isr161);
    GLOBAL_IDT.kernelISR(162, isr162);
    GLOBAL_IDT.kernelISR(163, isr163);
    GLOBAL_IDT.kernelISR(164, isr164);
    GLOBAL_IDT.kernelISR(165, isr165);
    GLOBAL_IDT.kernelISR(166, isr166);
    GLOBAL_IDT.kernelISR(167, isr167);
    GLOBAL_IDT.kernelISR(168, isr168);
    GLOBAL_IDT.kernelISR(169, isr169);
    GLOBAL_IDT.kernelISR(170, isr170);
    GLOBAL_IDT.kernelISR(171, isr171);
    GLOBAL_IDT.kernelISR(172, isr172);
    GLOBAL_IDT.kernelISR(173, isr173);
    GLOBAL_IDT.kernelISR(174, isr174);
    GLOBAL_IDT.kernelISR(175, isr175);
    GLOBAL_IDT.kernelISR(176, isr176);
    GLOBAL_IDT.kernelISR(177, isr177);
    GLOBAL_IDT.kernelISR(178, isr178);
    GLOBAL_IDT.kernelISR(179, isr179);
    GLOBAL_IDT.kernelISR(180, isr180);
    GLOBAL_IDT.kernelISR(181, isr181);
    GLOBAL_IDT.kernelISR(182, isr182);
    GLOBAL_IDT.kernelISR(183, isr183);
    GLOBAL_IDT.kernelISR(184, isr184);
    GLOBAL_IDT.kernelISR(185, isr185);
    GLOBAL_IDT.kernelISR(186, isr186);
    GLOBAL_IDT.kernelISR(187, isr187);
    GLOBAL_IDT.kernelISR(188, isr188);
    GLOBAL_IDT.kernelISR(189, isr189);
    GLOBAL_IDT.kernelISR(190, isr190);
    GLOBAL_IDT.kernelISR(191, isr191);
    GLOBAL_IDT.kernelISR(192, isr192);
    GLOBAL_IDT.kernelISR(193, isr193);
    GLOBAL_IDT.kernelISR(194, isr194);
    GLOBAL_IDT.kernelISR(195, isr195);
    GLOBAL_IDT.kernelISR(196, isr196);
    GLOBAL_IDT.kernelISR(197, isr197);
    GLOBAL_IDT.kernelISR(198, isr198);
    GLOBAL_IDT.kernelISR(199, isr199);
    GLOBAL_IDT.kernelISR(200, isr200);
    GLOBAL_IDT.kernelISR(201, isr201);
    GLOBAL_IDT.kernelISR(202, isr202);
    GLOBAL_IDT.kernelISR(203, isr203);
    GLOBAL_IDT.kernelISR(204, isr204);
    GLOBAL_IDT.kernelISR(205, isr205);
    GLOBAL_IDT.kernelISR(206, isr206);
    GLOBAL_IDT.kernelISR(207, isr207);
    GLOBAL_IDT.kernelISR(208, isr208);
    GLOBAL_IDT.kernelISR(209, isr209);
    GLOBAL_IDT.kernelISR(210, isr210);
    GLOBAL_IDT.kernelISR(211, isr211);
    GLOBAL_IDT.kernelISR(212, isr212);
    GLOBAL_IDT.kernelISR(213, isr213);
    GLOBAL_IDT.kernelISR(214, isr214);
    GLOBAL_IDT.kernelISR(215, isr215);
    GLOBAL_IDT.kernelISR(216, isr216);
    GLOBAL_IDT.kernelISR(217, isr217);
    GLOBAL_IDT.kernelISR(218, isr218);
    GLOBAL_IDT.kernelISR(219, isr219);
    GLOBAL_IDT.kernelISR(220, isr220);
    GLOBAL_IDT.kernelISR(221, isr221);
    GLOBAL_IDT.kernelISR(222, isr222);
    GLOBAL_IDT.kernelISR(223, isr223);
    GLOBAL_IDT.kernelISR(224, isr224);
    GLOBAL_IDT.kernelISR(225, isr225);
    GLOBAL_IDT.kernelISR(226, isr226);
    GLOBAL_IDT.kernelISR(227, isr227);
    GLOBAL_IDT.kernelISR(228, isr228);
    GLOBAL_IDT.kernelISR(229, isr229);
    GLOBAL_IDT.kernelISR(230, isr230);
    GLOBAL_IDT.kernelISR(231, isr231);
    GLOBAL_IDT.kernelISR(232, isr232);
    GLOBAL_IDT.kernelISR(233, isr233);
    GLOBAL_IDT.kernelISR(234, isr234);
    GLOBAL_IDT.kernelISR(235, isr235);
    GLOBAL_IDT.kernelISR(236, isr236);
    GLOBAL_IDT.kernelISR(237, isr237);
    GLOBAL_IDT.kernelISR(238, isr238);
    GLOBAL_IDT.kernelISR(239, isr239);
    GLOBAL_IDT.kernelISR(240, isr240);
    GLOBAL_IDT.kernelISR(241, isr241);
    GLOBAL_IDT.kernelISR(242, isr242);
    GLOBAL_IDT.kernelISR(243, isr243);
    GLOBAL_IDT.kernelISR(244, isr244);
    GLOBAL_IDT.kernelISR(245, isr245);
    GLOBAL_IDT.kernelISR(246, isr246);
    GLOBAL_IDT.kernelISR(247, isr247);
    GLOBAL_IDT.kernelISR(248, isr248);
    GLOBAL_IDT.kernelISR(249, isr249);
    GLOBAL_IDT.kernelISR(250, isr250);
    GLOBAL_IDT.kernelISR(251, isr251);
    GLOBAL_IDT.kernelISR(252, isr252);
    GLOBAL_IDT.kernelISR(253, isr253);
    GLOBAL_IDT.kernelISR(254, isr254);
    GLOBAL_IDT.kernelISR(255, isr255);
}

fn isr0(frame: *const ISRFrame, error_code: u64) callconv(.Interrupt) void { isr_handler(0, frame, error_code); }
fn isr1(frame: *const ISRFrame, error_code: u64) callconv(.Interrupt) void { isr_handler(1, frame, error_code); }
fn isr2(frame: *const ISRFrame, error_code: u64) callconv(.Interrupt) void { isr_handler(2, frame, error_code); }
fn isr3(frame: *const ISRFrame, error_code: u64) callconv(.Interrupt) void { isr_handler(3, frame, error_code); }
fn isr4(frame: *const ISRFrame, error_code: u64) callconv(.Interrupt) void { isr_handler(4, frame, error_code); }
fn isr5(frame: *const ISRFrame, error_code: u64) callconv(.Interrupt) void { isr_handler(5, frame, error_code); }
fn isr6(frame: *const ISRFrame, error_code: u64) callconv(.Interrupt) void { isr_handler(6, frame, error_code); }
fn isr7(frame: *const ISRFrame, error_code: u64) callconv(.Interrupt) void { isr_handler(7, frame, error_code); }
fn isr8(frame: *const ISRFrame, error_code: u64) callconv(.Interrupt) void { isr_handler(8, frame, error_code); }
fn isr9(frame: *const ISRFrame, error_code: u64) callconv(.Interrupt) void { isr_handler(9, frame, error_code); }
fn isr10(frame: *const ISRFrame, error_code: u64) callconv(.Interrupt) void { isr_handler(10, frame, error_code); }
fn isr11(frame: *const ISRFrame, error_code: u64) callconv(.Interrupt) void { isr_handler(11, frame, error_code); }
fn isr12(frame: *const ISRFrame, error_code: u64) callconv(.Interrupt) void { isr_handler(12, frame, error_code); }
fn isr13(frame: *const ISRFrame, error_code: u64) callconv(.Interrupt) void { isr_handler(13, frame, error_code); }
fn isr14(frame: *const ISRFrame, error_code: u64) callconv(.Interrupt) void { isr_handler(14, frame, error_code); }
fn isr15(frame: *const ISRFrame, error_code: u64) callconv(.Interrupt) void { isr_handler(15, frame, error_code); }
fn isr16(frame: *const ISRFrame, error_code: u64) callconv(.Interrupt) void { isr_handler(16, frame, error_code); }
fn isr17(frame: *const ISRFrame, error_code: u64) callconv(.Interrupt) void { isr_handler(17, frame, error_code); }
fn isr18(frame: *const ISRFrame, error_code: u64) callconv(.Interrupt) void { isr_handler(18, frame, error_code); }
fn isr19(frame: *const ISRFrame, error_code: u64) callconv(.Interrupt) void { isr_handler(19, frame, error_code); }
fn isr20(frame: *const ISRFrame, error_code: u64) callconv(.Interrupt) void { isr_handler(20, frame, error_code); }
fn isr21(frame: *const ISRFrame, error_code: u64) callconv(.Interrupt) void { isr_handler(21, frame, error_code); }
fn isr22(frame: *const ISRFrame, error_code: u64) callconv(.Interrupt) void { isr_handler(22, frame, error_code); }
fn isr23(frame: *const ISRFrame, error_code: u64) callconv(.Interrupt) void { isr_handler(23, frame, error_code); }
fn isr24(frame: *const ISRFrame, error_code: u64) callconv(.Interrupt) void { isr_handler(24, frame, error_code); }
fn isr25(frame: *const ISRFrame, error_code: u64) callconv(.Interrupt) void { isr_handler(25, frame, error_code); }
fn isr26(frame: *const ISRFrame, error_code: u64) callconv(.Interrupt) void { isr_handler(26, frame, error_code); }
fn isr27(frame: *const ISRFrame, error_code: u64) callconv(.Interrupt) void { isr_handler(27, frame, error_code); }
fn isr28(frame: *const ISRFrame, error_code: u64) callconv(.Interrupt) void { isr_handler(28, frame, error_code); }
fn isr29(frame: *const ISRFrame, error_code: u64) callconv(.Interrupt) void { isr_handler(29, frame, error_code); }
fn isr30(frame: *const ISRFrame, error_code: u64) callconv(.Interrupt) void { isr_handler(30, frame, error_code); }
fn isr31(frame: *const ISRFrame, error_code: u64) callconv(.Interrupt) void { isr_handler(31, frame, error_code); }
fn isr32(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(32, frame, null); }
fn isr33(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(33, frame, null); }
fn isr34(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(34, frame, null); }
fn isr35(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(35, frame, null); }
fn isr36(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(36, frame, null); }
fn isr37(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(37, frame, null); }
fn isr38(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(38, frame, null); }
fn isr39(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(39, frame, null); }
fn isr40(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(40, frame, null); }
fn isr41(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(41, frame, null); }
fn isr42(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(42, frame, null); }
fn isr43(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(43, frame, null); }
fn isr44(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(44, frame, null); }
fn isr45(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(45, frame, null); }
fn isr46(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(46, frame, null); }
fn isr47(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(47, frame, null); }
fn isr48(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(48, frame, null); }
fn isr49(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(49, frame, null); }
fn isr50(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(50, frame, null); }
fn isr51(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(51, frame, null); }
fn isr52(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(52, frame, null); }
fn isr53(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(53, frame, null); }
fn isr54(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(54, frame, null); }
fn isr55(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(55, frame, null); }
fn isr56(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(56, frame, null); }
fn isr57(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(57, frame, null); }
fn isr58(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(58, frame, null); }
fn isr59(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(59, frame, null); }
fn isr60(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(60, frame, null); }
fn isr61(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(61, frame, null); }
fn isr62(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(62, frame, null); }
fn isr63(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(63, frame, null); }
fn isr64(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(64, frame, null); }
fn isr65(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(65, frame, null); }
fn isr66(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(66, frame, null); }
fn isr67(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(67, frame, null); }
fn isr68(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(68, frame, null); }
fn isr69(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(69, frame, null); }
fn isr70(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(70, frame, null); }
fn isr71(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(71, frame, null); }
fn isr72(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(72, frame, null); }
fn isr73(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(73, frame, null); }
fn isr74(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(74, frame, null); }
fn isr75(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(75, frame, null); }
fn isr76(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(76, frame, null); }
fn isr77(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(77, frame, null); }
fn isr78(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(78, frame, null); }
fn isr79(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(79, frame, null); }
fn isr80(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(80, frame, null); }
fn isr81(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(81, frame, null); }
fn isr82(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(82, frame, null); }
fn isr83(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(83, frame, null); }
fn isr84(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(84, frame, null); }
fn isr85(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(85, frame, null); }
fn isr86(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(86, frame, null); }
fn isr87(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(87, frame, null); }
fn isr88(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(88, frame, null); }
fn isr89(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(89, frame, null); }
fn isr90(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(90, frame, null); }
fn isr91(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(91, frame, null); }
fn isr92(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(92, frame, null); }
fn isr93(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(93, frame, null); }
fn isr94(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(94, frame, null); }
fn isr95(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(95, frame, null); }
fn isr96(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(96, frame, null); }
fn isr97(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(97, frame, null); }
fn isr98(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(98, frame, null); }
fn isr99(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(99, frame, null); }
fn isr100(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(100, frame, null); }
fn isr101(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(101, frame, null); }
fn isr102(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(102, frame, null); }
fn isr103(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(103, frame, null); }
fn isr104(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(104, frame, null); }
fn isr105(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(105, frame, null); }
fn isr106(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(106, frame, null); }
fn isr107(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(107, frame, null); }
fn isr108(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(108, frame, null); }
fn isr109(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(109, frame, null); }
fn isr110(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(110, frame, null); }
fn isr111(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(111, frame, null); }
fn isr112(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(112, frame, null); }
fn isr113(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(113, frame, null); }
fn isr114(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(114, frame, null); }
fn isr115(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(115, frame, null); }
fn isr116(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(116, frame, null); }
fn isr117(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(117, frame, null); }
fn isr118(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(118, frame, null); }
fn isr119(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(119, frame, null); }
fn isr120(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(120, frame, null); }
fn isr121(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(121, frame, null); }
fn isr122(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(122, frame, null); }
fn isr123(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(123, frame, null); }
fn isr124(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(124, frame, null); }
fn isr125(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(125, frame, null); }
fn isr126(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(126, frame, null); }
fn isr127(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(127, frame, null); }
fn isr128(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(128, frame, null); }
fn isr129(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(129, frame, null); }
fn isr130(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(130, frame, null); }
fn isr131(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(131, frame, null); }
fn isr132(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(132, frame, null); }
fn isr133(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(133, frame, null); }
fn isr134(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(134, frame, null); }
fn isr135(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(135, frame, null); }
fn isr136(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(136, frame, null); }
fn isr137(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(137, frame, null); }
fn isr138(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(138, frame, null); }
fn isr139(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(139, frame, null); }
fn isr140(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(140, frame, null); }
fn isr141(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(141, frame, null); }
fn isr142(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(142, frame, null); }
fn isr143(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(143, frame, null); }
fn isr144(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(144, frame, null); }
fn isr145(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(145, frame, null); }
fn isr146(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(146, frame, null); }
fn isr147(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(147, frame, null); }
fn isr148(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(148, frame, null); }
fn isr149(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(149, frame, null); }
fn isr150(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(150, frame, null); }
fn isr151(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(151, frame, null); }
fn isr152(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(152, frame, null); }
fn isr153(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(153, frame, null); }
fn isr154(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(154, frame, null); }
fn isr155(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(155, frame, null); }
fn isr156(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(156, frame, null); }
fn isr157(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(157, frame, null); }
fn isr158(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(158, frame, null); }
fn isr159(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(159, frame, null); }
fn isr160(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(160, frame, null); }
fn isr161(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(161, frame, null); }
fn isr162(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(162, frame, null); }
fn isr163(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(163, frame, null); }
fn isr164(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(164, frame, null); }
fn isr165(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(165, frame, null); }
fn isr166(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(166, frame, null); }
fn isr167(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(167, frame, null); }
fn isr168(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(168, frame, null); }
fn isr169(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(169, frame, null); }
fn isr170(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(170, frame, null); }
fn isr171(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(171, frame, null); }
fn isr172(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(172, frame, null); }
fn isr173(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(173, frame, null); }
fn isr174(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(174, frame, null); }
fn isr175(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(175, frame, null); }
fn isr176(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(176, frame, null); }
fn isr177(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(177, frame, null); }
fn isr178(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(178, frame, null); }
fn isr179(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(179, frame, null); }
fn isr180(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(180, frame, null); }
fn isr181(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(181, frame, null); }
fn isr182(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(182, frame, null); }
fn isr183(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(183, frame, null); }
fn isr184(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(184, frame, null); }
fn isr185(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(185, frame, null); }
fn isr186(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(186, frame, null); }
fn isr187(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(187, frame, null); }
fn isr188(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(188, frame, null); }
fn isr189(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(189, frame, null); }
fn isr190(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(190, frame, null); }
fn isr191(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(191, frame, null); }
fn isr192(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(192, frame, null); }
fn isr193(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(193, frame, null); }
fn isr194(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(194, frame, null); }
fn isr195(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(195, frame, null); }
fn isr196(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(196, frame, null); }
fn isr197(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(197, frame, null); }
fn isr198(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(198, frame, null); }
fn isr199(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(199, frame, null); }
fn isr200(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(200, frame, null); }
fn isr201(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(201, frame, null); }
fn isr202(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(202, frame, null); }
fn isr203(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(203, frame, null); }
fn isr204(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(204, frame, null); }
fn isr205(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(205, frame, null); }
fn isr206(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(206, frame, null); }
fn isr207(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(207, frame, null); }
fn isr208(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(208, frame, null); }
fn isr209(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(209, frame, null); }
fn isr210(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(210, frame, null); }
fn isr211(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(211, frame, null); }
fn isr212(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(212, frame, null); }
fn isr213(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(213, frame, null); }
fn isr214(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(214, frame, null); }
fn isr215(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(215, frame, null); }
fn isr216(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(216, frame, null); }
fn isr217(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(217, frame, null); }
fn isr218(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(218, frame, null); }
fn isr219(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(219, frame, null); }
fn isr220(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(220, frame, null); }
fn isr221(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(221, frame, null); }
fn isr222(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(222, frame, null); }
fn isr223(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(223, frame, null); }
fn isr224(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(224, frame, null); }
fn isr225(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(225, frame, null); }
fn isr226(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(226, frame, null); }
fn isr227(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(227, frame, null); }
fn isr228(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(228, frame, null); }
fn isr229(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(229, frame, null); }
fn isr230(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(230, frame, null); }
fn isr231(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(231, frame, null); }
fn isr232(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(232, frame, null); }
fn isr233(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(233, frame, null); }
fn isr234(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(234, frame, null); }
fn isr235(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(235, frame, null); }
fn isr236(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(236, frame, null); }
fn isr237(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(237, frame, null); }
fn isr238(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(238, frame, null); }
fn isr239(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(239, frame, null); }
fn isr240(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(240, frame, null); }
fn isr241(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(241, frame, null); }
fn isr242(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(242, frame, null); }
fn isr243(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(243, frame, null); }
fn isr244(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(244, frame, null); }
fn isr245(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(245, frame, null); }
fn isr246(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(246, frame, null); }
fn isr247(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(247, frame, null); }
fn isr248(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(248, frame, null); }
fn isr249(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(249, frame, null); }
fn isr250(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(250, frame, null); }
fn isr251(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(251, frame, null); }
fn isr252(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(252, frame, null); }
fn isr253(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(253, frame, null); }
fn isr254(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(254, frame, null); }
fn isr255(frame: *const ISRFrame) callconv(.Interrupt) void { isr_handler(255, frame, null); }



