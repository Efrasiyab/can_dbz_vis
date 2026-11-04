const std = @import("std");

const StressRing = Spsc(u64, 1024);
const stress_item_count = 1_000_000;

pub fn Spsc(comptime T: type, comptime capacity: usize) type {
    if (capacity == 0 or (capacity & (capacity - 1)) != 0) {
        @compileError("SPSC capacity must be a non-zero power of two");
    }

    return struct {
        const Self = @This();

        slots: [capacity]T = undefined,
        write_index: std.atomic.Value(usize) align(64) = .init(0),
        read_index: std.atomic.Value(usize) align(64) = .init(0),
        dropped: std.atomic.Value(u64) = .init(0),

        pub fn push(self: *Self, value: T) bool {
            const write_index = self.write_index.load(.monotonic);
            const read_index = self.read_index.load(.acquire);
            if (write_index -% read_index >= capacity) {
                _ = self.dropped.fetchAdd(1, .monotonic);
                return false;
            }

            self.slots[write_index & (capacity - 1)] = value;
            self.write_index.store(write_index +% 1, .release);
            return true;
        }

        pub fn pop(self: *Self) ?T {
            const read_index = self.read_index.load(.monotonic);
            const write_index = self.write_index.load(.acquire);
            if (read_index == write_index) return null;

            const value = self.slots[read_index & (capacity - 1)];
            self.read_index.store(read_index +% 1, .release);
            return value;
        }

        pub fn pushMany(self: *Self, values: []const T) usize {
            var pushed: usize = 0;
            for (values) |value| {
                if (!self.push(value)) break;
                pushed += 1;
            }
            return pushed;
        }

        pub fn popMany(self: *Self, values: []T) usize {
            var popped: usize = 0;
            while (popped < values.len) : (popped += 1) {
                const value = self.pop() orelse break;
                values[popped] = value;
            }
            return popped;
        }

        pub fn lenApprox(self: *const Self) usize {
            const write_index = self.write_index.load(.acquire);
            const read_index = self.read_index.load(.acquire);
            return write_index -% read_index;
        }

        pub fn droppedCount(self: *const Self) u64 {
            return self.dropped.load(.monotonic);
        }
    };
}

test "SPSC ring preserves order through wraparound and counts drops" {
    var ring: Spsc(u32, 4) = .{};

    for (0..4) |value| try std.testing.expect(ring.push(@intCast(value)));
    try std.testing.expect(!ring.push(4));
    try std.testing.expectEqual(@as(u64, 1), ring.droppedCount());

    for (0..4) |value| {
        try std.testing.expectEqual(@as(?u32, @intCast(value)), ring.pop());
    }
    try std.testing.expectEqual(@as(?u32, null), ring.pop());

    for (0..64) |value| {
        try std.testing.expect(ring.push(@intCast(value)));
        try std.testing.expectEqual(@as(?u32, @intCast(value)), ring.pop());
    }
}

test "SPSC batch operations preserve order" {
    var ring: Spsc(u32, 4) = .{};
    const input = [_]u32{ 10, 11, 12 };
    var output: [4]u32 = undefined;

    try std.testing.expectEqual(@as(usize, 3), ring.pushMany(&input));
    try std.testing.expectEqual(@as(usize, 3), ring.popMany(&output));
    try std.testing.expectEqualSlices(u32, &input, output[0..3]);
}

fn produceStressItems(ring: *StressRing) void {
    var value: u64 = 0;
    while (value < stress_item_count) {
        const available = 1024 - ring.lenApprox();
        if (available == 0) continue;

        const batch_len = @min(available, stress_item_count - value);
        for (0..batch_len) |_| {
            if (!ring.push(value)) unreachable;
            value += 1;
        }
    }
}

test "SPSC transfers one million items concurrently without loss or reordering" {
    var ring: StressRing = .{};
    const producer = try std.Thread.spawn(.{}, produceStressItems, .{&ring});

    var expected: u64 = 0;
    var ordered = true;
    while (expected < stress_item_count) {
        const value = ring.pop() orelse continue;
        if (value != expected) ordered = false;
        expected += 1;
    }
    producer.join();

    try std.testing.expect(ordered);
    try std.testing.expectEqual(@as(u64, 0), ring.droppedCount());
}
