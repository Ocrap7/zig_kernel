const std = @import("std");
const rd = @import("../src/ramdisk.zig");
const RamDisk = @This();

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
) *RamDisk {
    const self = owner.allocator.create(RamDisk) catch @panic("OOM");
    self.* = RamDisk{
        .step = Step.init(.{
            .id = base_id,
            .name = "ramdisk",
            .owner = owner,
            .makeFn = make,
        }),
        .basename = options.basename orelse "ramdisk",
        .output_file = std.Build.GeneratedFile{ .step = &self.step },
    };
    return self;
}

pub fn getOutput(self: *const RamDisk) std.Build.LazyPath {
    return .{ .generated = &self.output_file };
}

fn make(step: *Step, prog_node: *std.Progress.Node) !void {
    const b = step.owner;
    const self = @fieldParentPtr(RamDisk, "step", step);

    var files = try std.ArrayList(rd.File).initCapacity(b.allocator, step.dependencies.items.len);

    defer {
        for (files.items) |fd| {
            b.allocator.free(fd.data);
        }
    }

    // Read all of the driver files into the buffer
    for (step.dependencies.items) |dep| {
        try dep.make(prog_node);

        // std.debug.print("{s}", .{dep.cast(std.build.Step.WriteFile).?.files.items[0].sub_path});
        const name = if (dep.cast(std.build.Step.WriteFile)) |wf|
            std.fs.path.basename(wf.files.items[0].sub_path)
        else if (dep.cast(std.build.Step.InstallFile)) |install_file| std.fs.path.stem(install_file.dest_rel_path) else {
            @panic("Unsupported dependency step");
        };

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

        // std.debug.print("{} {s}\n", .{ install_file.dir, full_path });

        var file = try std.fs.cwd().openFile(full_path, .{});
        var bytes = try file.readToEndAlloc(b.allocator, std.math.maxInt(u32));

        errdefer {
            b.allocator.free(bytes);
        }

        try files.append(rd.File{ .data = bytes, .name = name });
    }

    var man = b.cache.obtain();
    defer man.deinit();

    // Random bytes to make RamDisk unique.
    man.hash.add(@as(u32, 0x33c7fda9));
    // For now we always rebuild
    _ = try step.cacheHit(&man);

    const digest = man.final();
    const cache_path = "o" ++ std.fs.path.sep_str ++ digest;

    const full_dest_path = try b.cache_root.join(b.allocator, &.{ cache_path, self.basename });
    self.output_file.path = full_dest_path;
    b.cache_root.handle.makePath(cache_path) catch |err| {
        return step.fail("unable to make path {s}: {s}", .{ cache_path, @errorName(err) });
    };

    // Create the ramdisk and output to the dest file
    const buffer = try rd.RamDisk.createFromFiles(files.items, b.allocator);
    defer {
        buffer.deinit();
    }

    var file = try std.fs.cwd().createFile(full_dest_path, .{});
    try file.writeAll(buffer.items);
}
