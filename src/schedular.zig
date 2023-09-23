const std = @import("std");
const tasks = @import("./task.zig");
const log = @import("./logger.zig");
const regs = @import("./registers.zig");

pub var schedular: Schedular = undefined;

const List = std.SinglyLinkedList(tasks.Task);

pub const Schedular = struct {
    allocator: std.heap.GeneralPurposeAllocator(.{ .thread_safe = false, .safety = false, .stack_trace_frames = 0 }),
    /// The schedular owns the tasks
    processes: List,
    current_process: ?*List.Node,

    pub fn addTask(self: *Schedular, task: tasks.Task) void {
        log.warn("Add task", .{}, @src());
        const node = self.allocator.allocator().create(List.Node) catch log.panic("Unable to allocate task!", .{}, @src());
        node.data = task;

        self.processes.prepend(node);
    }

    pub fn resetCurrent(self: *Schedular) void {
        self.current_process = self.processes.first;

        if (self.current_process) |proc| {
            const task = &proc.data;

            task.address_space.load();
            regs.jumpIP(@intFromPtr(task.entry), task.context.rsp, 0);
        }
    }

    pub fn deinit(self: Schedular) void {
        var it = self.processes.first;
        while (it) |node| : (it = node.next) {
            node.data.allocator.deinit();
            self.allocator.destroy(node);
        }
    }
};

pub fn init() void {
    log.warn("Scheldul", .{}, @src());

    schedular = .{ .allocator = .{}, .processes = .{}, .current_process = null };
    log.warn("Scheldul fjldkfj", .{}, @src());
}
