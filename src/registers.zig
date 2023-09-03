const std = @import("std");
const assert = @import("std").debug.assert;

pub const CR0 = packed struct {
    protected_mode: bool,
    co_cpu: bool,
    fpu: bool,
    task_switched: bool,
    ext_type: bool,
    numeric_error: bool,
    res1: u10,
    write_protect: bool,
    res2: u1,
    alignment_mask: bool,
    res3: u10,
    cache_disable: bool,
    paging: bool,
    rest: u33,

    pub fn get() CR0 {
        const address = asm volatile ("mov %cr0, %rax"
            : [ret] "={rax}" (-> u64),
        );
        return @bitCast(address);
    }

    pub fn set(cr0: CR0) void {
        const ival: u64 = @bitCast(cr0);
        asm volatile ("mov %rax, %cr0"
            :
            : [val] "{rax}" (ival),
        );
    }
};

pub const CR3 = packed struct {
    low: packed union {
        attrs: packed struct {
            res1: u3,
            pwt: bool,
            res2: u1,
            pcd: bool,
            res3: u6,
        },
        pcid: u12,
    },
    phys_addr: u52,

    pub fn get() CR3 {
        const address = asm volatile ("mov %cr3, %rax"
            : [ret] "={rax}" (-> u64),
        );
        return @bitCast(address);
    }

    pub fn set_address(addr: *u8) void {
        const cr3 = CR3{
            .low = .{ .pcid = 0 },
            .phys_addr = @truncate(@intFromPtr(addr) >> 12),
        };
        const ival: u64 = @bitCast(cr3);
        asm volatile ("mov %rax, %cr4"
            :
            : [val] "{rax}" (ival),
        );
    }
};

pub const CR4 = packed struct {
    v8086: bool,
    virtual_interrupts: bool,
    time_stamp_enable: bool,
    debug_ext: bool,
    page_size_ext: bool,
    phys_addr_axt: bool,
    machine_check_exc: bool,
    page_global: bool,
    performance_monitoring: bool,
    osfxsr: bool,
    osxmmexcpt: bool,
    umip: bool,
    l5_paging: bool,
    virtual_mode: bool,
    safer_mode: bool,
    res2: u1,
    fsg_base: bool,
    pcid: bool,
    extended_states: bool,
    res3: u1,
    exe_protection: bool,
    access_protection: bool,
    protection_keys_user: bool,
    control_flow: bool,
    protection_keys_super: bool,
    res4: u39,

    pub fn get() CR4 {
        const address = asm volatile ("mov %cr4, %rax"
            : [ret] "={rax}" (-> u64),
        );
        return @bitCast(address);
    }

    pub fn set(self: CR4) void {
        const ival: u64 = @bitCast(self);
        asm volatile ("mov %rax, %cr4"
            :
            : [val] "{rax}" (ival),
        );
    }
};

comptime {
    assert(@bitSizeOf(CR4) == 64);
}

pub const CpuFeatures = packed struct(u64) {
    /// ECX values
    sse3: bool,
    pclmul: bool,
    dtes64: bool,
    monitor: bool,
    ds_cpl: bool,
    vmx: bool,
    smx: bool,
    est: bool,
    tm2: bool,
    ssse3: bool,
    cid: bool,
    sdbg: bool,
    fma: bool,
    cx16: bool,
    xtpr: bool,
    pdcm: bool,
    unused1: bool,
    pcid: bool,
    dca: bool,
    sse4_1: bool,
    sse4_2: bool,
    x2apic: bool,
    movbe: bool,
    popcnt: bool,
    tsc: bool,
    aes: bool,
    xsave: bool,
    osxsave: bool,
    avx: bool,
    f16c: bool,
    rdrandr: bool,
    hypervisor: bool,

    /// EDX values
    fpu: bool,
    vme: bool,
    de: bool,
    pse: bool,
    tsc1: bool,
    msr: bool,
    pae: bool,
    mce: bool,
    cx8: bool,
    apic: bool,
    unused2: bool,
    sep: bool,
    mtrr: bool,
    pge: bool,
    mca: bool,
    cmov: bool,
    pat: bool,
    pse36: bool,
    psn: bool,
    cflush: bool,
    unused3: bool,
    ds: bool,
    acpi: bool,
    mmx: bool,
    fxsr: bool,
    sse: bool,
    sse2: bool,
    ss: bool,
    htt: bool,
    tm: bool,
    ia64: bool,
    pbe: bool,

    /// Querys all cpu features
    pub fn get() CpuFeatures {
        return asm volatile ("cpuid; shlq $32, %rdx; or %rdx, %rcx"
            : [ret] "={rcx}" (-> CpuFeatures),
            : [param] "{eax}" (1),
            : "rcx", "rdx"
        );
    }
};

pub fn getIP() usize {
    return asm volatile ("lea (%rip), %rax"
        : [ret] "={rax}" (-> usize),
    );
}

pub fn jumpIP(ip: usize, sp: usize, param: anytype) noreturn {
    asm volatile ("push %rax; ret"
        :
        : [ip] "{rax}" (ip),
          [sp] "{rsp}" (sp),
          [bp] "{rbp}" (sp),
          [param] "{rdi}" (param),
    );

    while (true) {}
}

/// Enable interrupts
pub inline fn sti() void {
    asm volatile ("sti");
}

/// Disable interrupts
pub inline fn cli() void {
    asm volatile ("cli");
}

/// Disable all interrupt pins on the legacy PIC
pub inline fn mask_legacy_pic() void {
    asm volatile ("outb %[mask], $0xA1; outb %[mask], $0x21"
        :
        : [mask] "{al}" (@as(u8, 0xFF)),
    );
}

pub fn wait() void {
    out(0x80, @as(u8, 0));
}

/// Write to the specified i/o port. `value` can be of size 1, 2, 4, or 8 bytes.
pub inline fn out(port: u16, value: anytype) void {
    switch (@sizeOf(@TypeOf(value))) {
        1 => asm volatile ("outb %[val], %[reg]"
            :
            : [val] "r" (value),
              [reg] "{dx}" (port),
        ),
        2 => asm volatile ("outw %[val], %[reg]"
            :
            : [val] "r" (value),
              [reg] "{dx}" (port),
        ),
        4 => asm volatile ("outd %[val], %[reg]"
            :
            : [val] "r" (value),
              [reg] "{dx}" (port),
        ),
        8 => asm volatile ("outq %[val], %[reg]"
            :
            : [val] "r" (value),
              [reg] "{dx}" (port),
        ),
        else => @compileError("Unexpected type size"),
    }
}

/// Read from the specified i/o port. `ty` can be of size 1, 2, 4, or 8 bytes.
pub fn in(port: u16, comptime ty: type) ty {
    switch (@sizeOf(ty)) {
        1 => return asm ("inb %[reg], %[ret]"
            : [ret] "=r" (-> ty),
            : [reg] "{dx}" (port),
        ),
        2 => return asm ("inw %[reg], %[ret]"
            : [ret] "=r" (-> ty),
            : [reg] "{dx}" (port),
        ),
        // 4 => return asm("ind %[ret], %[reg]" : [ret] "=r" (-> ty) : [reg] "n" (port)),
        // 8 => return asm("inq %[ret], %[reg]" : [ret] "=r" (-> ty) : [reg] "n" (port)),
        else => @compileError("Unexpected type size"),
    }
}

/// Flush the paging translation lookahead buffer
pub fn flush_tlb() void {
    asm volatile ("mov %cr3, %rax; mov %rax, %cr3");
}

/// Load the task state segment with `selector` in the GDT
pub inline fn load_tss(selector: u16) void {
    asm volatile ("ltr %[sel]"
        :
        : [sel] "r" (selector),
    );
}

/// Set the value of the `cs` register
pub inline fn set_cs(selector: u16) void {
    _ = asm volatile (
        \\push %[sel]
        \\lea set_cs_out(%rip), %[tmp]
        \\push %[tmp]
        \\lretq
        \\set_cs_out:
        : [tmp] "=r" (-> usize),
        : [sel] "r" (@as(u64, selector)),
        : "memory"
    );
}

/// Set the vlaue of all of the data segment registers (`ds`, `es`, `fs`, `gs`, `ss`)
pub inline fn set_data_segments(selector: u16) void {
    asm volatile (
        \\movw %[sel], %ds
        \\movw %[sel], %es
        \\movw %[sel], %fs
        \\movw %[sel], %gs
        \\movw %[sel], %ss
        :
        : [sel] "{rax}" (selector),
    );
}
