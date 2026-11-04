const std = @import("std");
const can_dbz = @import("can_dbz");
const Frame = @import("../can/frame.zig").Frame;
const spsc = @import("../sync/spsc.zig");
const triple_buffer = @import("../sync/triple_buffer.zig");
const rx = @import("rx.zig");
const store = @import("store.zig");
const plot = @import("plot.zig");
const log_writer = @import("../log/writer.zig");
const log_format = @import("../log/format.zig");

pub const max_channels = 4;
pub const ingest_batch_capacity = 256;
const Table = store.MessageTable(store.max_message_table_entries, 1024);

pub const Ingestor = struct {
    queues: [max_channels]?*rx.FrameQueue = @splat(null),
    queue_count: usize = 0,
    tx_queue: ?*store.TxEventQueue = null,
    marker_queue: ?*log_writer.MarkerQueue = null,
    rx_store: Table = .{},
    tx_store: Table = .{},
    sent_events: [store.max_snapshot_trace]store.TxEvent = undefined,
    sent_write: usize = 0,
    sent_len: usize = 0,
    tx_frames_total: u64 = 0,
    plot_config: ?*const plot.Config = null,
    plot_samples: ?*plot.SampleQueue = null,
    compiled_database: ?*const can_dbz.compile.CompiledDatabase = null,
    logger: ?*log_writer.Logger = null,
    snapshots: triple_buffer.TripleBuffer(store.Snapshot) = .init(.{}),
    generation: u64 = 0,
    reset_requested: std.atomic.Value(u64) = .init(0),
    reset_completed: std.atomic.Value(u64) = .init(0),
    restore_snapshot: store.Snapshot = .{},
    restore_rows: [store.max_message_table_entries]store.MessageRow = undefined,
    restore_row_count: u16 = 0,

    pub const AttachError = error{TooManyChannels};

    pub fn attachQueue(self: *Ingestor, queue: *rx.FrameQueue) AttachError!void {
        if (self.queue_count == self.queues.len) return error.TooManyChannels;
        self.queues[self.queue_count] = queue;
        self.queue_count += 1;
    }

    pub fn attachTxQueue(self: *Ingestor, queue: *store.TxEventQueue) void {
        self.tx_queue = queue;
    }

    pub fn attachPlot(self: *Ingestor, config: *const plot.Config, samples: *plot.SampleQueue, database: *const can_dbz.compile.CompiledDatabase) void {
        self.plot_config = config;
        self.plot_samples = samples;
        self.compiled_database = database;
    }

    pub fn attachLogger(self: *Ingestor, logger: ?*log_writer.Logger) void {
        self.logger = logger;
    }

    pub fn attachMarkerQueue(self: *Ingestor, queue: *log_writer.MarkerQueue) void {
        self.marker_queue = queue;
    }

    pub fn requestReset(self: *Ingestor) u64 {
        self.restore_snapshot = .{};
        self.restore_row_count = 0;
        return self.reset_requested.fetchAdd(1, .acq_rel) +% 1;
    }

    pub fn requestRestore(self: *Ingestor, snapshot: *const store.Snapshot, rows: []const store.MessageRow) u64 {
        std.debug.assert(rows.len <= self.restore_rows.len);
        self.restore_snapshot = snapshot.*;
        @memcpy(self.restore_rows[0..rows.len], rows);
        self.restore_row_count = @intCast(rows.len);
        return self.reset_requested.fetchAdd(1, .acq_rel) +% 1;
    }

    pub fn resetComplete(self: *const Ingestor, request: u64) bool {
        return self.reset_completed.load(.acquire) == request;
    }

    pub fn step(self: *Ingestor) usize {
        const reset_request = self.reset_requested.load(.acquire);
        if (reset_request != self.reset_completed.load(.acquire)) {
            for (self.queues[0..self.queue_count]) |maybe_queue| {
                while (maybe_queue.?.pop()) |_| {}
            }
            if (self.tx_queue) |queue| while (queue.pop()) |_| {};
            self.rx_store.restoreState(&self.restore_snapshot, self.restore_rows[0..self.restore_row_count]);
            self.tx_store = .{};
            self.sent_write = self.restore_snapshot.sent_count;
            self.sent_len = self.restore_snapshot.sent_count;
            self.tx_frames_total = self.restore_snapshot.tx_frames_total;
            for (0..self.sent_len) |index| self.sent_events[index] = self.restore_snapshot.sent[index];
            self.generation +%= 1;
            self.publish();
            self.reset_completed.store(reset_request, .release);
            return 0;
        }

        var consumed: usize = 0;
        var batch: [ingest_batch_capacity]Frame = undefined;
        for (self.queues[0..self.queue_count]) |maybe_queue| {
            const queue = maybe_queue.?;
            const count = queue.popMany(&batch);
            for (batch[0..count]) |frame| {
                _ = self.rx_store.update(frame);
                self.pushPlotSamples(frame);
                self.logFrame(frame, .rx, null);
            }
            consumed += count;
        }

        if (self.tx_queue) |queue| {
            while (queue.pop()) |event| {
                _ = self.tx_store.update(event.frame);
                self.logFrame(event.frame, .tx, txStatus(event.status));
                self.sent_events[self.sent_write & (store.max_snapshot_trace - 1)] = event;
                self.sent_write +%= 1;
                self.sent_len = @min(self.sent_len + 1, store.max_snapshot_trace);
                self.tx_frames_total +%= 1;
                consumed += 1;
            }
        }

        if (self.marker_queue) |queue| {
            while (queue.pop()) |marker| {
                if (self.logger) |logger| _ = logger.enqueueMarker(marker.t_ns, marker.text.slice());
                consumed += 1;
            }
        }

        if (consumed != 0) self.publish();
        return consumed;
    }

    fn logFrame(self: *Ingestor, frame: Frame, direction: log_format.Direction, status: ?log_format.TxStatus) void {
        const logger = self.logger orelse return;
        _ = logger.enqueueFrame(.{
            .t_ns = frame.timestamp_ns,
            .bus = frame.bus,
            .direction = direction,
            .frame = frame,
            .status = status,
            .echo = frame.flags.tx_echo,
        });
    }

    fn txStatus(status: store.TxStatus) log_format.TxStatus {
        return switch (status) {
            .ok => .ok,
            .queue_full => .queue_full,
            .bus_off => .bus_off,
            .driver_error => .driver_error,
        };
    }

    fn pushPlotSamples(self: *Ingestor, frame: Frame) void {
        const config = self.plot_config orelse return;
        const samples = self.plot_samples orelse return;
        const database = self.compiled_database orelse return;
        const selection = config.read();
        for (0..selection.count) |slot| {
            const target = selection.targets[slot].?;
            if (frame.bus != target.bus_index or frame.id != target.id or frame.flags.extended != target.extended) continue;
            const value = database.decodeSignalPhysical(target.message_handle, target.signal_index, frame.data[0..frame.len]) catch continue;
            _ = samples.push(.{
                .signal_slot = @intCast(slot),
                .generation = selection.generation,
                .timestamp_ns = frame.timestamp_ns,
                .value = value,
            });
        }
    }

    pub fn publish(self: *Ingestor) void {
        self.generation +%= 1;
        var snapshot: store.Snapshot = .{};
        self.rx_store.publish(&snapshot, self.generation);
        for (self.queues[0..self.queue_count]) |maybe_queue| {
            snapshot.dropped +%= maybe_queue.?.droppedCount();
        }
        snapshot.tx_frames_total = self.tx_frames_total;
        snapshot.sent_count = @intCast(self.sent_len);
        const first_sent = self.sent_write -% self.sent_len;
        for (0..self.sent_len) |index| {
            snapshot.sent[index] = self.sent_events[(first_sent + index) & (store.max_snapshot_trace - 1)];
        }
        self.snapshots.publish(snapshot);
    }

    pub fn readSnapshot(self: *Ingestor) store.Snapshot {
        return self.snapshots.read();
    }

    pub fn droppedCount(self: *const Ingestor) u64 {
        var dropped = self.rx_store.dropped +% self.tx_store.dropped;
        for (self.queues[0..self.queue_count]) |maybe_queue| {
            dropped +%= maybe_queue.?.droppedCount();
        }
        if (self.tx_queue) |queue| dropped +%= queue.droppedCount();
        if (self.marker_queue) |queue| dropped +%= queue.droppedCount();
        if (self.plot_samples) |queue| dropped +%= queue.droppedCount();
        if (self.logger) |logger| dropped +%= logger.droppedCount();
        return dropped;
    }

    pub fn run(self: *Ingestor, stop: *const std.atomic.Value(bool)) void {
        while (!stop.load(.acquire)) {
            if (self.step() == 0) std.Thread.yield() catch {};
        }
        while (self.step() != 0) {}
        self.publish();
    }
};

test "ingest drains channel queues and publishes one sorted snapshot" {
    var queue: rx.FrameQueue = .{};
    var ingestor: Ingestor = .{};
    try ingestor.attachQueue(&queue);
    try std.testing.expect(queue.push(testFrame(1, 0x200)));
    try std.testing.expect(queue.push(testFrame(0, 0x100)));

    try std.testing.expectEqual(@as(usize, 2), ingestor.step());
    const snapshot = ingestor.readSnapshot();
    try std.testing.expectEqual(@as(u16, 2), snapshot.row_count);
    try std.testing.expectEqual(@as(u8, 0), snapshot.rows[0].frame.bus);
    try std.testing.expectEqual(@as(u32, 0x100), snapshot.rows[0].frame.id);
    try std.testing.expectEqual(@as(u64, 2), snapshot.frames_total);
    try std.testing.expectEqual(@as(u64, 1), snapshot.generation);
}

test "ingest reset discards queued frames and clears published state" {
    var queue: rx.FrameQueue = .{};
    var ingestor: Ingestor = .{};
    try ingestor.attachQueue(&queue);
    try std.testing.expect(queue.push(testFrame(0, 0x123)));
    try std.testing.expectEqual(@as(usize, 1), ingestor.step());
    try std.testing.expectEqual(@as(u16, 1), ingestor.readSnapshot().row_count);

    try std.testing.expect(queue.push(testFrame(0, 0x456)));
    const request = ingestor.requestReset();
    try std.testing.expectEqual(@as(usize, 0), ingestor.step());

    const snapshot = ingestor.readSnapshot();
    try std.testing.expect(ingestor.resetComplete(request));
    try std.testing.expectEqual(@as(u16, 0), snapshot.row_count);
    try std.testing.expectEqual(@as(u64, 0), snapshot.frames_total);
    try std.testing.expectEqual(@as(?Frame, null), queue.pop());
}

test "ingest restores RX and Sent state from a keyframe snapshot" {
    const SmallTable = store.MessageTable(8, 4);
    var source_table: SmallTable = .{};
    try std.testing.expect(source_table.update(testFrame(0, 0x123)));
    var snapshot: store.Snapshot = .{};
    source_table.publish(&snapshot, 1);
    snapshot.tx_frames_total = 1;
    snapshot.sent_count = 1;
    snapshot.sent[0] = .{ .frame = testFrame(0, 0x456), .status = .ok, .timestamp_ns = 1 };

    var queue: rx.FrameQueue = .{};
    var tx_queue: store.TxEventQueue = .{};
    var ingestor: Ingestor = .{};
    try ingestor.attachQueue(&queue);
    ingestor.attachTxQueue(&tx_queue);
    const request = ingestor.requestRestore(&snapshot, snapshot.rows[0..snapshot.row_count]);
    try std.testing.expectEqual(@as(usize, 0), ingestor.step());

    const restored = ingestor.readSnapshot();
    try std.testing.expect(ingestor.resetComplete(request));
    try std.testing.expectEqual(@as(u16, 1), restored.row_count);
    try std.testing.expectEqual(@as(u32, 0x123), restored.rows[0].frame.id);
    try std.testing.expectEqual(@as(u64, 1), restored.tx_frames_total);
    try std.testing.expectEqual(@as(u16, 1), restored.sent_count);
    try std.testing.expectEqual(@as(u32, 0x456), restored.sent[0].frame.id);
}

test "ingest decodes only configured plot signals into the sample queue" {
    const allocator = std.testing.allocator;
    const Database = @import("../db/database.zig").Database;
    const Diagnostics = @import("../db/database.zig").Diagnostics;
    const source =
        \\VERSION ""
        \\
        \\NS_ :
        \\
        \\BS_:
        \\
        \\BU_: ECU
        \\
        \\BO_ 192 EngineData: 8 ECU
        \\ SG_ RPM : 0|16@1+ (0.25,0) [0|16383.75] "rpm" Vector__XXX
        \\
    ;
    var diagnostics: Diagnostics = .empty;
    defer diagnostics.deinit(allocator);
    var database = try Database.init(allocator, .dbc, source, &diagnostics);
    defer database.deinit();
    const handle = database.compiled.findMessage("can0", 192, false).?;

    var plot_config: plot.Config = .{};
    const targets = [_]plot.Target{.{ .bus_index = 0, .message_handle = handle, .signal_index = 0, .id = 192, .extended = false }};
    plot_config.setTargets(&targets);
    var samples: plot.SampleQueue = .{};
    var frame_queue: rx.FrameQueue = .{};
    var ingestor: Ingestor = .{};
    try ingestor.attachQueue(&frame_queue);
    ingestor.attachPlot(&plot_config, &samples, &database.compiled);

    var frame = testFrame(0, 192);
    frame.len = 8;
    frame.timestamp_ns = 1234;
    frame.data[0] = 0x10;
    frame.data[1] = 0x27;
    try std.testing.expect(frame_queue.push(frame));
    try std.testing.expectEqual(@as(usize, 1), ingestor.step());
    const sample = samples.pop().?;
    try std.testing.expectEqual(@as(u8, 0), sample.signal_slot);
    try std.testing.expectEqual(@as(u64, 1234), sample.timestamp_ns);
    try std.testing.expectApproxEqAbs(@as(f64, 2500), sample.value, 1e-9);
}

fn testFrame(bus: u8, id: u32) Frame {
    return .{
        .timestamp_ns = 1,
        .id = id,
        .bus = bus,
        .len = 0,
        .flags = .{},
        ._pad = 0,
        .data = @splat(0),
    };
}
