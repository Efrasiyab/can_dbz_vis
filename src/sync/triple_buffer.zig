const std = @import("std");

const StressSnapshot = struct {
    sequence: u64,
    inverse: u64,
};
const StressBuffer = TripleBuffer(StressSnapshot);
const stress_item_count = 1_000_000;

pub fn TripleBuffer(comptime T: type) type {
    return struct {
        const Self = @This();
        const dirty_bit: u8 = 0b100;
        const index_mask: u8 = 0b011;

        slots: [3]T,
        middle: std.atomic.Value(u8),
        write_index: u8 = 2,
        read_index: u8 = 0,

        pub fn init(initial: T) Self {
            return .{
                .slots = .{ initial, initial, initial },
                .middle = .init(1),
            };
        }

        pub fn publish(self: *Self, value: T) void {
            self.slots[self.write_index] = value;
            const previous = self.middle.swap(self.write_index | dirty_bit, .acq_rel);
            self.write_index = previous & index_mask;
        }

        pub fn read(self: *Self) T {
            var state = self.middle.load(.acquire);
            while ((state & dirty_bit) != 0) {
                if (self.middle.cmpxchgStrong(state, self.read_index, .acq_rel, .acquire)) |observed| {
                    state = observed;
                } else {
                    self.read_index = state & index_mask;
                    break;
                }
            }
            return self.slots[self.read_index];
        }
    };
}

test "triple buffer returns the newest published value" {
    var buffer = TripleBuffer(u64).init(0);
    try std.testing.expectEqual(@as(u64, 0), buffer.read());

    for (1..10_001) |value| buffer.publish(value);
    try std.testing.expectEqual(@as(u64, 10_000), buffer.read());
}

test "triple buffer preserves coherent snapshots" {
    const Snapshot = struct {
        sequence: u64,
        inverse: u64,
    };

    var buffer = TripleBuffer(Snapshot).init(.{ .sequence = 0, .inverse = ~@as(u64, 0) });
    for (1..1024) |sequence| {
        buffer.publish(.{ .sequence = sequence, .inverse = ~@as(u64, sequence) });
        const snapshot = buffer.read();
        try std.testing.expectEqual(~snapshot.sequence, snapshot.inverse);
    }
}

fn publishStressSnapshots(buffer: *StressBuffer, finished: *std.atomic.Value(bool)) void {
    for (1..stress_item_count + 1) |sequence| {
        const value: u64 = @intCast(sequence);
        buffer.publish(.{ .sequence = value, .inverse = ~value });
    }
    finished.store(true, .release);
}

test "triple buffer does not tear concurrent snapshots" {
    var buffer = StressBuffer.init(.{ .sequence = 0, .inverse = ~@as(u64, 0) });
    var finished: std.atomic.Value(bool) = .init(false);
    const writer = try std.Thread.spawn(.{}, publishStressSnapshots, .{ &buffer, &finished });

    var coherent = true;
    var nondecreasing = true;
    var last_sequence: u64 = 0;
    while (!finished.load(.acquire)) {
        const snapshot = buffer.read();
        if (snapshot.inverse != ~snapshot.sequence) coherent = false;
        if (snapshot.sequence < last_sequence) nondecreasing = false;
        last_sequence = snapshot.sequence;
    }
    writer.join();

    const final = buffer.read();
    try std.testing.expect(coherent);
    try std.testing.expect(nondecreasing);
    try std.testing.expectEqual(@as(u64, stress_item_count), final.sequence);
    try std.testing.expectEqual(~final.sequence, final.inverse);
}
