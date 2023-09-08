const std = @import("std");
// const rd = @import("./src/ramdisk.zig");
const CodeStrip = @This();

const Step = std.Build.Step;

pub const base_id: Step.Id = .custom;

step: Step,
basename: []const u8,
output_file: std.Build.GeneratedFile,

pub const Options = struct {
    basename: ?[]const u8 = null,
};

pub fn create(
    owner: *std.Build,
    options: Options,
) *CodeStrip {
    const self = owner.allocator.create(CodeStrip) catch @panic("OOM");
    self.* = CodeStrip{
        .step = Step.init(.{
            .id = base_id,
            .name = "code-strip",
            .owner = owner,
            .makeFn = make,
        }),
        .basename = options.basename orelse "code-strip",
        .output_file = std.Build.GeneratedFile{ .step = &self.step },
    };
    return self;
}

pub fn getOutput(self: *const CodeStrip) std.Build.LazyPath {
    return .{ .generated = &self.output_file };
}

fn make(step: *Step, prog_node: *std.Progress.Node) !void {
    const b = step.owner;
    const self = @fieldParentPtr(CodeStrip, "step", step);

    var file: ?[] const u8 = null; 

    // Read first file path
    for (step.dependencies.items) |dep| {
        try dep.make(prog_node);

        const full_path = if (dep.cast(std.build.Step.WriteFile)) |wf|
            wf.files.items[0].sub_path
        else if (dep.cast(std.build.Step.InstallFile)) |install_file|
            switch (install_file.dir) {
                .lib => step.owner.pathJoin(&[_][]const u8{ step.owner.lib_dir, install_file.dest_rel_path }),
                .bin => step.owner.pathJoin(&[_][]const u8{ step.owner.exe_dir, install_file.dest_rel_path }),
                .header => step.owner.pathJoin(&[_][]const u8{ step.owner.h_dir, install_file.dest_rel_path }),
                .prefix => step.owner.pathJoin(&[_][]const u8{ step.owner.install_prefix, install_file.dest_rel_path }),
                .custom => |dir| step.owner.pathJoin(&[_][]const u8{ dir, install_file.dest_rel_path }),
            }
        else {
            @panic("Unsupported dependency step");
        };


        file = full_path;

        break;
    }

    var man = b.cache.obtain();
    defer man.deinit();

    // Random bytes to make RamDisk unique.
    man.hash.add(@as(u32, 0x21C7A2A0));
    // For now we always rebuild
    _ = try step.cacheHit(&man);

    const digest = man.final();
    const cache_path = "o" ++ std.fs.path.sep_str ++ digest;

    const full_dest_path = try b.cache_root.join(b.allocator, &.{ cache_path, self.basename });
    self.output_file.path = full_dest_path;
    b.cache_root.handle.makePath(cache_path) catch |err| {
        return step.fail("unable to make path {s}: {s}", .{ cache_path, @errorName(err) });
    };

    _ = try step.evalZigProcess(&.{
        b.zig_exe, "ld.lld",
        "-r",
        b.fmt("--just-symbols={s}", .{file.?}),
        "-o", full_dest_path,
    }, prog_node);

    _ = try step.evalZigProcess(&.{
        // b.zig_exe, "ld.lld",
        "objcopy",
        // "-r",
        // b.fmt("--just-symbols={s}", .{file.?}),
        // "-o", full_dest_path,
        "-x",
        full_dest_path, full_dest_path,
    }, prog_node);
}
