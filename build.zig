const std = @import("std");
const CrossTarget = @import("std").zig.CrossTarget;
const Target = @import("std").Target;

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.build.Builder) void {
    
    const kernel_exe = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = .{ .path = "src/kernel.zig" },
        .target = .{
            .cpu_arch = .x86_64,
            .os_tag = .freestanding,
            .abi = .none,
        },
        .optimize = .Debug,
    });
    kernel_exe.linker_script = .{ .path = "link.ld" };
    kernel_exe.pie = false;
    kernel_exe.force_pic = false;
    kernel_exe.code_model = .medium;

    b.installArtifact(kernel_exe);
    
    // const objcopy_step = kernel_exe.addObjCopy(.{
    //     .format = .bin,
    // });
    // _ = objcopy_step;

    // const install_bin_step = b.addInstallBinFile(objcopy_step.getOutputSource(), b.fmt("{s}.gba", .{"kernel"}));
    // install_bin_step.step.dependOn(&objcopy_step.step);

    // b.default_step.dependOn(&install_bin_step.step);

    // std.debug.print("hello {s}\n", .{kernel_exe.getOutputSource().generated.path.?});

    const exe = b.addExecutable(.{
        .name = "bootx64",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = CrossTarget{
            .cpu_arch = Target.Cpu.Arch.x86_64,
            .os_tag = Target.Os.Tag.uefi,
            .abi = Target.Abi.none,
        },
        .optimize = .Debug,
    });
    b.verbose_llvm_ir = "out.ir";
    exe.dwarf_format = .@"64";
    exe.defineCMacro("KERNEL_CODE_PATH", "zig-out/bin/kernel");

    const run_step = std.build.RunStep.create(b, "uefi-run bootx64");
    run_step.addArgs(&.{ "uefi-run" });
    run_step.addArtifactArg(exe);
    run_step.addArgs(&.{ 
        "--", 
        "-D", "qemu.log",
        "-d", "int",
        "-s",
        // "-debugcon", "file:uefi_debug.log", "-global", "isa-debugcon.iobase=0x402",
        // "-drive", "if=pflash,format=raw,readonly=on,file=/usr/share/edk2-ovmf/x64/OVMF_CODE.fd",
        "-drive", "if=pflash,format=raw,readonly=on,file=ovmf-x64/OVMF_CODE-pure-efi.fd",
        // "-drive if=pflash,format=raw,file=/usr/share/edk2-ovmf/x64/OVMF_VARS.fd",
        "-machine", "q35",
        "-no-reboot",
        "-m", "1024M",
        // "-serial", "stdio",
        "-monitor", "tcp:127.0.0.1:55555,server,nowait",
        "--nographic",
    });

    b.installArtifact(exe);

    exe.step.dependOn(&kernel_exe.step);
    b.default_step.dependOn(&exe.step);

    const step = b.step("run", "Runs the executable");
    step.dependOn(&run_step.step);
}
