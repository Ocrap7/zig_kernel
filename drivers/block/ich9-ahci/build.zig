const std = @import("std");

pub fn package(b: *std.Build) void {
    const driver_target = .{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    };

    const driver_module = b.createModule(.{
        .source_file = .{ .path = "drivers/src/lib.zig" },
    });

    const driver_lib = b.addSharedLibrary(.{
        .name = "ich9-ahci",
        .root_source_file = .{ .path = thisDir() ++ "/src/main.zig" },
        .target = driver_target,
        .optimize = .Debug,
    });

    driver_lib.addModule("driver", driver_module);

    b.installArtifact(driver_lib);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = thisDir() ++ "/src/main.zig" },
        .target = driver_target,
        .optimize = .Debug,
    });

    const run_main_tests = b.addRunArtifact(main_tests);

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build test`
    // This will evaluate the `test` step rather than the default, which is "install".
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);
}

pub fn build(b: *std.Build) void {
    _ = b;
}

pub inline fn thisDir() []const u8 {
    return comptime std.fs.path.dirname(@src().file) orelse ".";
}
