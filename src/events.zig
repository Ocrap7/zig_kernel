const alloc = @import("./allocator.zig");
const paging = @import("./paging.zig");
const acpi = @import("./acpi/acpi.zig");
const ioapic = @import("./ioapic.zig");
const irq = @import("./irq.zig");
const std = @import("std");
const log = @import("./logger.zig");

const MAX_VECTORS: usize = 64;
const VECTOR_OFFSET: u8 = 0x30;

pub const EventError = error{
    NoIOApic,
    InvalidIrq,
};

var EVENT_MANAGER: EventManager = undefined;

pub fn init(madt: *const acpi.MADT) void {
    EVENT_MANAGER = .{ .madt = madt };
}

pub fn instance() *EventManager {
    return &EVENT_MANAGER;
}

/// Handles events with irqs
pub const EventManager = struct {
    /// The last vector count
    last_vector: u8 = 0,
    /// The next vector_index
    vector_index: u8 = 0,
    /// Keeps track of used idt vectors. Each element is the number of listeners attached for that vector.
    vectors: [MAX_VECTORS]u8 = [_]u8{0} ** MAX_VECTORS,
    /// Reference to madt for looking up ioapic info
    madt: *const acpi.MADT,

    /// Returns the next vector, filling in the lowest number of uses first
    ///
    /// 0: 1   <-- self.vector_index
    /// 1: 111
    /// 2: 1
    /// 3:     <-- returns this
    /// 4: 1
    /// 5: 1
    /// 6: 11
    fn next_vector(self: *EventManager) u8 {
        while (self.last_vector < self.vectors[self.vector_index]) : (self.last_vector += 1) {
            var i: u8 = self.vector_index;
            while (i < MAX_VECTORS and self.vectors[i] >= self.last_vector) : (i += 1) {
                if (self.vectors[i] == self.last_vector) {
                    self.vector_index = @truncate(@mod(i + 1, MAX_VECTORS));

                    return i;
                }
            }
        }

        const index = self.vector_index;
        self.vector_index = @truncate(@mod(self.vector_index + 1, MAX_VECTORS));

        return index;
    }

    /// Register callaback `listener` on the specified irq pin.
    /// An idt vector is allocated and returned from the function.
    /// This vector is then set in the ioapic that contains the irq and enabled
    /// 
    /// The vector is returned on success
    pub fn register_listener(self: *EventManager, irq_pin: u16, listener: irq.IRQHandler) EventError!u8 {
        var offset: usize = 0;
        var found_ioapic = false;

        while (offset < self.madt.len()) {
            const entry = self.madt.next_entry(offset);

            switch (entry) {
                .io_apic => |value| {
                    found_ioapic = true;

                    const virtualPage = alloc.allocVirtualPage();
                    switch (paging.mapPage(@as(usize, value.io_apic_address), @intFromPtr(virtualPage), .{ .writable = true })) {
                        .success => {},
                        else => |err| log.panic("Unable to map ioapic region {}", .{err}, @src()),
                    }

                    var io = ioapic.get(@intFromPtr(virtualPage));
                    const info = io.info();

                    if (irq_pin < value.gsi_base or irq_pin >= value.gsi_base + info.max_entries) {
                        continue;
                    }

                    // We get a free vector, enable the redirection entry in ioapic, and add the listener to the idt.
                    const vector = self.next_vector();

                    io.enable_vector(vector + VECTOR_OFFSET, @truncate(irq_pin - value.gsi_base));
                    irq.register_handler(listener, vector + VECTOR_OFFSET, irq_pin);

                    return vector;
                },
                else => {},
            }

            offset += entry.len();
        }

        return if (found_ioapic) error.NoIOApic else error.InvalidIrq;
    }
};

const testing = @import("std").testing;

test "next linear vector" {
    var ev_mgr = EventManager{ .madt = @ptrFromInt(0x555500) };

    try testing.expectEqual(ev_mgr.next_vector(), 0);
    try testing.expectEqual(ev_mgr.next_vector(), 1);
    try testing.expectEqual(ev_mgr.next_vector(), 2);
    try testing.expectEqual(ev_mgr.next_vector(), 3);
}

test "next linear wrapping vector" {
    var ev_mgr = EventManager{ .madt = @ptrFromInt(0x555500) };

    for (0..MAX_VECTORS) |i| {
        try testing.expectEqual(ev_mgr.next_vector(), @as(u8, @truncate(i)));
    }

    for (0..MAX_VECTORS) |i| {
        try testing.expectEqual(ev_mgr.next_vector(), @as(u8, @truncate(i)));
    }
}

test "next vector some filled" {
    var ev_mgr = EventManager{ .madt = @ptrFromInt(0x555500) };

    ev_mgr.vectors[2] = 4;
    ev_mgr.vectors[4] = 1;
    ev_mgr.vectors[6] = 4;
    ev_mgr.vectors[7] = 3;
    ev_mgr.vectors[8] = 2;
    ev_mgr.vectors[9] = 1;

    try testing.expectEqual(ev_mgr.next_vector(), 0);
    try testing.expectEqual(ev_mgr.next_vector(), 1);
    try testing.expectEqual(ev_mgr.next_vector(), 3);
    try testing.expectEqual(ev_mgr.next_vector(), 5);
    try testing.expectEqual(ev_mgr.next_vector(), 10);
}
