const std = @import("std");
const CrossTarget = @import("std").zig.CrossTarget;
const Target = @import("std").Target;

pub fn build(b: *std.build.Builder) void {
    const exe = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = .{ .path = "src/kernel.zig" },
        .target = .{
            .cpu_arch = .x86_64,
            .os_tag = .freestanding,
            .abi = .none,
        },
        .optimize = .Debug,
    });
    exe.linker_script = .{ .path = "link.ld" };
    exe.pie = false;
    exe.force_pic = false;
    exe.code_model = .medium;

    // the bootloader will setup basic functionality and depends on the kernel image
    const bootloader = b.addExecutable(.{
        .name = "bootx64",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = CrossTarget{
            .cpu_arch = Target.Cpu.Arch.x86_64,
            .os_tag = Target.Os.Tag.uefi,
            .abi = Target.Abi.msvc,
        },
        .optimize = .Debug,
    });
    bootloader.strip = false;
    bootloader.addAnonymousModule("kernel", .{ .source_file = exe.getOutputSource() });

    b.installArtifact(bootloader);

    const run_step = std.build.RunStep.create(b, "uefi-run bootx64");
    run_step.addArgs(&.{"uefi-run"});
    run_step.addArtifactArg(bootloader);
    run_step.addArgs(&.{
        "-d",
        "--",

        // Debug logging
        "-D", "qemu.log",
        "-d", "int", 

        // Firmware
        "-drive", "if=pflash,format=raw,readonly=on,file=ovmf-x64/OVMF_CODE-pure-efi.fd",

        // System specs
        "-machine", "q35",
        "-m", "1024M",

        "-no-reboot",

        // Monitoring/debugging
        "-s",
        // "-serial", "stdio",
        "-monitor",
        // "-serial",
        "tcp:127.0.0.1:55555,server,nowait",
        "--nographic",
    });

    const step = b.step("run", "Runs the executable");
    step.dependOn(&run_step.step);
}
