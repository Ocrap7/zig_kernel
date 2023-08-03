const regs = @import("./registers.zig");
const acpi = @import("./acpi/acpi.zig");
const log = @import("./logger.zig").getLogger();
const paging = @import("./paging.zig");

const GateType = enum(u4) {
    Interrupt = 0xE,
    Trap = 0xF,
};

const IDTEntry = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u3 = 0,
    reserved1: u5 = 0,
    gate_type: GateType = .Interrupt,
    reserved2: u1 = 0,
    dpl: enum(u2) {
        kernel = 0,
        user = 3,
    } = .kernel,
    present: bool = false,
    offset_high: u48,
    reserved3: u32 = 0,
};

const IDT align(16) = struct {
    entries: [256]IDTEntry = .{.{ .offset_low = 0, .selector = 0, .offset_high = 0 }} ** 256,

    pub fn kernelErrorISR(self: *IDT, index: u8, isr: *const fn () callconv(.Naked) void) void {
        const isr_val = @intFromPtr(isr);
        self.entries[index] = .{
            .offset_low = @truncate(isr_val & 0xFFFF),
            .offset_high = @truncate(isr_val >> 16),
            .present = true,
            .selector = 0x38,
        };
    }

    pub fn kernelISR(self: *IDT, index: u8, isr: *const fn () callconv(.Naked) void) void {
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
var IDT_DESCRIPTOR: packed struct { size: u16, base: u64 } = .{ .base = 0, .size = 0 };

const ISRFrame = extern struct {
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,

    vector: u64,
    error_code: u64,
    
    rip: usize,
    cs: u64,
    rflags: u64,
    rsp: usize,
    ss: u64,
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

    pub fn read(register: Register, comptime return_ty: type) return_ty {
        const ptr: *return_ty = @ptrFromInt(CONTROL_BASE + @as(usize, @intFromEnum(register)));
        return ptr.*;
    }

    pub fn write(register: Register, comptime value: anytype) void {
        const ptr: *@TypeOf(value) = @ptrFromInt(CONTROL_BASE + @as(usize, @intFromEnum(register)));
        ptr.* = value;
        _ = ptr.*;
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
        remoteIRR: u1  = 0,
        /// For ISA IRQs assume Edge unless otherwise specified in Interrupt Source Override descriptors of the MADT or in the MP Tables.
        trigger_mode: TriggerMode = .Edge,
        // Temporarily disable this IRQ by setting this, and reenable it by clearing.
        masked: bool,
        unused: u39 = 0,
        /// This field is interpreted according to the Destination Format bit. 
        /// If Physical destination is choosen, then this field is limited to bits 56 - 59 (only 16 CPUs addressable). You put here the APIC ID of the CPU that you want to receive the interrupt.
        destination: u8,
    };

    pub const Register = union(enum(u32)) {
        IOAPICID = 0,
        IOAPICVER = 1,
        IOAPICARB = 2,
        Redirection: u16,
    };

    base: usize,

    /// Reads a value from the ioapic register
    pub fn read(self: *IOApic, register: Register, comptime return_ty: type) return_ty {
        // Volatile is needed on these two ptrs so that the first read isn't optimized out
        const iosel : *volatile u32 = @ptrFromInt(self.base);
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

export fn isr_handler(frame: *const ISRFrame) void {
    // regs.cli();

    log.*.?.writer().print("Interrupt : {X}\n", .{frame.rip}) catch {};
    // _ = frame;

    Apic.write(.EOI, @as(u32, 0));
    // regs.sti();
}

const PIC1: u16 = 0x20;
const PIC2: u16	= 0xA0;
const PIC1_COMMAND: u16	= PIC1;
const PIC1_DATA: u16 = (PIC1+1);
const PIC2_COMMAND: u16	= PIC2;
const PIC2_DATA: u16 = (PIC2+1);

const ICW1_ICW4: u8	= 0x01;	
const ICW1_SINGLE: u8 = 0x02;	
const ICW1_INTERVAL4: u8 = 0x04;
const ICW1_LEVEL: u8 = 0x08;	
const ICW1_INIT: u8	= 0x10;	
 
const ICW4_8086: u8	= 0x01;	
const ICW4_AUTO: u8	= 0x02;	
const ICW4_BUF_SLAVE: u8 = 0x08;
const ICW4_BUF_MASTER: u8 = 0x0C;
const ICW4_SFNM: u8	= 0x10;	
	
pub fn init(xsdt: *align(1) const acpi.XSDT) void {
    _ = xsdt;
    // regs.out(23, @as(u8, 45));
    // _ = regs.in(23, u8);
    // const a1 = regs.in(PIC)
    regs.cli();
    // _ = asm ("in %[ret], %[reg]" : [ret] "=r" (-> u32) : [reg] "n" (4));
    const a1 = regs.in(PIC1_DATA, u8);
    const a2 = regs.in(PIC2_DATA, u8);                        // save masks
	// const a2: u8 = regs.in(PIC2_DATA, u8);
 
	regs.out(PIC1_COMMAND, ICW1_INIT | ICW1_ICW4);  // starts the initialization sequence (in cascade mode)
    regs.wait();
	regs.out(PIC2_COMMAND, ICW1_INIT | ICW1_ICW4);
    regs.wait();

	regs.out(PIC1_DATA, @as(u8, 0x20));                 // ICW2: Master PIC vector offset
    regs.wait();
	regs.out(PIC2_DATA, @as(u8, 0x28));                 // ICW2: Slave PIC vector offset
    regs.wait();

	regs.out(PIC1_DATA, @as(u8, 4));                       // ICW3: tell Master PIC that there is a slave PIC at IRQ2 (0000 0100)
    regs.wait();
	regs.out(PIC2_DATA, @as(u8, 2));                       // ICW3: tell Slave PIC its cascade identity (0000 0010)
    regs.wait();
 
	regs.out(PIC1_DATA, ICW4_8086);               // ICW4: have the PICs use 8086 mode (and not 8080 mode)
    regs.wait();
	regs.out(PIC2_DATA, ICW4_8086);
    regs.wait();
 
	regs.out(PIC1_DATA, a1);   // restore saved masks.
    regs.wait();
	regs.out(PIC2_DATA, a2);
    regs.wait();


    IDT_DESCRIPTOR.base = @intFromPtr(&GLOBAL_IDT);
    IDT_DESCRIPTOR.size = 256 * @sizeOf(IDTEntry) - 1;
    
    init_idt();
    asm volatile ("lidt (%[idtr])" :: [idtr] "r" (@intFromPtr(&IDT_DESCRIPTOR)));
}

pub fn init2(xsdt: *const acpi.XSDT) void {
    if (regs.CpuFeatures.get().apic) @panic("CPU does not support APIC");

    regs.cli();
    regs.mask_legacy_pic();

    Apic.write(.SpuriousVector, @as(packed struct { offset: u8, enable: bool }, .{ .offset = 0xFF, .enable = true }));
    
    Apic.write(.LVTTimer, @as(u32, 32 | 0x20000));
    Apic.write(.DivideConfiguration, @as(u32, 0xB));
    Apic.write(.InitialCount, @as(u32, 10000000));

    Apic.write(.LVTPCINT, @as(u32, 0x10000));

    Apic.write(.LVTLINT0, @as(u32, 0x10000));
    Apic.write(.LVTLINT1, @as(u32, 0x10000));

    Apic.write(.ErrorStatus, @as(u32, 0));
    Apic.write(.ErrorStatus, @as(u32, 0));

    Apic.write(.EOI, @as(u32, 0));

    Apic.write(.IntCommandLow, @as(u32, 0x88500));
    Apic.write(.IntCommandHigh, @as(u32, 0x0));

    while (Apic.read(.IntCommandLow, u32) & 0x1000 != 0) {}

    Apic.write(.TaskPriority, @as(u32, 0));

    const madt = xsdt.madt() orelse @panic("fskldf");

    var apic_id: ?u8 = null;
    var ioapic_address: ?usize = null;

    const len = madt.length();
    var offset: usize = 0;
    while (offset < len) {
        const entry = madt.next_entry(offset);

        switch (entry) {
            .local_apic => |val| {
                apic_id = val.apic_id;
                log.*.?.writer().print("LocalApic@{}\n", .{val}) catch {};
            },
            .io_apic => |val| {
                ioapic_address = val.io_apic_address; 
                log.*.?.writer().print("IOAPIC@{X}\n", .{ val.io_apic_address }) catch {};
                // break;
            },
            else => {}
        }

        offset += entry.len();
    }

    var ioapic = IOApic{ .base = ioapic_address.? };
    _ = ioapic;

    // ioapic.write(. { .Redirection = 0 }, IOApic.RedirectionEntry{
    //     .vector = 0x20,
    //     .destination = apic_id.?,
    //     .masked = true,
    // });

    // ioapic.write(. { .Redirection = 7 }, IOApic.RedirectionEntry{
    //     .vector = 0x27,
    //     .destination = apic_id.?,
    //     .masked = false,
    // });

    IDT_DESCRIPTOR.base = @intFromPtr(&GLOBAL_IDT);
    IDT_DESCRIPTOR.size = 256 * @sizeOf(IDTEntry) - 1;
    
    init_idt();
    asm volatile ("lidt (%[idtr])" :: [idtr] "r" (@intFromPtr(&IDT_DESCRIPTOR)));


    asm volatile("int3");
}

fn init_idt() void {
    GLOBAL_IDT.kernelISR(0, isr0);
    GLOBAL_IDT.kernelISR(1, isr1);
    GLOBAL_IDT.kernelISR(2, isr2);
    GLOBAL_IDT.kernelISR(3, isr3);
    GLOBAL_IDT.kernelISR(4, isr4);
    GLOBAL_IDT.kernelISR(5, isr5);
    GLOBAL_IDT.kernelISR(6, isr6);
    GLOBAL_IDT.kernelISR(7, isr7);
    GLOBAL_IDT.kernelErrorISR(8, isr8);
    GLOBAL_IDT.kernelISR(9, isr9);
    GLOBAL_IDT.kernelErrorISR(10, isr10);
    GLOBAL_IDT.kernelErrorISR(11, isr11);
    GLOBAL_IDT.kernelErrorISR(12, isr12);
    GLOBAL_IDT.kernelErrorISR(13, isr13);
    GLOBAL_IDT.kernelErrorISR(14, isr14);
    GLOBAL_IDT.kernelISR(15, isr15);
    GLOBAL_IDT.kernelISR(16, isr16);
    GLOBAL_IDT.kernelErrorISR(17, isr17);
    GLOBAL_IDT.kernelISR(18, isr18);
    GLOBAL_IDT.kernelISR(19, isr19);
    GLOBAL_IDT.kernelISR(20, isr20);
    GLOBAL_IDT.kernelISR(21, isr21);
    GLOBAL_IDT.kernelISR(22, isr22);
    GLOBAL_IDT.kernelISR(23, isr23);
    GLOBAL_IDT.kernelISR(24, isr24);
    GLOBAL_IDT.kernelISR(25, isr25);
    GLOBAL_IDT.kernelISR(26, isr26);
    GLOBAL_IDT.kernelISR(27, isr27);
    GLOBAL_IDT.kernelISR(28, isr28);
    GLOBAL_IDT.kernelISR(29, isr29);
    GLOBAL_IDT.kernelErrorISR(30, isr30);
    GLOBAL_IDT.kernelISR(31, isr31);
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

// TODO: Use callconv(.Interrupt) functions when they work

comptime {
    asm (
        \\.global isr_stub_next
        \\isr_stub_next:
    
        \\    push %rax   
        \\    push %rbx   
        \\    push %rcx   
        \\    push %rdx   
        \\    push %rsi   
        \\    push %rdi   

        \\    mov %rsp, %rcx

        \\    call isr_handler

        \\    pop %rdi
        \\    pop %rsi
        \\    pop %rdx
        \\    pop %rcx
        \\    pop %rbx
        \\    pop %rax  

        \\    add $16, %rsp
        \\    iret
    );

    
    asm (
        \\.global isr_stub_next
        \\isr_stub_next_err:
    
        \\    push %rax   
        \\    push %rbx   
        \\    push %rcx   
        \\    push %rdx   
        \\    push %rsi   
        \\    push %rdi   

        \\    mov %rsp, %rcx

        \\    call isr_handler

        \\    pop %rdi
        \\    pop %rsi
        \\    pop %rdx
        \\    pop %rcx
        \\    pop %rbx
        \\    pop %rax  

        \\    add $8, %rsp
        \\    iret
    );
}

fn isr_stub(comptime vector: u64) callconv(.Inline) void {
    // asm volatile ("1: jmp 1b");
    asm volatile (
        // \\cli
        \\pushq $0   
        \\pushq %[vector]
        \\jmp isr_stub_next
        :: [vector] "n" (vector)
    );
}

fn isr_stub_err(comptime vector: u64) callconv(.Inline) void {
    asm volatile (
        // \\cli
        \\pushq %[vector]
        \\jmp isr_stub_next
        :: [vector] "n" (vector)
    );
}

// Functions generated by virt.js
fn isr0() callconv(.Naked) void { isr_stub(0); }
fn isr1() callconv(.Naked) void { isr_stub(1); }
fn isr2() callconv(.Naked) void { isr_stub(2); }
fn isr3() callconv(.Naked) void { isr_stub(3); }
fn isr4() callconv(.Naked) void { isr_stub(4); }
fn isr5() callconv(.Naked) void { isr_stub(5); }
fn isr6() callconv(.Naked) void { isr_stub(6); }
fn isr7() callconv(.Naked) void { isr_stub(7); }
fn isr8() callconv(.Naked) void { isr_stub_err(8); }
fn isr9() callconv(.Naked) void { isr_stub(9); }
fn isr10() callconv(.Naked) void { isr_stub_err(10); }
fn isr11() callconv(.Naked) void { isr_stub_err(11); }
fn isr12() callconv(.Naked) void { isr_stub_err(12); }
fn isr13() callconv(.Naked) void { isr_stub_err(13); }
fn isr14() callconv(.Naked) void { isr_stub_err(14); }
fn isr15() callconv(.Naked) void { isr_stub(15); }
fn isr16() callconv(.Naked) void { isr_stub(16); }
fn isr17() callconv(.Naked) void { isr_stub_err(17); }
fn isr18() callconv(.Naked) void { isr_stub(18); }
fn isr19() callconv(.Naked) void { isr_stub(19); }
fn isr20() callconv(.Naked) void { isr_stub(20); }
fn isr21() callconv(.Naked) void { isr_stub(21); }
fn isr22() callconv(.Naked) void { isr_stub(22); }
fn isr23() callconv(.Naked) void { isr_stub(23); }
fn isr24() callconv(.Naked) void { isr_stub(24); }
fn isr25() callconv(.Naked) void { isr_stub(25); }
fn isr26() callconv(.Naked) void { isr_stub(26); }
fn isr27() callconv(.Naked) void { isr_stub(27); }
fn isr28() callconv(.Naked) void { isr_stub(28); }
fn isr29() callconv(.Naked) void { isr_stub(29); }
fn isr30() callconv(.Naked) void { isr_stub_err(30); }
fn isr31() callconv(.Naked) void { isr_stub(31); }
fn isr32() callconv(.Naked) void { isr_stub(32); }
fn isr33() callconv(.Naked) void { isr_stub(33); }
fn isr34() callconv(.Naked) void { isr_stub(34); }
fn isr35() callconv(.Naked) void { isr_stub(35); }
fn isr36() callconv(.Naked) void { isr_stub(36); }
fn isr37() callconv(.Naked) void { isr_stub(37); }
fn isr38() callconv(.Naked) void { isr_stub(38); }
fn isr39() callconv(.Naked) void { isr_stub(39); }
fn isr40() callconv(.Naked) void { isr_stub(40); }
fn isr41() callconv(.Naked) void { isr_stub(41); }
fn isr42() callconv(.Naked) void { isr_stub(42); }
fn isr43() callconv(.Naked) void { isr_stub(43); }
fn isr44() callconv(.Naked) void { isr_stub(44); }
fn isr45() callconv(.Naked) void { isr_stub(45); }
fn isr46() callconv(.Naked) void { isr_stub(46); }
fn isr47() callconv(.Naked) void { isr_stub(47); }
fn isr48() callconv(.Naked) void { isr_stub(48); }
fn isr49() callconv(.Naked) void { isr_stub(49); }
fn isr50() callconv(.Naked) void { isr_stub(50); }
fn isr51() callconv(.Naked) void { isr_stub(51); }
fn isr52() callconv(.Naked) void { isr_stub(52); }
fn isr53() callconv(.Naked) void { isr_stub(53); }
fn isr54() callconv(.Naked) void { isr_stub(54); }
fn isr55() callconv(.Naked) void { isr_stub(55); }
fn isr56() callconv(.Naked) void { isr_stub(56); }
fn isr57() callconv(.Naked) void { isr_stub(57); }
fn isr58() callconv(.Naked) void { isr_stub(58); }
fn isr59() callconv(.Naked) void { isr_stub(59); }
fn isr60() callconv(.Naked) void { isr_stub(60); }
fn isr61() callconv(.Naked) void { isr_stub(61); }
fn isr62() callconv(.Naked) void { isr_stub(62); }
fn isr63() callconv(.Naked) void { isr_stub(63); }
fn isr64() callconv(.Naked) void { isr_stub(64); }
fn isr65() callconv(.Naked) void { isr_stub(65); }
fn isr66() callconv(.Naked) void { isr_stub(66); }
fn isr67() callconv(.Naked) void { isr_stub(67); }
fn isr68() callconv(.Naked) void { isr_stub(68); }
fn isr69() callconv(.Naked) void { isr_stub(69); }
fn isr70() callconv(.Naked) void { isr_stub(70); }
fn isr71() callconv(.Naked) void { isr_stub(71); }
fn isr72() callconv(.Naked) void { isr_stub(72); }
fn isr73() callconv(.Naked) void { isr_stub(73); }
fn isr74() callconv(.Naked) void { isr_stub(74); }
fn isr75() callconv(.Naked) void { isr_stub(75); }
fn isr76() callconv(.Naked) void { isr_stub(76); }
fn isr77() callconv(.Naked) void { isr_stub(77); }
fn isr78() callconv(.Naked) void { isr_stub(78); }
fn isr79() callconv(.Naked) void { isr_stub(79); }
fn isr80() callconv(.Naked) void { isr_stub(80); }
fn isr81() callconv(.Naked) void { isr_stub(81); }
fn isr82() callconv(.Naked) void { isr_stub(82); }
fn isr83() callconv(.Naked) void { isr_stub(83); }
fn isr84() callconv(.Naked) void { isr_stub(84); }
fn isr85() callconv(.Naked) void { isr_stub(85); }
fn isr86() callconv(.Naked) void { isr_stub(86); }
fn isr87() callconv(.Naked) void { isr_stub(87); }
fn isr88() callconv(.Naked) void { isr_stub(88); }
fn isr89() callconv(.Naked) void { isr_stub(89); }
fn isr90() callconv(.Naked) void { isr_stub(90); }
fn isr91() callconv(.Naked) void { isr_stub(91); }
fn isr92() callconv(.Naked) void { isr_stub(92); }
fn isr93() callconv(.Naked) void { isr_stub(93); }
fn isr94() callconv(.Naked) void { isr_stub(94); }
fn isr95() callconv(.Naked) void { isr_stub(95); }
fn isr96() callconv(.Naked) void { isr_stub(96); }
fn isr97() callconv(.Naked) void { isr_stub(97); }
fn isr98() callconv(.Naked) void { isr_stub(98); }
fn isr99() callconv(.Naked) void { isr_stub(99); }
fn isr100() callconv(.Naked) void { isr_stub(100); }
fn isr101() callconv(.Naked) void { isr_stub(101); }
fn isr102() callconv(.Naked) void { isr_stub(102); }
fn isr103() callconv(.Naked) void { isr_stub(103); }
fn isr104() callconv(.Naked) void { isr_stub(104); }
fn isr105() callconv(.Naked) void { isr_stub(105); }
fn isr106() callconv(.Naked) void { isr_stub(106); }
fn isr107() callconv(.Naked) void { isr_stub(107); }
fn isr108() callconv(.Naked) void { isr_stub(108); }
fn isr109() callconv(.Naked) void { isr_stub(109); }
fn isr110() callconv(.Naked) void { isr_stub(110); }
fn isr111() callconv(.Naked) void { isr_stub(111); }
fn isr112() callconv(.Naked) void { isr_stub(112); }
fn isr113() callconv(.Naked) void { isr_stub(113); }
fn isr114() callconv(.Naked) void { isr_stub(114); }
fn isr115() callconv(.Naked) void { isr_stub(115); }
fn isr116() callconv(.Naked) void { isr_stub(116); }
fn isr117() callconv(.Naked) void { isr_stub(117); }
fn isr118() callconv(.Naked) void { isr_stub(118); }
fn isr119() callconv(.Naked) void { isr_stub(119); }
fn isr120() callconv(.Naked) void { isr_stub(120); }
fn isr121() callconv(.Naked) void { isr_stub(121); }
fn isr122() callconv(.Naked) void { isr_stub(122); }
fn isr123() callconv(.Naked) void { isr_stub(123); }
fn isr124() callconv(.Naked) void { isr_stub(124); }
fn isr125() callconv(.Naked) void { isr_stub(125); }
fn isr126() callconv(.Naked) void { isr_stub(126); }
fn isr127() callconv(.Naked) void { isr_stub(127); }
fn isr128() callconv(.Naked) void { isr_stub(128); }
fn isr129() callconv(.Naked) void { isr_stub(129); }
fn isr130() callconv(.Naked) void { isr_stub(130); }
fn isr131() callconv(.Naked) void { isr_stub(131); }
fn isr132() callconv(.Naked) void { isr_stub(132); }
fn isr133() callconv(.Naked) void { isr_stub(133); }
fn isr134() callconv(.Naked) void { isr_stub(134); }
fn isr135() callconv(.Naked) void { isr_stub(135); }
fn isr136() callconv(.Naked) void { isr_stub(136); }
fn isr137() callconv(.Naked) void { isr_stub(137); }
fn isr138() callconv(.Naked) void { isr_stub(138); }
fn isr139() callconv(.Naked) void { isr_stub(139); }
fn isr140() callconv(.Naked) void { isr_stub(140); }
fn isr141() callconv(.Naked) void { isr_stub(141); }
fn isr142() callconv(.Naked) void { isr_stub(142); }
fn isr143() callconv(.Naked) void { isr_stub(143); }
fn isr144() callconv(.Naked) void { isr_stub(144); }
fn isr145() callconv(.Naked) void { isr_stub(145); }
fn isr146() callconv(.Naked) void { isr_stub(146); }
fn isr147() callconv(.Naked) void { isr_stub(147); }
fn isr148() callconv(.Naked) void { isr_stub(148); }
fn isr149() callconv(.Naked) void { isr_stub(149); }
fn isr150() callconv(.Naked) void { isr_stub(150); }
fn isr151() callconv(.Naked) void { isr_stub(151); }
fn isr152() callconv(.Naked) void { isr_stub(152); }
fn isr153() callconv(.Naked) void { isr_stub(153); }
fn isr154() callconv(.Naked) void { isr_stub(154); }
fn isr155() callconv(.Naked) void { isr_stub(155); }
fn isr156() callconv(.Naked) void { isr_stub(156); }
fn isr157() callconv(.Naked) void { isr_stub(157); }
fn isr158() callconv(.Naked) void { isr_stub(158); }
fn isr159() callconv(.Naked) void { isr_stub(159); }
fn isr160() callconv(.Naked) void { isr_stub(160); }
fn isr161() callconv(.Naked) void { isr_stub(161); }
fn isr162() callconv(.Naked) void { isr_stub(162); }
fn isr163() callconv(.Naked) void { isr_stub(163); }
fn isr164() callconv(.Naked) void { isr_stub(164); }
fn isr165() callconv(.Naked) void { isr_stub(165); }
fn isr166() callconv(.Naked) void { isr_stub(166); }
fn isr167() callconv(.Naked) void { isr_stub(167); }
fn isr168() callconv(.Naked) void { isr_stub(168); }
fn isr169() callconv(.Naked) void { isr_stub(169); }
fn isr170() callconv(.Naked) void { isr_stub(170); }
fn isr171() callconv(.Naked) void { isr_stub(171); }
fn isr172() callconv(.Naked) void { isr_stub(172); }
fn isr173() callconv(.Naked) void { isr_stub(173); }
fn isr174() callconv(.Naked) void { isr_stub(174); }
fn isr175() callconv(.Naked) void { isr_stub(175); }
fn isr176() callconv(.Naked) void { isr_stub(176); }
fn isr177() callconv(.Naked) void { isr_stub(177); }
fn isr178() callconv(.Naked) void { isr_stub(178); }
fn isr179() callconv(.Naked) void { isr_stub(179); }
fn isr180() callconv(.Naked) void { isr_stub(180); }
fn isr181() callconv(.Naked) void { isr_stub(181); }
fn isr182() callconv(.Naked) void { isr_stub(182); }
fn isr183() callconv(.Naked) void { isr_stub(183); }
fn isr184() callconv(.Naked) void { isr_stub(184); }
fn isr185() callconv(.Naked) void { isr_stub(185); }
fn isr186() callconv(.Naked) void { isr_stub(186); }
fn isr187() callconv(.Naked) void { isr_stub(187); }
fn isr188() callconv(.Naked) void { isr_stub(188); }
fn isr189() callconv(.Naked) void { isr_stub(189); }
fn isr190() callconv(.Naked) void { isr_stub(190); }
fn isr191() callconv(.Naked) void { isr_stub(191); }
fn isr192() callconv(.Naked) void { isr_stub(192); }
fn isr193() callconv(.Naked) void { isr_stub(193); }
fn isr194() callconv(.Naked) void { isr_stub(194); }
fn isr195() callconv(.Naked) void { isr_stub(195); }
fn isr196() callconv(.Naked) void { isr_stub(196); }
fn isr197() callconv(.Naked) void { isr_stub(197); }
fn isr198() callconv(.Naked) void { isr_stub(198); }
fn isr199() callconv(.Naked) void { isr_stub(199); }
fn isr200() callconv(.Naked) void { isr_stub(200); }
fn isr201() callconv(.Naked) void { isr_stub(201); }
fn isr202() callconv(.Naked) void { isr_stub(202); }
fn isr203() callconv(.Naked) void { isr_stub(203); }
fn isr204() callconv(.Naked) void { isr_stub(204); }
fn isr205() callconv(.Naked) void { isr_stub(205); }
fn isr206() callconv(.Naked) void { isr_stub(206); }
fn isr207() callconv(.Naked) void { isr_stub(207); }
fn isr208() callconv(.Naked) void { isr_stub(208); }
fn isr209() callconv(.Naked) void { isr_stub(209); }
fn isr210() callconv(.Naked) void { isr_stub(210); }
fn isr211() callconv(.Naked) void { isr_stub(211); }
fn isr212() callconv(.Naked) void { isr_stub(212); }
fn isr213() callconv(.Naked) void { isr_stub(213); }
fn isr214() callconv(.Naked) void { isr_stub(214); }
fn isr215() callconv(.Naked) void { isr_stub(215); }
fn isr216() callconv(.Naked) void { isr_stub(216); }
fn isr217() callconv(.Naked) void { isr_stub(217); }
fn isr218() callconv(.Naked) void { isr_stub(218); }
fn isr219() callconv(.Naked) void { isr_stub(219); }
fn isr220() callconv(.Naked) void { isr_stub(220); }
fn isr221() callconv(.Naked) void { isr_stub(221); }
fn isr222() callconv(.Naked) void { isr_stub(222); }
fn isr223() callconv(.Naked) void { isr_stub(223); }
fn isr224() callconv(.Naked) void { isr_stub(224); }
fn isr225() callconv(.Naked) void { isr_stub(225); }
fn isr226() callconv(.Naked) void { isr_stub(226); }
fn isr227() callconv(.Naked) void { isr_stub(227); }
fn isr228() callconv(.Naked) void { isr_stub(228); }
fn isr229() callconv(.Naked) void { isr_stub(229); }
fn isr230() callconv(.Naked) void { isr_stub(230); }
fn isr231() callconv(.Naked) void { isr_stub(231); }
fn isr232() callconv(.Naked) void { isr_stub(232); }
fn isr233() callconv(.Naked) void { isr_stub(233); }
fn isr234() callconv(.Naked) void { isr_stub(234); }
fn isr235() callconv(.Naked) void { isr_stub(235); }
fn isr236() callconv(.Naked) void { isr_stub(236); }
fn isr237() callconv(.Naked) void { isr_stub(237); }
fn isr238() callconv(.Naked) void { isr_stub(238); }
fn isr239() callconv(.Naked) void { isr_stub(239); }
fn isr240() callconv(.Naked) void { isr_stub(240); }
fn isr241() callconv(.Naked) void { isr_stub(241); }
fn isr242() callconv(.Naked) void { isr_stub(242); }
fn isr243() callconv(.Naked) void { isr_stub(243); }
fn isr244() callconv(.Naked) void { isr_stub(244); }
fn isr245() callconv(.Naked) void { isr_stub(245); }
fn isr246() callconv(.Naked) void { isr_stub(246); }
fn isr247() callconv(.Naked) void { isr_stub(247); }
fn isr248() callconv(.Naked) void { isr_stub(248); }
fn isr249() callconv(.Naked) void { isr_stub(249); }
fn isr250() callconv(.Naked) void { isr_stub(250); }
fn isr251() callconv(.Naked) void { isr_stub(251); }
fn isr252() callconv(.Naked) void { isr_stub(252); }
fn isr253() callconv(.Naked) void { isr_stub(253); }
fn isr254() callconv(.Naked) void { isr_stub(254); }
fn isr255() callconv(.Naked) void { isr_stub(255); }
