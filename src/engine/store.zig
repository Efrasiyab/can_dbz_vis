const std = @import("std");
const Frame = @import("../can/frame.zig").Frame;

pub const max_snapshot_rows = 256;
pub const max_snapshot_trace = 128;
pub const max_message_table_entries = 2048;

pub const TxStatus = enum {
    ok,
    queue_full,
    bus_off,
    driver_error,
};

pub const TxEvent = struct {
    frame: Frame = undefined,
    status: TxStatus = .driver_error,
    job_id: u16 = 0,
    timestamp_ns: u64 = 0,
};

pub const TxEventQueue = @import("../sync/spsc.zig").Spsc(TxEvent, 1024);

pub const MessageRow = struct {
    frame: Frame = undefined,
    count: u64 = 0,
    cycle_min_ns: u64 = 0,
    cycle_max_ns: u64 = 0,
    cycle_avg_ns: u64 = 0,
    cycle_sum_ns: u128 = 0,
    cycle_samples: u64 = 0,
    changed_bytes: u64 = 0,
};

pub const Snapshot = struct {
    rows: [max_snapshot_rows]MessageRow = @splat(.{}),
    trace: [max_snapshot_trace]Frame = undefined,
    sent: [max_snapshot_trace]TxEvent = undefined,
    row_count: u16 = 0,
    trace_len: u16 = 0,
    sent_count: u16 = 0,
    frames_total: u64 = 0,
    tx_frames_total: u64 = 0,
    dropped: u64 = 0,
    generation: u64 = 0,
};

pub fn MessageTable(comptime capacity: usize, comptime trace_capacity: usize) type {
    if (capacity == 0 or (capacity & (capacity - 1)) != 0) {
        @compileError("message table capacity must be a non-zero power of two");
    }
    if (trace_capacity == 0 or (trace_capacity & (trace_capacity - 1)) != 0) {
        @compileError("trace capacity must be a non-zero power of two");
    }

    return struct {
        const Self = @This();

        const Entry = struct {
            used: bool = false,
            bus: u8 = 0,
            id: u32 = 0,
            extended: bool = false,
            latest: Frame = undefined,
            count: u64 = 0,
            cycle_min_ns: u64 = std.math.maxInt(u64),
            cycle_max_ns: u64 = 0,
            cycle_sum_ns: u128 = 0,
            cycle_samples: u64 = 0,
            changed_bytes: u64 = 0,
        };

        entries: [capacity]Entry = @splat(.{}),
        trace: [trace_capacity]Frame = undefined,
        trace_write: usize = 0,
        trace_len: usize = 0,
        frames_total: u64 = 0,
        dropped: u64 = 0,

        pub fn update(self: *Self, frame: Frame) bool {
            if (frame.len > 64) {
                self.dropped +%= 1;
                return false;
            }

            const entry = self.findOrInsert(frame) orelse {
                self.dropped +%= 1;
                return false;
            };
            if (entry.count != 0) {
                var changed: u64 = 0;
                const compare_len = @max(frame.len, entry.latest.len);
                for (0..compare_len) |index| {
                    if (frame.data[index] != entry.latest.data[index]) changed |= @as(u64, 1) << @intCast(index);
                }
                entry.changed_bytes = changed;

                if (frame.timestamp_ns >= entry.latest.timestamp_ns) {
                    const cycle = frame.timestamp_ns - entry.latest.timestamp_ns;
                    entry.cycle_min_ns = @min(entry.cycle_min_ns, cycle);
                    entry.cycle_max_ns = @max(entry.cycle_max_ns, cycle);
                    entry.cycle_sum_ns +|= cycle;
                    entry.cycle_samples +%= 1;
                }
            }

            entry.latest = frame;
            entry.count +%= 1;
            self.frames_total +%= 1;
            self.trace[self.trace_write & (trace_capacity - 1)] = frame;
            self.trace_write +%= 1;
            self.trace_len = @min(self.trace_len + 1, trace_capacity);
            return true;
        }

        pub fn publish(self: *const Self, snapshot: *Snapshot, generation: u64) void {
            snapshot.* = .{
                .frames_total = self.frames_total,
                .dropped = self.dropped,
                .generation = generation,
            };
            const count = self.copyRows(snapshot.rows[0..]);
            std.mem.sort(MessageRow, snapshot.rows[0..count], {}, lessThan);
            snapshot.row_count = @intCast(count);
            snapshot.trace_len = @intCast(self.copyTrace(&snapshot.trace));
        }

        pub fn copyRows(self: *const Self, output: []MessageRow) usize {
            var count: usize = 0;
            for (self.entries) |entry| {
                if (!entry.used or count == output.len) continue;
                output[count] = .{
                    .frame = entry.latest,
                    .count = entry.count,
                    .cycle_min_ns = if (entry.cycle_samples == 0) 0 else entry.cycle_min_ns,
                    .cycle_max_ns = entry.cycle_max_ns,
                    .cycle_avg_ns = if (entry.cycle_samples == 0)
                        0
                    else
                        @intCast(entry.cycle_sum_ns / entry.cycle_samples),
                    .cycle_sum_ns = entry.cycle_sum_ns,
                    .cycle_samples = entry.cycle_samples,
                    .changed_bytes = entry.changed_bytes,
                };
                count += 1;
            }
            return count;
        }

        pub fn restoreSnapshot(self: *Self, snapshot: *const Snapshot) void {
            self.restoreState(snapshot, snapshot.rows[0..snapshot.row_count]);
        }

        pub fn restoreState(self: *Self, snapshot: *const Snapshot, rows: []const MessageRow) void {
            self.* = .{};
            self.frames_total = snapshot.frames_total;
            self.dropped = snapshot.dropped;
            for (rows) |row| {
                const entry = self.findOrInsert(row.frame) orelse continue;
                entry.latest = row.frame;
                entry.count = row.count;
                entry.cycle_min_ns = if (row.cycle_samples == 0) std.math.maxInt(u64) else row.cycle_min_ns;
                entry.cycle_max_ns = row.cycle_max_ns;
                entry.cycle_sum_ns = row.cycle_sum_ns;
                entry.cycle_samples = row.cycle_samples;
                entry.changed_bytes = row.changed_bytes;
            }
            const trace_count = @min(snapshot.trace_len, trace_capacity);
            const first = snapshot.trace_len - trace_count;
            for (0..trace_count) |index| self.trace[index] = snapshot.trace[first + index];
            self.trace_write = trace_count;
            self.trace_len = trace_count;
        }

        pub fn copyTrace(self: *const Self, output: []Frame) usize {
            const count = @min(output.len, self.trace_len);
            const first = self.trace_write -% self.trace_len;
            for (0..count) |index| {
                output[index] = self.trace[(first + index) & (trace_capacity - 1)];
            }
            return count;
        }

        fn findOrInsert(self: *Self, frame: Frame) ?*Entry {
            const start = hashKey(frame.bus, frame.id, frame.flags.extended) & (capacity - 1);
            for (0..capacity) |offset| {
                const entry = &self.entries[(start + offset) & (capacity - 1)];
                if (!entry.used) {
                    entry.* = .{
                        .used = true,
                        .bus = frame.bus,
                        .id = frame.id,
                        .extended = frame.flags.extended,
                    };
                    return entry;
                }
                if (entry.bus == frame.bus and entry.id == frame.id and entry.extended == frame.flags.extended) {
                    return entry;
                }
            }
            return null;
        }
    };
}

fn hashKey(bus: u8, id: u32, extended: bool) usize {
    var value = @as(u64, id) *% 0x9e3779b185ebca87;
    value ^= @as(u64, bus) << 32;
    value ^= if (extended) 0xd6e8feb86659fd93 else 0;
    value ^= value >> 29;
    return @truncate(value);
}

fn lessThan(_: void, left: MessageRow, right: MessageRow) bool {
    if (left.frame.bus != right.frame.bus) return left.frame.bus < right.frame.bus;
    if (left.frame.id != right.frame.id) return left.frame.id < right.frame.id;
    return !left.frame.flags.extended and right.frame.flags.extended;
}

test "message table aggregates stats and publishes rows sorted by bus and ID" {
    const Table = MessageTable(8, 4);
    var table: Table = .{};
    try std.testing.expect(table.update(testFrame(1, 0x200, false, 100, 1)));
    try std.testing.expect(table.update(testFrame(0, 0x300, false, 100, 2)));
    try std.testing.expect(table.update(testFrame(1, 0x100, true, 100, 3)));
    try std.testing.expect(table.update(testFrame(1, 0x200, false, 110, 2)));
    try std.testing.expect(table.update(testFrame(1, 0x200, false, 130, 3)));

    var snapshot: Snapshot = .{};
    table.publish(&snapshot, 7);
    try std.testing.expectEqual(@as(u16, 3), snapshot.row_count);
    try std.testing.expectEqual(@as(u8, 0), snapshot.rows[0].frame.bus);
    try std.testing.expectEqual(@as(u32, 0x100), snapshot.rows[1].frame.id);
    try std.testing.expectEqual(@as(u32, 0x200), snapshot.rows[2].frame.id);
    try std.testing.expectEqual(@as(u64, 3), snapshot.rows[2].count);
    try std.testing.expectEqual(@as(u64, 10), snapshot.rows[2].cycle_min_ns);
    try std.testing.expectEqual(@as(u64, 20), snapshot.rows[2].cycle_max_ns);
    try std.testing.expectEqual(@as(u64, 15), snapshot.rows[2].cycle_avg_ns);
    try std.testing.expectEqual(@as(u64, 0b11), snapshot.rows[2].changed_bytes);
    try std.testing.expectEqual(@as(u64, 5), snapshot.frames_total);
    try std.testing.expectEqual(@as(u64, 7), snapshot.generation);
}

test "message table trace ring retains newest frames in order" {
    const Table = MessageTable(2, 4);
    var table: Table = .{};
    for (0..6) |index| try std.testing.expect(table.update(testFrame(0, 1, false, index, @intCast(index))));

    var trace: [4]Frame = undefined;
    try std.testing.expectEqual(@as(usize, 4), table.copyTrace(&trace));
    for (0..4) |index| try std.testing.expectEqual(@as(u64, index + 2), trace[index].timestamp_ns);
}

test "message table snapshot restoration preserves cycle statistics" {
    const Table = MessageTable(8, 4);
    var original: Table = .{};
    try std.testing.expect(original.update(testFrame(0, 0x123, false, 100, 1)));
    try std.testing.expect(original.update(testFrame(0, 0x123, false, 110, 2)));
    var snapshot: Snapshot = .{};
    original.publish(&snapshot, 1);

    var restored: Table = .{};
    restored.restoreSnapshot(&snapshot);
    try std.testing.expect(restored.update(testFrame(0, 0x123, false, 130, 3)));
    var actual: Snapshot = .{};
    restored.publish(&actual, 2);

    try std.testing.expectEqual(@as(u64, 3), actual.rows[0].count);
    try std.testing.expectEqual(@as(u64, 10), actual.rows[0].cycle_min_ns);
    try std.testing.expectEqual(@as(u64, 20), actual.rows[0].cycle_max_ns);
    try std.testing.expectEqual(@as(u128, 30), actual.rows[0].cycle_sum_ns);
    try std.testing.expectEqual(@as(u64, 2), actual.rows[0].cycle_samples);
}

test "keyframe row export restores messages beyond the visible snapshot limit" {
    const Table = MessageTable(512, 4);
    var original: Table = .{};
    for (0..300) |id| {
        try std.testing.expect(original.update(testFrame(0, @intCast(id), false, id, @intCast(id % 255))));
    }
    var visible: Snapshot = .{};
    original.publish(&visible, 1);
    try std.testing.expectEqual(@as(u16, max_snapshot_rows), visible.row_count);

    var rows: [512]MessageRow = undefined;
    const row_count = original.copyRows(&rows);
    try std.testing.expectEqual(@as(usize, 300), row_count);
    var restored: Table = .{};
    restored.restoreState(&visible, rows[0..row_count]);
    var restored_rows: [512]MessageRow = undefined;
    try std.testing.expectEqual(@as(usize, 300), restored.copyRows(&restored_rows));
    try std.testing.expectEqual(@as(u64, 300), restored.frames_total);
}

fn testFrame(bus: u8, id: u32, extended: bool, timestamp_ns: u64, first_byte: u8) Frame {
    var frame = Frame{
        .timestamp_ns = timestamp_ns,
        .id = id,
        .bus = bus,
        .len = 2,
        .flags = .{ .extended = extended },
        ._pad = 0,
        .data = @splat(0),
    };
    frame.data[0] = first_byte;
    frame.data[1] = first_byte;
    return frame;
}
