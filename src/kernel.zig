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

pub const os = @import("./os.zig");

const apic = @import("./lapic.zig");
const ioapic = @import("./ioapic.zig");

const RAMDISK_CONTENT_RAW = @embedFile("ramdisk");

/// this is a workaround to align the code on a page boundry.
/// TODO: once embedfile is able to align, use that directly
/// as this creates two copies of the data in memory
fn ramdisk_content() type {
    return struct { code: [RAMDISK_CONTENT_RAW.len:0]u8 align(@alignOf(ramdisk.RamDisk)) };
}

const RAMDISK: ramdisk_content() = .{ .code = RAMDISK_CONTENT_RAW.* };

export fn kernel_start(params: *const config.KernelParams) callconv(.C) void {
    gdt.init_gdt();
    irq.init_idt();

    log.set_kernel();
    devices.init_default();

    alloc.copyMemoryMap(params.memory_map, params.allocated); // We copy the memory map so that we can eventually (safely) unmap the bootloader pages
    alloc.printMemoryMap();

    const stats = alloc.MemoryStats.collect();
    stats.print();

    log.info("kernel", .{}, @src());

    const cpu_features = regs.CpuFeatures.get();

    const xsdt = params.xsdt;
    const madt_opt = xsdt.madt();

    if (madt_opt == null) {
        log.panic("MADT not found in XSDT", .{}, @src());
    }

    const madt = madt_opt.?;
    var ev_mgr = events.EventManager{ .madt = madt };

    {
        var offset: usize = 0;
        while (offset < madt.len()) {
            const entry = madt.next_entry(offset);

            switch (entry) {
                .local_apic => {
                    if (cpu_features.apic) {
                        _ = apic.init(apic.DEFAULT_BASE);
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

    _ = ev_mgr.register_listener(1, handlerpoo) catch log.panic("Unable to register listener", .{}, @src());

    const rd = ramdisk.RamDisk.fromBuffer(&RAMDISK.code);
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

            log.info("Loaded driver \"{s}\"", .{stripped_line}, @src());
            _ = driver_task;
        }

        // task.Task.load_driver(dconfig.data) catch log.panic("Unable to ", args: anytype, src: std.builtin.SourceLocation);
    } else {
        log.warn("Driver Config file not found in ramdisk", .{}, @src());
    }

    regs.sti();

    while (true) {}
}

fn handlerpoo() bool {
    _ = regs.in(0x60, u8);
    return true;
}
