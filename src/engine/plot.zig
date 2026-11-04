const std = @import("std");
const spsc = @import("../sync/spsc.zig");
const triple_buffer = @import("../sync/triple_buffer.zig");

pub const max_signals = 8;
pub const history_capacity = 200_000;
pub const max_chart_width = 256;
pub const max_decimated_points = max_chart_width * 2;
pub const sample_queue_capacity = 32_768;
const sample_batch_capacity = 512;

pub const Target = struct {
    bus_index: u8,
    message_handle: usize,
    signal_index: usize,
    id: u32,
    extended: bool,
};

pub const Selection = struct {
    targets: [max_signals]?Target = @splat(null),
    count: u8 = 0,
    generation: u64 = 0,
    view_generation: u64 = 0,
    window_ns: u64 = 10 * std.time.ns_per_s,
    scroll_offset_ns: u64 = 0,
    chart_width: u16 = 80,
};

const AtomicTarget = struct {
    bus_index: std.atomic.Value(u8) = .init(0),
    message_handle: std.atomic.Value(usize) = .init(0),
    signal_index: std.atomic.Value(usize) = .init(0),
    id: std.atomic.Value(u32) = .init(0),
    extended: std.atomic.Value(bool) = .init(false),
};

pub const Config = struct {
    version: std.atomic.Value(u64) = .init(0),
    view_version: std.atomic.Value(u64) = .init(0),
    count: std.atomic.Value(u8) = .init(0),
    window_ns: std.atomic.Value(u64) = .init(10 * std.time.ns_per_s),
    scroll_offset_ns: std.atomic.Value(u64) = .init(0),
    chart_width: std.atomic.Value(u16) = .init(80),
    targets: [max_signals]AtomicTarget = @splat(.{}),

    pub fn setTargets(self: *Config, targets: []const Target) void {
        _ = self.version.fetchAdd(1, .acq_rel);
        const count = @min(targets.len, max_signals);
        for (0..count) |index| {
            const target = targets[index];
            self.targets[index].bus_index.store(target.bus_index, .monotonic);
            self.targets[index].message_handle.store(target.message_handle, .monotonic);
            self.targets[index].signal_index.store(target.signal_index, .monotonic);
            self.targets[index].id.store(target.id, .monotonic);
            self.targets[index].extended.store(target.extended, .monotonic);
        }
        self.count.store(@intCast(count), .monotonic);
        _ = self.version.fetchAdd(1, .release);
    }

    pub fn setWindow(self: *Config, window_ns: u64) void {
        self.window_ns.store(@max(window_ns, 100 * std.time.ns_per_ms), .release);
        _ = self.view_version.fetchAdd(1, .release);
    }

    pub fn setScrollOffset(self: *Config, offset_ns: u64) void {
        self.scroll_offset_ns.store(offset_ns, .release);
        _ = self.view_version.fetchAdd(1, .release);
    }

    pub fn setChartWidth(self: *Config, width: u16) void {
        self.chart_width.store(@min(@max(width, 1), max_chart_width), .release);
        _ = self.view_version.fetchAdd(1, .release);
    }

    pub fn read(self: *const Config) Selection {
        while (true) {
            const before = self.version.load(.acquire);
            if (before & 1 != 0) continue;
            var selection = Selection{
                .count = self.count.load(.monotonic),
                .generation = before,
                .view_generation = self.view_version.load(.acquire),
                .window_ns = self.window_ns.load(.acquire),
                .scroll_offset_ns = self.scroll_offset_ns.load(.acquire),
                .chart_width = self.chart_width.load(.acquire),
            };
            for (0..selection.count) |index| {
                selection.targets[index] = .{
                    .bus_index = self.targets[index].bus_index.load(.monotonic),
                    .message_handle = self.targets[index].message_handle.load(.monotonic),
                    .signal_index = self.targets[index].signal_index.load(.monotonic),
                    .id = self.targets[index].id.load(.monotonic),
                    .extended = self.targets[index].extended.load(.monotonic),
                };
            }
            if (self.version.load(.acquire) == before) return selection;
        }
    }
};

pub const Sample = struct {
    signal_slot: u8,
    generation: u64,
    timestamp_ns: u64,
    value: f64,
};

pub const SampleQueue = spsc.Spsc(Sample, sample_queue_capacity);

pub const Point = struct {
    timestamp_ns: u64,
    x: f64,
    y: f64,
};

pub const Series = struct {
    target: Target = .{ .bus_index = 0, .message_handle = 0, .signal_index = 0, .id = 0, .extended = false },
    points: [max_decimated_points]Point = undefined,
    point_count: u16 = 0,
    minimum: f64 = 0,
    maximum: f64 = 0,
};

pub const Snapshot = struct {
    series: [max_signals]Series = @splat(.{}),
    series_count: u8 = 0,
    generation: u64 = 0,
    window_start_ns: u64 = 0,
    window_end_ns: u64 = 0,
    dropped: u64 = 0,
};

const History = struct {
    samples: [history_capacity]Point = undefined,
    write_index: usize = 0,
    len: usize = 0,

    fn append(self: *History, timestamp_ns: u64, value: f64) void {
        self.samples[self.write_index % history_capacity] = .{ .timestamp_ns = timestamp_ns, .x = 0, .y = value };
        self.write_index +%= 1;
        self.len = @min(self.len + 1, history_capacity);
    }

    fn clear(self: *History) void {
        self.write_index = 0;
        self.len = 0;
    }
};

pub const Worker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const Config,
    samples: *SampleQueue,
    dropped: std.atomic.Value(u64) = .init(0),
    reset_requested: std.atomic.Value(u64) = .init(0),
    reset_completed: std.atomic.Value(u64) = .init(0),
    stop: std.atomic.Value(bool) = .init(true),
    thread: ?std.Thread = null,
    histories: [max_signals]History = @splat(.{}),
    selection: Selection = .{},
    snapshots: triple_buffer.TripleBuffer(Snapshot) = .init(.{}),
    publish_generation: u64 = 0,

    pub const StartError = std.Thread.SpawnError || error{AlreadyStarted};

    pub fn create(allocator: std.mem.Allocator, io: std.Io, config: *const Config, samples: *SampleQueue) std.mem.Allocator.Error!*Worker {
        const worker = try allocator.create(Worker);
        worker.* = .{ .allocator = allocator, .io = io, .config = config, .samples = samples };
        return worker;
    }

    pub fn start(self: *Worker) StartError!void {
        if (self.thread != null) return error.AlreadyStarted;
        self.stop.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn stopAndDeinit(self: *Worker) void {
        self.stop.store(true, .release);
        if (self.thread) |thread| thread.join();
        self.allocator.destroy(self);
    }

    pub fn requestReset(self: *Worker) u64 {
        return self.reset_requested.fetchAdd(1, .acq_rel) +% 1;
    }

    pub fn resetComplete(self: *const Worker, request: u64) bool {
        return self.reset_completed.load(.acquire) == request;
    }

    pub fn windowNs(self: *const Worker) u64 {
        return self.config.read().window_ns;
    }

    pub fn step(self: *Worker, now_ns: u64) usize {
        const reset_request = self.reset_requested.load(.acquire);
        if (reset_request != self.reset_completed.load(.acquire)) {
            self.selection = self.config.read();
            self.histories = @splat(.{});
            while (self.samples.pop()) |_| {}
            self.publish(now_ns);
            self.reset_completed.store(reset_request, .release);
            return 0;
        }

        const latest_selection = self.config.read();
        const targets_changed = latest_selection.generation != self.selection.generation;
        const view_changed = latest_selection.view_generation != self.selection.view_generation;
        if (targets_changed) {
            self.selection = latest_selection;
            self.histories = @splat(.{});
        } else {
            self.selection.view_generation = latest_selection.view_generation;
            self.selection.window_ns = latest_selection.window_ns;
            self.selection.scroll_offset_ns = latest_selection.scroll_offset_ns;
            self.selection.chart_width = latest_selection.chart_width;
        }

        var batch: [sample_batch_capacity]Sample = undefined;
        var consumed: usize = 0;
        while (true) {
            const count = self.samples.popMany(&batch);
            if (count == 0) break;
            consumed += count;
            for (batch[0..count]) |sample| {
                if (sample.generation != self.selection.generation) continue;
                if (sample.signal_slot >= self.selection.count) continue;
                self.histories[sample.signal_slot].append(sample.timestamp_ns, sample.value);
            }
        }

        if (consumed != 0 or targets_changed or view_changed) self.publish(now_ns);
        return consumed;
    }

    pub fn readSnapshot(self: *Worker) Snapshot {
        return self.snapshots.read();
    }

    pub fn droppedCount(self: *const Worker) u64 {
        return self.dropped.load(.monotonic) +% self.samples.droppedCount();
    }

    fn publish(self: *Worker, now_ns: u64) void {
        var latest_ns = now_ns;
        for (0..self.selection.count) |slot| {
            const history = &self.histories[slot];
            if (history.len == 0) continue;
            const latest_index = (history.write_index -% 1) % history_capacity;
            latest_ns = @max(latest_ns, history.samples[latest_index].timestamp_ns);
        }
        const window_end_ns = latest_ns -| self.selection.scroll_offset_ns;
        const window_start_ns = window_end_ns -| self.selection.window_ns;
        var snapshot = Snapshot{
            .series_count = self.selection.count,
            .generation = self.publish_generation,
            .window_start_ns = window_start_ns,
            .window_end_ns = window_end_ns,
            .dropped = self.droppedCount(),
        };
        const width: usize = @min(@max(self.selection.chart_width, 1), max_chart_width);

        for (0..self.selection.count) |slot| {
            const target = self.selection.targets[slot].?;
            const history = &self.histories[slot];
            var series = &snapshot.series[slot];
            series.target = target;
            if (history.len == 0) continue;
            decimate(history, series, window_start_ns, latest_ns, width);
        }
        self.publish_generation +%= 1;
        self.snapshots.publish(snapshot);
    }

    fn run(self: *Worker) void {
        while (!self.stop.load(.acquire)) {
            const consumed = self.step(@intCast(std.Io.Clock.awake.now(self.io).nanoseconds));
            if (consumed == 0) std.Io.sleep(self.io, .{ .nanoseconds = 8 * std.time.ns_per_ms }, .awake) catch {};
        }
        _ = self.step(@intCast(std.Io.Clock.awake.now(self.io).nanoseconds));
        self.publish(@intCast(std.Io.Clock.awake.now(self.io).nanoseconds));
    }
};

fn decimate(history: *const History, series: *Series, window_start_ns: u64, window_end_ns: u64, width: usize) void {
    var min_points: [max_chart_width]?Point = @splat(null);
    var max_points: [max_chart_width]?Point = @splat(null);
    var min_indices: [max_chart_width]usize = undefined;
    var max_indices: [max_chart_width]usize = undefined;
    var minimum = std.math.inf(f64);
    var maximum = -std.math.inf(f64);
    const first = history.write_index -% history.len;
    const span = @max(@as(u64, 1), window_end_ns -| window_start_ns);

    for (0..history.len) |offset| {
        const sample_index = (first + offset) % history_capacity;
        const sample = history.samples[sample_index];
        if (sample.timestamp_ns < window_start_ns or sample.timestamp_ns > window_end_ns) continue;
        const relative = sample.timestamp_ns - window_start_ns;
        const column: usize = @min(@as(usize, @intCast(@as(u128, relative) * width / span)), width - 1);
        minimum = @min(minimum, sample.y);
        maximum = @max(maximum, sample.y);
        if (min_points[column] == null or sample.y < min_points[column].?.y) {
            min_points[column] = sample;
            min_indices[column] = offset;
        }
        if (max_points[column] == null or sample.y > max_points[column].?.y) {
            max_points[column] = sample;
            max_indices[column] = offset;
        }
    }

    if (!std.math.isFinite(minimum)) return;
    series.minimum = minimum;
    series.maximum = maximum;
    for (0..width) |column| {
        const min_point = min_points[column] orelse continue;
        const max_point = max_points[column].?;
        if (min_indices[column] == max_indices[column]) {
            appendDecimated(series, min_point, window_start_ns);
        } else if (min_indices[column] < max_indices[column]) {
            appendDecimated(series, min_point, window_start_ns);
            appendDecimated(series, max_point, window_start_ns);
        } else {
            appendDecimated(series, max_point, window_start_ns);
            appendDecimated(series, min_point, window_start_ns);
        }
    }
}

fn appendDecimated(series: *Series, sample: Point, window_start_ns: u64) void {
    if (series.point_count == max_decimated_points) return;
    series.points[series.point_count] = .{
        .timestamp_ns = sample.timestamp_ns,
        .x = @as(f64, @floatFromInt(sample.timestamp_ns -| window_start_ns)) / std.time.ns_per_s,
        .y = sample.y,
    };
    series.point_count += 1;
}

test "plot config publishes coherent signal selections" {
    var config: Config = .{};
    const targets = [_]Target{
        .{ .bus_index = 2, .message_handle = 11, .signal_index = 3, .id = 0x123, .extended = false },
    };
    config.setTargets(&targets);
    const selection = config.read();
    try std.testing.expectEqual(@as(u8, 1), selection.count);
    try std.testing.expectEqual(@as(u8, 2), selection.targets[0].?.bus_index);
    try std.testing.expectEqual(@as(usize, 11), selection.targets[0].?.message_handle);
}

test "plot worker retains peaks with min/max pixel decimation" {
    const allocator = std.testing.allocator;
    var config: Config = .{};
    const targets = [_]Target{
        .{ .bus_index = 0, .message_handle = 1, .signal_index = 0, .id = 1, .extended = false },
    };
    config.setTargets(&targets);
    config.setChartWidth(2);
    const generation = config.read().generation;
    var queue: SampleQueue = .{};
    const worker = try Worker.create(allocator, std.testing.io, &config, &queue);
    defer worker.stopAndDeinit();
    try std.testing.expect(queue.push(.{ .signal_slot = 0, .generation = generation, .timestamp_ns = 1, .value = 1 }));
    try std.testing.expect(queue.push(.{ .signal_slot = 0, .generation = generation, .timestamp_ns = 2, .value = 100 }));
    try std.testing.expect(queue.push(.{ .signal_slot = 0, .generation = generation, .timestamp_ns = 3, .value = -5 }));
    try std.testing.expect(queue.push(.{ .signal_slot = 0, .generation = generation, .timestamp_ns = 4, .value = 2 }));
    _ = worker.step(4);
    const snapshot = worker.readSnapshot();
    try std.testing.expectEqual(@as(u8, 1), snapshot.series_count);
    try std.testing.expect(snapshot.series[0].point_count <= 4);
    try std.testing.expectEqual(@as(f64, -5), snapshot.series[0].minimum);
    try std.testing.expectEqual(@as(f64, 100), snapshot.series[0].maximum);

    config.setWindow(20 * std.time.ns_per_s);
    config.setScrollOffset(2);
    _ = worker.step(100);
    const updated = worker.readSnapshot();
    try std.testing.expect(updated.generation > snapshot.generation);
    try std.testing.expect(updated.series[0].point_count != 0);
    try std.testing.expectEqual(@as(u64, 98), updated.window_end_ns);

    try std.testing.expect(queue.push(.{ .signal_slot = 0, .generation = generation, .timestamp_ns = 101, .value = 7 }));
    const reset = worker.requestReset();
    _ = worker.step(102);
    const reset_snapshot = worker.readSnapshot();
    try std.testing.expect(worker.resetComplete(reset));
    try std.testing.expectEqual(@as(u16, 0), reset_snapshot.series[0].point_count);
    try std.testing.expectEqual(@as(?Sample, null), queue.pop());
}

test "plot worker handles eight 1 kHz series with bounded decimation" {
    const allocator = std.testing.allocator;
    var config: Config = .{};
    var targets: [max_signals]Target = undefined;
    for (0..max_signals) |index| {
        targets[index] = .{ .bus_index = 0, .message_handle = index, .signal_index = 0, .id = @intCast(index), .extended = false };
    }
    config.setTargets(&targets);
    config.setWindow(std.time.ns_per_s);
    config.setChartWidth(80);
    const generation = config.read().generation;
    var queue: SampleQueue = .{};
    const worker = try Worker.create(allocator, std.testing.io, &config, &queue);
    defer worker.stopAndDeinit();
    for (0..1000) |sample_index| {
        for (0..max_signals) |slot| {
            try std.testing.expect(queue.push(.{
                .signal_slot = @intCast(slot),
                .generation = generation,
                .timestamp_ns = sample_index * std.time.ns_per_ms,
                .value = @floatFromInt((sample_index + slot) % 97),
            }));
        }
    }
    _ = worker.step(std.time.ns_per_s);
    const snapshot = worker.readSnapshot();
    try std.testing.expectEqual(@as(u8, max_signals), snapshot.series_count);
    try std.testing.expectEqual(@as(u64, 0), snapshot.dropped);
    for (snapshot.series[0..max_signals]) |series| {
        try std.testing.expect(series.point_count <= 160);
        try std.testing.expect(series.point_count != 0);
    }
}
