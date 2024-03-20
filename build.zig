const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "quartz",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = .{ .path = "src/main.zig" },
        .target = .{
            .cpu_arch = .aarch64,
            .os_tag = .freestanding,
            .ofmt = .elf,
        },
        .optimize = optimize,
    });

    exe.code_model = .large;
    exe.addCSourceFile(.{
        .file = .{ .path = "src/entry.s" },
        .flags = &[_][]const u8{},
    });
    exe.linker_script = .{ .path = "build/linker.ld" };
    b.enable_qemu = true;

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    var args = [_][]const u8{
        // "-d",
        // "-f",
        // "zig-out/ramdisk",
        // "--size",
        // "40",
        // // "-q", "../repos/qemu/build/x86_64-softmmu/qemu-system-x86_64",
        // "--",

        "-D",
        "qemu.log",
        "-d",
        "int",

        // System specs
        "-machine",
        "virt",
        "-cpu",
        "cortex-a72",
        "-m",
        "1024M",

        // "-device",
        // "virtio-mouse-pci",

        "-no-reboot",

        // Monitoring/debugging
        "-s",
        // "-S",
        // "-monitor",
        "-serial",
        "stdio",
        // "-monitor",
        // "tcp:127.0.0.1:55555,server,nowait",
        // "--nographic",
    };
    {
        const run_step = std.Build.RunStep.create(b, "qemu-system-aarch64");
        run_step.addArgs(&.{ "qemu-system-aarch64", "-kernel" });
        run_step.addArtifactArg(exe);

        run_step.addArgs(&args);
        const step = b.step("run", "Runs the executable");
        step.dependOn(&run_step.step);
    }

    {
        const run_step = std.Build.RunStep.create(b, "qemu-system-aarch64");
        run_step.addArgs(&.{ "qemu-system-aarch64", "-kernel" });
        run_step.addArtifactArg(exe);

        const debug_args = args ++ .{"-S"};
        run_step.addArgs(&debug_args);

        const step = b.step("debug", "Debugs the executable");
        step.dependOn(&run_step.step);
    }

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
