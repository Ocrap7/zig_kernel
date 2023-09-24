//! This is the core task schedular of the system. A task is switched at a regular interval, provided by the LAPIC timer.
//!
//! Each task has a current status. See `task.Status` and a task is scheduled according to this status.
//!
const std = @import("std");
const tasks = @import("./task.zig");
const log = @import("./logger.zig");
const regs = @import("./registers.zig");
const lapic = @import("./lapic.zig");
const irq = @import("./irq.zig");
const alloc = @import("./allocator.zig");

var schedular: ?Schedular = null;

/// The process list type
pub const List = std.SinglyLinkedList(tasks.Task);

pub const Schedular = struct {
    allocator: std.heap.GeneralPurposeAllocator(.{ .thread_safe = false, .safety = false, .stack_trace_frames = 0 }),
    /// The schedular owns the tasks
    processes: List,
    current_process: ?*List.Node,

    /// Run scheduling algorithm and update `self.current_process`.
    ///
    /// The saved state of the new process is written into `frame`
    pub fn schedule(self: *Schedular, frame: *irq.ISRFrame) void {
        if (self.current_process == null) return;

        self.current_process.?.data.saveCPUFromFrame(frame);

        var next_proc = self.next();

        while (true) {
            switch (next_proc.data.context.status) {
                .Ready, .Running => break,
                .Yielded, .Blocked => {
                    next_proc = next_proc.next orelse self.processes.first.?;
                },
            }
        }

        self.current_process = next_proc;

        self.current_process.?.data.context.address_space.load();
        self.current_process.?.data.loadCPUIntoFrame(frame);
    }

    /// Get's the next task, wrapping to the first task
    /// Expects `self.current process` to be not null
    pub fn next(self: *Schedular) *List.Node {
        if (self.current_process.?.next) |next_proc| {
            return next_proc;
        } else {
            return self.processes.first.?;
        }
    }

    /// Add a task to the schedular. `task` will be put onto the heap and inserted into the process list.
    pub fn addTask(self: *Schedular, task: tasks.Task) void {
        const node = self.allocator.allocator().create(List.Node) catch log.panic("Unable to allocate task!", .{}, @src());
        node.data = task;

        self.processes.prepend(node);
    }

    /// Jump to the current process. This should probably only be used when bootstrapping the schedular (only once).
    /// TODO: maybe we should just use an `iret` for this
    pub fn runCurrent(self: *Schedular) void {
        if (self.current_process) |proc| {
            const task = &proc.data;

            task.context.address_space.load();
            regs.jumpIP(@intFromPtr(task.entry), task.context.cpu_state.rsp + 8, 0);
        } else {
            log.warn("Tried running without a current process", .{}, @src());
        }
    }

    /// Set the current process to the first process in the process list and switch to it.
    /// This should probably only be used when bootstrapping the schedular (only once).
    pub fn resetCurrent(self: *Schedular) void {
        self.current_process = self.processes.first;

        self.runCurrent();
    }

    /// Cleanup the schedular. All the tasks are destroyed.
    /// TODO: use arean allocator to unalloc everything at once
    pub fn deinit(self: Schedular) void {
        var it = self.processes.first;
        while (it) |node| : (it = node.next) {
            node.data.allocator.deinit();
            self.allocator.destroy(node);
        }
    }

    /// Interrupt callback for the LAPIC timer. Causes scheduling algorithm to run. See `Schedular.schedule`
    fn timer_handler(frame: *irq.ISRFrame) bool {
        schedular.?.schedule(frame);

        return true;
    }
};

pub fn instance() *Schedular {
    return &schedular.?;
}

pub fn is_init() bool {
    return inited;
}

var inited = false;

pub fn init() void {
    schedular = .{ .allocator = .{
        .backing_allocator = alloc.kernel_page_allocator,
    }, .processes = .{}, .current_process = null };

    irq.register_handler_callback(Schedular.timer_handler, lapic.instance().timer_vector);

    inited = true;
}
