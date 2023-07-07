const std = @import("std");
const CrossTarget = @import("std").zig.CrossTarget;
const Target = @import("std").Target;

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.build.Builder) void {
    const exe = b.addExecutable(.{
        .name = "bootx64",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = CrossTarget{
            .cpu_arch = Target.Cpu.Arch.x86_64,
            .os_tag = Target.Os.Tag.uefi,
            .abi = Target.Abi.msvc,
        },
        .optimize = .ReleaseSafe,
    });
    exe.output_dirname_source = .{ .step = &exe.step, .path = "efi/boot" };

    const run_step = std.Build.RunStep.create(b, "uefi-run bootx64");
    run_step.addArgs(&.{ "uefi-run" });
    run_step.addArtifactArg(exe);
    run_step.addArgs(&.{ 
        "--", 
        "-machine", "q35",
        "-no-reboot",
        "-m", "1024M",
        // "-serial", "stdio",
        "--nographic",
    });

    // exe.emit_analysis
    b.installArtifact(exe);
    b.default_step.dependOn(&exe.step);

    const step = b.step("run", "Runs the executable");
    step.dependOn(&run_step.step);
}
