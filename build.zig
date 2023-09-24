const std = @import("std");
const CrossTarget = @import("std").zig.CrossTarget;
const Target = @import("std").Target;
const RamDisk = @import("./RamDisk.zig");
const CodeStrip = @import("./CodeStrip.zig");

const drivers = @import("./drivers/build.zig");
const ramdisk = @import("./src/ramdisk.zig");

pub fn build(b: *std.build.Builder) void {
    var ramdisk_step = RamDisk.create(b, .{});
    drivers.build(b, ramdisk_step);

    const install_ramdisk_step = b.addInstallFile(ramdisk_step.getOutput(), "ramdisk");
    install_ramdisk_step.step.dependOn(&ramdisk_step.step);

    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .Debug });


    const exe = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = .{ .path = "src/kernel.zig" },
        .target = .{
            .cpu_arch = .x86_64,
            .os_tag = .freestanding,
            .abi = .none,
        },
        .optimize = optimize,
    });
    exe.linker_script = .{ .path = "link.ld" };
    exe.pie = false;
    exe.force_pic = false;
    exe.code_model = .medium;

    {
        const objcopy_step = exe.addObjCopy(.{ .basename = "kernel" });
        const install_kernel_step = b.addInstallBinFile(objcopy_step.getOutput(), "kernel");
        install_kernel_step.step.dependOn(&objcopy_step.step);

        b.default_step.dependOn(&install_kernel_step.step);

        const code_strip_step = CodeStrip.create(b, .{ .program = "llvm-objcopy" });
        code_strip_step.step.dependOn(&install_kernel_step.step);

        const install_symbols = b.addInstallBinFile(code_strip_step.getOutput(), "../kernel-symbols.o");
        install_symbols.step.dependOn(&code_strip_step.step);

        b.default_step.dependOn(&install_symbols.step);
    }

    // the bootloader will setup basic functionality and depends on the kernel image
    const bootloader = b.addExecutable(.{
        .name = "bootx64",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = CrossTarget{
            .cpu_arch = Target.Cpu.Arch.x86_64,
            .os_tag = Target.Os.Tag.uefi,
            .abi = Target.Abi.msvc,
        },
        .optimize = optimize,
    });
    bootloader.strip = false;
    bootloader.addAnonymousModule("kernel", .{ .source_file = exe.getOutputSource() });

    b.installArtifact(bootloader);

    var args = [_][]const u8{
        "-d",
        "-f",
        "zig-out/ramdisk",
        "--size",
        "40",
        // "-q", "../repos/qemu/build/x86_64-softmmu/qemu-system-x86_64",
        "--",

        // Debug logging
        "-D",
        "qemu.log",
        "-d",
        "int",

        // Firmware
        "-drive",
        "if=pflash,format=raw,readonly=on,file=ovmf-x64/OVMF_CODE-pure-efi.fd",

        // System specs
        "-machine",
        "q35",
        "-m",
        "1024M",

        // "-device",
        // "virtio-mouse-pci",

        "-no-reboot",

        // Monitoring/debugging
        "-s",
        // "-S",
        "-serial",
        "stdio",
        "-monitor",
        // "-serial",
        "tcp:127.0.0.1:55555,server,nowait",
        // "--nographic",
    };

    {
        const step = b.step("ramdisk", "Build ramdisk");
        step.dependOn(&install_ramdisk_step.step);
    }

    {
        const step = b.step("kernel", "Build ramdisk");
        step.dependOn(&exe.step);

        b.verbose_llvm_ir = "out.ll";
    }

    {
        const run_step = std.build.RunStep.create(b, "uefi-run bootx64");
        run_step.addArgs(&.{"uefi-run"});
        run_step.addArtifactArg(bootloader);

        run_step.addArgs(&args);
        const step = b.step("run", "Runs the executable");
        step.dependOn(&run_step.step);
    }

    {
        const run_step = std.build.RunStep.create(b, "uefi-run bootx64");
        run_step.addArgs(&.{"uefi-run"});
        run_step.addArtifactArg(bootloader);

        const debug_args = args ++ .{"-S"};
        run_step.addArgs(&debug_args);

        const step = b.step("debug", "Runs the executable");
        step.dependOn(&run_step.step);
    }
}

fn generate_symbols(b: *std.build.Builder, step: *std.build.Step, src: []const u8, dst: []const u8) !void {
    var argv = std.ArrayList([]const u8).init(b.allocator);
    try argv.appendSlice(&.{"objcopy"});
    // try argv.appendSlice(&.{ "-O", "lib" });
    try argv.appendSlice(&.{ "-j", ".text" });
    try argv.appendSlice(&.{"-x"});
    try argv.appendSlice(&.{"--extract-symbol"});

    try argv.appendSlice(&.{ src, dst });

    _ = try step.evalChildProcess(argv.items);
}
