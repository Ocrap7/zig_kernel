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
        const address = asm volatile ("mov %cr0, %rax" : [ret] "={rax}" (-> u64));
        return @bitCast(address);
    }

    pub fn set(cr0: CR0) void {
        const ival: u64 = @bitCast(cr0);
        asm volatile ("mov %rax, %cr0" :: [val] "{rax}" (ival));
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
        const address = asm volatile ("mov %cr3, %rax" : [ret] "={rax}" (-> u64));
        return @bitCast(address);
    }

    pub fn set_address(addr: *u8) void {
        const cr3 = CR3{
            .low = .{ .pcid = 0 },
            .phys_addr = @truncate(@intFromPtr(addr) >> 12),
        };
        const ival: u64 = @bitCast(cr3);
        asm volatile ("mov %rax, %cr4" :: [val] "{rax}" (ival));
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
        const address = asm volatile ("mov %cr4, %rax" : [ret] "={rax}" (-> u64));
        return @bitCast(address);
    }

    pub fn set(self: CR4) void {
        const ival: u64 = @bitCast(self);
        asm volatile ("mov %rax, %cr4" :: [val] "{rax}" (ival));
    }
};

comptime {
    assert(@bitSizeOf(CR4) == 64);
}

pub const CpuFeatures = packed struct {
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

    pub fn get() CpuFeatures {
        return asm volatile ("cpuid; shlq $32, %rdx; shrdq $32, %rdx, %rcx" : [ret] "={rcx}" (-> CpuFeatures): [param] "{eax}" (1) : "ecx", "edx");
    }
};

pub fn getIP() usize {
    return asm volatile("lea (%rip), %rax" : [ret] "={rax}" (-> usize));
}

pub fn jumpIP(ip: usize, param: anytype) void {
    asm volatile("push %rax; ret" :: [ip] "{rax}" (ip), [param] "{rcx}" (param));
}

pub fn sti() callconv(.Inline) void {
    asm volatile("sti");
}

pub fn cli() callconv(.Inline) void {
    asm volatile("cli");
}

pub fn mask_legacy_pic() callconv(.Inline) void {
    asm volatile("out %al, $0xA1; out %al, $0x21" :: [mask] "{al}" (0xFF));
}