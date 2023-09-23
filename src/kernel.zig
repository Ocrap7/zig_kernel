const std = @import("std");
const uefi = @import("std").os.uefi;

const log = @import("./logger.zig");
const regs = @import("./registers.zig");
const alloc = @import("./allocator.zig");
const acpi = @import("./acpi/acpi.zig");
const gdt = @import("./gdt.zig");
const irq = @import("./irq.zig");
const config = @import("./config.zig");
const devices = @import("./devices/devices.zig");
const events = @import("./events.zig");
const ramdisk = @import("./ramdisk.zig");
const task = @import("./task.zig");
const schedular = @import("./schedular.zig");
const paging = @import("./paging.zig");
const lib = @import("./lib.zig");

comptime {
    _ = lib;
}

pub const os = @import("./os.zig");

const apic = @import("./lapic.zig");
const ioapic = @import("./ioapic.zig");

pub export const _kernel_export_lib: usize = 0;

export fn kernel_start(params: *const config.KernelParams) callconv(.C) noreturn {
    kernel_main(params) catch log.panic("Kernel Panic", .{}, @src());

    while (true) {}
}

var RAMDISK: [1024 * 1024]u8 align(8) = undefined;
var RAMDISK_LEN: usize = undefined;

fn ramdisk_code() []align(8) const u8 {
    return RAMDISK[0..RAMDISK_LEN];
}

fn kernel_main(params: *const config.KernelParams) !noreturn {
   @memcpy(RAMDISK[0..params.ramdisk.len], params.ramdisk);
    RAMDISK_LEN = params.ramdisk.len;

    gdt.init_gdt();
    irq.init_idt();

    log.set_kernel();
    devices.init_default();

    alloc.copyMemoryMap(params.memory_map, params.allocated); // We copy the memory map so that we can eventually (safely) unmap the bootloader pages
    alloc.printMemoryMap();

    log.info("Starting kernel...", .{}, @src());

    const stats = alloc.MemoryStats.collect();
    stats.print();

    const cpu_features = regs.CpuFeatures.get();

    const xsdt = params.xsdt;
    const madt_opt = xsdt.madt();

    if (madt_opt == null) {
        log.panic("MADT not found in XSDT", .{}, @src());
    }
    var arena = std.heap.ArenaAllocator.init(alloc.virtual_page_allocator);
    var allocator = arena.allocator();

    {
        // Set fresh paging table

        const address_space: *paging.PageTable = &(try allocator.alignedAlloc(paging.PageTable, 4096, 1))[0];

        const physAddr = switch (paging.translateToPhysical(@intFromPtr(address_space))) {
            .success => |addr| addr,
            else => log.panic("Unable to translate physical address", .{}, @src()),
        };

        address_space.* = .{};

        address_space.setRecursiveEntryOn();
        paging.remapKernel(paging.getPageTable(), address_space);
        paging.PageTable.loadPhysical(physAddr);
    }

    try acpi.init();

    const madt = madt_opt.?;
    // var ev_mgr = events.EventManager{ .madt = madt };
    events.init(madt);
    var ev_mgr = events.instance();
    _ = ev_mgr;

    {
        var offset: usize = 0;
        while (offset < madt.len()) {
            const entry = madt.next_entry(offset);

            switch (entry) {
                .local_apic => {
                    if (cpu_features.apic) {
                        const addr = try allocator.allocWithOptions(u8, 4096, 4096, null);

                        const physical = switch (paging.translateToPhysical(@intFromPtr(addr.ptr))) {
                            .success => |addrr| addrr,
                            else => log.panic("Unable to translate physical address", .{}, @src()),
                        };

                        _ = paging.unmapPage(@intFromPtr(addr.ptr));
                        _ = paging.mapPage(apic.DEFAULT_BASE, @intFromPtr(addr.ptr), .{ .writable = true });

                        log.info("APIC: 0x{x} -> 0x{x}", .{ @intFromPtr(addr.ptr), physical }, @src());

                        _ = apic.init(physical, @intFromPtr(addr.ptr));
                        apic.setDefaultConfig();
                    } else {
                        log.warn("APIC initialization skipped: CPU doesn't support it", .{}, @src());
                    }
                },
                else => {
                    log.info("{}", .{entry}, @src());
                },
            }

            offset += entry.len();
        }
    }

    // _ = ev_mgr.register_listener(1, handlerpoo) catch log.panic("Unable to register listener", .{}, @src());
    // while (true) {}

    schedular.init();

    const rd = ramdisk.RamDisk.fromBuffer(ramdisk_code());
    const driver_config = rd.searchFile("driver_config");

    if (driver_config) |dconfig| {
        var config_stream = std.io.FixedBufferStream([]const u8){ .buffer = dconfig.data, .pos = 0 };
        _ = config_stream;

        var lines = std.mem.splitSequence(u8, dconfig.data, "\n");
        while (lines.next()) |line| {
            const stripped_line = std.mem.trim(u8, line, "\n\r ");
            if (stripped_line.len <= 0) {
                continue;
            }

            const driver_file = rd.searchFile(stripped_line) orelse {
                log.warn("Driver \"{s}\" not found", .{stripped_line}, @src());
                continue;
            };

            const driver_task = task.Task.load_driver(driver_file.data) catch {
                log.warn("Error loading driver \"{s}\". Skipping", .{stripped_line}, @src());
                continue;
            };

            schedular.schedular.addTask(driver_task);

            log.info("Loaded driver \"{s}\"", .{stripped_line}, @src());
        }

        // task.Task.load_driver(dconfig.data) catch log.panic("Unable to ", args: anytype, src: std.builtin.SourceLocation);
    } else {
        log.warn("Driver Config file not found in ramdisk", .{}, @src());
    }

    regs.sti();

    schedular.schedular.resetCurrent();

    while (true) {}
}

fn handlerpoo() bool {
    _ = regs.in(0x60, u8);
    return true;
}
