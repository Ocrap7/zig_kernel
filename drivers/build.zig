const std = @import("std");
const RamDisk = @import("../RamDisk.zig");

const drivers = [_][]const u8{
    "block/ich9-ahci",
    "block/ps2",
};

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build, rd: *RamDisk) void {
    const driver_target = .{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    };

    const kernel_module = b.createModule(.{
        .source_file = .{ .path = thisDir() ++ "/../src/lib.zig" },
    });

    const depend = std.build.ModuleDependency{
        .name = "kernel",
        .module = kernel_module,
    };

    const driver_module = b.createModule(.{
        .source_file = .{ .path = thisDir() ++ "/src/lib.zig" },
        .dependencies = &.{depend},
    });

    {
        // Add the driver config file which tells the kernel which files to load as drivers
        var buffer = std.ArrayList(u8).initCapacity(b.allocator, drivers.len * 16) catch @panic("Unable to allocate array!");
        for (drivers) |driver| {
            buffer.appendSlice(std.fs.path.basename(driver)) catch @panic("Error");
            buffer.append('\n') catch @panic("Erorr");
        }

        const driver_path = b.pathJoin(&.{ b.install_path, "driver_config" });
        const driver_config = b.addWriteFile(driver_path, buffer.items);

        rd.step.dependOn(&driver_config.step);
    }

    for (drivers) |driver| {
        const path = b.fmt("{s}/{s}/src/main.zig", .{ thisDir(), driver });

        const driver_lib = b.addExecutable(.{
            .name = std.fs.path.stem(driver),
            .root_source_file = .{ .path = path },
            .target = driver_target,
            .optimize = .Debug,
        });
        driver_lib.pie = false;
        driver_lib.force_pic = false;

        driver_lib.code_model = .large;
        driver_lib.entry_symbol_name = "driver_main_stub";
        driver_lib.linker_script = .{ .path = thisDir() ++ "/driver.ld" };

        driver_lib.addObjectFile(.{ .path = "zig-out/kernel-symbols.o" });

        driver_lib.addModule("driver", driver_module);
        driver_lib.addModule("kernel", kernel_module);

        const objcopy_step = driver_lib.addObjCopy(.{ .basename = driver_lib.name });
        const install_driver = b.addInstallLibFile(objcopy_step.getOutput(), b.fmt("drivers/{s}", .{driver_lib.name}));
        install_driver.step.dependOn(&objcopy_step.step);

        rd.step.dependOn(&install_driver.step);
    }

    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = thisDir() ++ "src/lib.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_main_tests = b.addRunArtifact(main_tests);

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build test`
    // This will evaluate the `test` step rather than the default, which is "install".
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);
}

pub inline fn thisDir() []const u8 {
    return comptime std.fs.path.dirname(@src().file) orelse ".";
}
