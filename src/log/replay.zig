const std = @import("std");
const rx = @import("../engine/rx.zig");
const store = @import("../engine/store.zig");
const Ingestor = @import("../engine/ingest.zig").Ingestor;
const PlotWorker = @import("../engine/plot.zig").Worker;
const Database = @import("../db/database.zig").Database;
const format = @import("format.zig");
const log_index = @import("index.zig");

pub const max_log_buses = format.max_buses;
const backstep_history_capacity = 4096;

pub const ReplaySource = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    reader: std.Io.File.Reader,
    line_buffer: [8192]u8,
    index_path: []u8,
    data_offset: u64 = 0,
    header: format.Header,
    index: ?log_index.Index = null,
    index_ready: std.atomic.Value(bool) = .init(false),
    index_failed: std.atomic.Value(bool) = .init(false),
    index_cancel: std.atomic.Value(bool) = .init(false),
    index_bytes_scanned: std.atomic.Value(u64) = .init(0),
    index_file_size: std.atomic.Value(u64) = .init(0),
    rx_queue: *rx.FrameQueue,
    tx_queue: *store.TxEventQueue,
    ingestor: ?*Ingestor = null,
    plot_worker: ?*PlotWorker = null,
    bus_map: [max_log_buses]u8 = @splat(0),
    stop_requested: std.atomic.Value(bool) = .init(true),
    playing: std.atomic.Value(bool) = .init(false),
    speed_milli: std.atomic.Value(u32) = .init(1000),
    step_requests: std.atomic.Value(u32) = .init(0),
    step_back_requests: std.atomic.Value(u32) = .init(0),
    seek_target_ns: std.atomic.Value(u64) = .init(0),
    seek_requires_reset: std.atomic.Value(bool) = .init(false),
    seek_offset_mode: std.atomic.Value(bool) = .init(false),
    seek_offset_target: std.atomic.Value(u64) = .init(0),
    seek_offset_exclusive: std.atomic.Value(bool) = .init(false),
    seek_sequence: std.atomic.Value(u64) = .init(0),
    seek_completed: std.atomic.Value(u64) = .init(0),
    resume_after_seek: std.atomic.Value(bool) = .init(false),
    frames_played: std.atomic.Value(u64) = .init(0),
    malformed_lines: std.atomic.Value(u64) = .init(0),
    position_ns: std.atomic.Value(u64) = .init(0),
    eof: std.atomic.Value(bool) = .init(false),
    frame_offsets: [backstep_history_capacity]u64 = undefined,
    frame_timestamps: [backstep_history_capacity]u64 = undefined,
    frame_history_write: usize = 0,
    frame_history_len: usize = 0,
    history_base_offset: u64 = 0,
    history_base_time_ns: u64 = 0,
    thread: ?std.Thread = null,
    index_thread: ?std.Thread = null,

    pub const CreateError = std.Io.File.OpenError || std.Thread.SpawnError || std.mem.Allocator.Error || error{ ReadFailed, StreamTooLong, MissingHeader, InvalidHeader };
    pub const StartError = std.Thread.SpawnError || error{AlreadyStarted};

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        database: *const Database,
        rx_queue: *rx.FrameQueue,
        tx_queue: *store.TxEventQueue,
    ) CreateError!*ReplaySource {
        const self = try allocator.create(ReplaySource);
        errdefer allocator.destroy(self);
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .reader = undefined,
            .line_buffer = undefined,
            .index_path = owned_path,
            .header = .{},
            .rx_queue = rx_queue,
            .tx_queue = tx_queue,
        };
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        errdefer file.close(io);
        self.reader = std.Io.File.Reader.init(file, io, &self.line_buffer);
        const header_line = self.reader.interface.takeDelimiterInclusive('\n') catch return error.InvalidHeader;
        const record = (format.decodeLine(header_line[0 .. header_line.len - 1]) catch return error.InvalidHeader) orelse return error.InvalidHeader;
        if (record != .header) return error.MissingHeader;
        self.header = record.header;
        self.data_offset = self.reader.logicalPos();
        self.history_base_offset = self.data_offset;
        if (self.reader.file.stat(io)) |stat| {
            self.index_file_size.store(stat.size -| self.data_offset, .release);
        } else |_| {}
        for (self.header.buses[0..self.header.bus_count]) |bus| {
            var mapped: ?u8 = null;
            for (database.doc.buses.items, 0..) |database_bus, index| {
                if (std.mem.eql(u8, bus.name.slice(), database_bus.name)) mapped = @intCast(index);
            }
            self.bus_map[bus.index] = mapped orelse bus.index;
        }
        self.index_thread = try std.Thread.spawn(.{}, runIndexer, .{self});
        return self;
    }

    pub fn start(self: *ReplaySource) StartError!void {
        if (self.thread != null) return error.AlreadyStarted;
        self.stop_requested.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn play(self: *ReplaySource) void {
        self.step_requests.store(0, .release);
        self.playing.store(true, .release);
    }

    pub fn pause(self: *ReplaySource) void {
        self.playing.store(false, .release);
    }

    pub fn stepForward(self: *ReplaySource) void {
        self.playing.store(false, .release);
        _ = self.step_requests.fetchAdd(1, .release);
    }

    pub fn stepBackward(self: *ReplaySource) void {
        self.playing.store(false, .release);
        self.step_requests.store(0, .release);
        _ = self.step_back_requests.fetchAdd(1, .release);
    }

    pub fn attachIngestor(self: *ReplaySource, ingestor: *Ingestor) void {
        self.ingestor = ingestor;
    }

    pub fn attachPlotWorker(self: *ReplaySource, worker: *PlotWorker) void {
        self.plot_worker = worker;
    }

    pub fn seekTo(self: *ReplaySource, timestamp_ns: u64) void {
        self.seek_requires_reset.store(timestamp_ns < self.position_ns.load(.acquire), .release);
        self.seek_offset_mode.store(false, .release);
        self.resume_after_seek.store(self.playing.load(.acquire), .release);
        self.playing.store(false, .release);
        self.step_requests.store(0, .release);
        self.seek_target_ns.store(timestamp_ns, .release);
        _ = self.seek_sequence.fetchAdd(1, .release);
    }

    pub fn seekBy(self: *ReplaySource, delta_ns: i64) void {
        const current = self.position_ns.load(.acquire);
        const requested = if (delta_ns < 0)
            current -| @as(u64, @intCast(-delta_ns))
        else
            current +| @as(u64, @intCast(delta_ns));
        const duration = if (self.indexData()) |index| index.duration_ns else std.math.maxInt(u64);
        self.seekTo(@min(requested, duration));
    }

    pub fn durationNs(self: *const ReplaySource) u64 {
        return if (self.indexData()) |index| index.duration_ns else 0;
    }

    pub fn indexData(self: *const ReplaySource) ?*const log_index.Index {
        if (!self.index_ready.load(.acquire)) return null;
        return if (self.index) |*index| index else null;
    }

    pub fn indexProgress(self: *const ReplaySource) struct { scanned: u64, total: u64, failed: bool } {
        return .{
            .scanned = self.index_bytes_scanned.load(.acquire),
            .total = self.index_file_size.load(.acquire),
            .failed = self.index_failed.load(.acquire),
        };
    }

    pub fn jumpToNextMarker(self: *ReplaySource) bool {
        const index = self.indexData() orelse return false;
        const marker = index.markerAtOrAfter(self.position_ns.load(.acquire) +| 1) orelse return false;
        self.seekTo(marker.t_ns);
        return true;
    }

    pub fn jumpToPreviousMarker(self: *ReplaySource) bool {
        const index = self.indexData() orelse return false;
        const marker = index.markerBefore(self.position_ns.load(.acquire)) orelse return false;
        self.seekTo(marker.t_ns);
        return true;
    }

    pub fn setSpeed(self: *ReplaySource, speed_milli: u32) void {
        self.speed_milli.store(@min(@max(speed_milli, 100), 10_000), .release);
    }

    pub fn speedMilli(self: *const ReplaySource) u32 {
        return self.speed_milli.load(.acquire);
    }

    pub fn stopAndDeinit(self: *ReplaySource) void {
        self.stop();
        self.reader.file.close(self.io);
        if (self.index) |*index| index.deinit();
        self.allocator.free(self.index_path);
        self.allocator.destroy(self);
    }

    pub fn stop(self: *ReplaySource) void {
        self.stop_requested.store(true, .release);
        self.index_cancel.store(true, .release);
        if (self.thread) |thread| thread.join();
        self.thread = null;
        if (self.index_thread) |thread| thread.join();
        self.index_thread = null;
    }

    fn runIndexer(self: *ReplaySource) void {
        const index = log_index.Index.createWithProgress(
            self.allocator,
            self.io,
            self.index_path,
            self.data_offset,
            &self.index_bytes_scanned,
            &self.index_cancel,
        ) catch {
            self.index_failed.store(true, .release);
            return;
        };
        self.index = index;
        self.index_ready.store(true, .release);
    }

    fn run(self: *ReplaySource) void {
        var previous_t_ns: ?u64 = null;
        var handled_seek: u64 = 0;
        while (!self.stop_requested.load(.acquire)) {
            if (self.step_back_requests.load(.acquire) != 0) {
                _ = self.step_back_requests.fetchSub(1, .acq_rel);
                const backstep = if (self.frame_history_len == 0) blk: {
                    const index = self.indexData() orelse break :blk null;
                    const keyframe = index.keyframeAtOrBefore(self.history_base_time_ns) orelse break :blk null;
                    break :blk keyframe.backstep_target;
                } else null;
                if (self.frame_history_len != 0 or backstep != null) {
                    const target_offset: u64 = if (self.frame_history_len == 0)
                        backstep.?.byte_offset
                    else if (self.frame_history_len == 1)
                        self.history_base_offset
                    else
                        self.frame_offsets[(self.frame_history_write -% 2) & (backstep_history_capacity - 1)];
                    const target_time = if (self.frame_history_len == 0)
                        backstep.?.t_ns
                    else if (self.frame_history_len == 1)
                        self.history_base_time_ns
                    else
                        self.frame_timestamps[(self.frame_history_write -% 2) & (backstep_history_capacity - 1)];
                    self.resume_after_seek.store(false, .release);
                    self.playing.store(false, .release);
                    self.seek_target_ns.store(target_time, .release);
                    self.seek_requires_reset.store(true, .release);
                    self.seek_offset_target.store(target_offset, .release);
                    self.seek_offset_exclusive.store(if (self.frame_history_len == 0) backstep.?.stop_before else self.frame_history_len == 1, .release);
                    self.seek_offset_mode.store(true, .release);
                    _ = self.seek_sequence.fetchAdd(1, .release);
                }
            }
            const seek_sequence = self.seek_sequence.load(.acquire);
            if (seek_sequence != handled_seek) {
                self.performSeek(self.seek_target_ns.load(.acquire), seek_sequence);
                handled_seek = seek_sequence;
                previous_t_ns = self.position_ns.load(.acquire);
                continue;
            }
            const playing = self.playing.load(.acquire);
            if (!playing) {
                const requests = self.step_requests.load(.acquire);
                if (requests == 0) {
                    std.Io.sleep(self.io, .{ .nanoseconds = std.time.ns_per_ms }, .awake) catch {};
                    continue;
                }
                _ = self.step_requests.fetchSub(1, .acq_rel);
            }

            const record_offset = self.reader.logicalPos();
            const record = self.nextRecord() catch {
                _ = self.malformed_lines.fetchAdd(1, .monotonic);
                continue;
            } orelse {
                self.eof.store(true, .release);
                self.playing.store(false, .release);
                continue;
            };
            if (record != .frame) continue;
            const frame_record = record.frame;

            if (playing) {
                if (previous_t_ns) |previous| {
                    const speed = self.speed_milli.load(.acquire);
                    const delay_ns = @as(u128, frame_record.t_ns -| previous) * 1000 / speed;
                    if (delay_ns > 0) std.Io.sleep(self.io, .{ .nanoseconds = @intCast(@min(delay_ns, std.math.maxInt(u64))) }, .awake) catch {};
                }
            }
            previous_t_ns = frame_record.t_ns;
            self.rememberFrame(record_offset, frame_record.t_ns);
            self.position_ns.store(frame_record.t_ns, .release);
            var frame = frame_record.frame;
            frame.bus = self.bus_map[frame_record.bus];
            if (frame_record.direction == .rx) {
                _ = self.rx_queue.push(frame);
            } else {
                const status = txStatus(frame_record.status);
                _ = self.tx_queue.push(.{ .frame = frame, .status = status, .timestamp_ns = frame.timestamp_ns });
            }
            _ = self.frames_played.fetchAdd(1, .monotonic);
        }
    }

    fn performSeek(self: *ReplaySource, target_ns: u64, sequence: u64) void {
        if (self.seek_requires_reset.load(.acquire)) {
            const ingestor = self.ingestor orelse {
                self.seek_completed.store(sequence, .release);
                return;
            };
            while (!self.stop_requested.load(.acquire) and !self.index_ready.load(.acquire) and !self.index_failed.load(.acquire)) {
                std.Thread.yield() catch {};
            }
            if (self.stop_requested.load(.acquire) or self.index_failed.load(.acquire)) {
                self.seek_completed.store(sequence, .release);
                return;
            }
            const prefill_start_ns = if (self.plot_worker) |worker|
                target_ns -| worker.windowNs()
            else
                target_ns;
            const index = self.indexData() orelse return;
            const keyframe = index.keyframeAtOrBefore(prefill_start_ns) orelse return;
            var snapshot = keyframe.snapshot;
            var rows: [store.max_message_table_entries]store.MessageRow = undefined;
            @memcpy(rows[0..keyframe.rows.len], keyframe.rows);
            for (rows[0..keyframe.rows.len]) |*row| row.frame.bus = self.bus_map[row.frame.bus];
            for (snapshot.rows[0..snapshot.row_count]) |*row| row.frame.bus = self.bus_map[row.frame.bus];
            for (snapshot.trace[0..snapshot.trace_len]) |*frame| frame.bus = self.bus_map[frame.bus];
            for (snapshot.sent[0..snapshot.sent_count]) |*event| event.frame.bus = self.bus_map[event.frame.bus];
            const reset_request = ingestor.requestRestore(&snapshot, rows[0..keyframe.rows.len]);
            while (!self.stop_requested.load(.acquire) and !ingestor.resetComplete(reset_request)) {
                std.Thread.yield() catch {};
            }
            if (self.stop_requested.load(.acquire)) return;
            if (self.plot_worker) |worker| {
                const plot_reset = worker.requestReset();
                while (!self.stop_requested.load(.acquire) and !worker.resetComplete(plot_reset)) {
                    std.Thread.yield() catch {};
                }
                if (self.stop_requested.load(.acquire)) return;
            }

            self.reader.seekTo(keyframe.byte_offset) catch {
                _ = self.malformed_lines.fetchAdd(1, .monotonic);
                self.seek_completed.store(sequence, .release);
                return;
            };
            self.frame_history_write = 0;
            self.frame_history_len = 0;
            self.history_base_offset = keyframe.byte_offset;
            self.history_base_time_ns = keyframe.t_ns;
            self.frames_played.store(snapshot.frames_total +% snapshot.tx_frames_total, .release);
            self.position_ns.store(keyframe.t_ns, .release);
        }
        self.eof.store(false, .release);

        var target_frame_seen = false;
        while (!self.stop_requested.load(.acquire)) {
            const record_offset = self.reader.logicalPos();
            if (self.seek_offset_mode.load(.acquire)) {
                const target_offset = self.seek_offset_target.load(.acquire);
                if (target_frame_seen or (self.seek_offset_exclusive.load(.acquire) and record_offset >= target_offset)) {
                    self.reader.seekTo(record_offset) catch {};
                    break;
                }
            }
            const record = self.nextRecord() catch {
                _ = self.malformed_lines.fetchAdd(1, .monotonic);
                continue;
            } orelse {
                self.eof.store(true, .release);
                break;
            };
            if (record != .frame) continue;
            const frame_record = record.frame;
            if (frame_record.t_ns > target_ns) {
                self.reader.seekTo(record_offset) catch {};
                break;
            }

            var frame = frame_record.frame;
            frame.bus = self.bus_map[frame_record.bus];
            if (frame_record.direction == .rx) {
                while (self.rx_queue.lenApprox() >= rx.queue_capacity and !self.stop_requested.load(.acquire)) {
                    std.Thread.yield() catch {};
                }
                if (self.stop_requested.load(.acquire)) break;
                _ = self.rx_queue.push(frame);
            } else {
                const event = store.TxEvent{
                    .frame = frame,
                    .status = txStatus(frame_record.status),
                    .timestamp_ns = frame.timestamp_ns,
                };
                while (self.tx_queue.lenApprox() >= 1024 and !self.stop_requested.load(.acquire)) {
                    std.Thread.yield() catch {};
                }
                if (self.stop_requested.load(.acquire)) break;
                _ = self.tx_queue.push(event);
            }
            self.position_ns.store(frame_record.t_ns, .release);
            self.rememberFrame(record_offset, frame_record.t_ns);
            _ = self.frames_played.fetchAdd(1, .monotonic);
            if (self.seek_offset_mode.load(.acquire) and record_offset == self.seek_offset_target.load(.acquire)) target_frame_seen = true;
        }
        if (!self.stop_requested.load(.acquire)) {
            self.seek_offset_mode.store(false, .release);
            self.playing.store(self.resume_after_seek.load(.acquire), .release);
            self.seek_completed.store(sequence, .release);
        }
    }

    fn rememberFrame(self: *ReplaySource, byte_offset: u64, timestamp_ns: u64) void {
        const index = self.frame_history_write & (backstep_history_capacity - 1);
        self.frame_offsets[index] = byte_offset;
        self.frame_timestamps[index] = timestamp_ns;
        self.frame_history_write +%= 1;
        self.frame_history_len = @min(self.frame_history_len + 1, backstep_history_capacity);
    }

    fn nextRecord(self: *ReplaySource) !?format.Record {
        while (true) {
            const line = self.reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.EndOfStream => return null,
                error.StreamTooLong => {
                    _ = self.reader.interface.discardDelimiterInclusive('\n') catch |discard_err| switch (discard_err) {
                        error.EndOfStream => return null,
                        else => return error.ReadFailed,
                    };
                    _ = self.malformed_lines.fetchAdd(1, .monotonic);
                    continue;
                },
                else => return err,
            };
            if (line.len == 0) continue;
            const record = format.decodeLine(line[0 .. line.len - 1]) catch {
                _ = self.malformed_lines.fetchAdd(1, .monotonic);
                continue;
            };
            if (record) |value| return value;
        }
    }
};

fn txStatus(status: ?format.TxStatus) store.TxStatus {
    return switch (status orelse .driver_error) {
        .ok => .ok,
        .queue_full => .queue_full,
        .bus_off => .bus_off,
        .driver_error => .driver_error,
    };
}

test "replay source streams RX frames and TX status into the live ingest queues" {
    const allocator = std.testing.allocator;
    const Diagnostics = @import("../db/database.zig").Diagnostics;
    const database_source =
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
    var database = try Database.init(allocator, .dbc, database_source, &diagnostics);
    defer database.deinit();

    const log_lines =
        "{\"type\":\"header\",\"format\":\"can_dbz_vis/log\",\"version\":1,\"created_utc\":\"2026-11-04T00:00:00Z\",\"tool\":\"test\",\"database\":null,\"buses\":[{\"index\":0,\"name\":\"can0\",\"backend\":\"virtual\",\"channel\":\"virtual0\",\"fd\":false,\"timestamps\":\"software\"}]}\n" ++
        "{\"type\":\"frame\",\"t_ns\":1,\"bus\":0,\"dir\":\"rx\",\"id\":\"0C0\",\"len\":8,\"data\":\"1027800000000000\"}\n" ++
        "{\"type\":\"frame\",\"t_ns\":2,\"bus\":0,\"dir\":\"tx\",\"id\":\"0C0\",\"len\":8,\"data\":\"1027800000000000\",\"status\":\"ok\"}\n" ++
        "{\"type\":\"frame\",\"t_ns\":3,\"bus\":0,\"dir\":\"rx\",\"id\":\"0C0\",\"len\":8,\"data\":\"1027800000000000\"}";
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "replay.canlog.jsonl", .data = log_lines });
    const path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &temporary.sub_path, "replay.canlog.jsonl" });
    defer allocator.free(path);

    var rx_queue: rx.FrameQueue = .{};
    var tx_queue: store.TxEventQueue = .{};
    const replay = try ReplaySource.create(allocator, std.testing.io, path, &database, &rx_queue, &tx_queue);
    for (0..100_000) |_| {
        if (replay.index_ready.load(.acquire) or replay.index_failed.load(.acquire)) break;
        std.Thread.yield() catch {};
    }
    try std.testing.expect(replay.indexData() != null);
    try std.testing.expect(replay.indexProgress().scanned <= replay.indexProgress().total);
    try replay.start();
    replay.play();
    for (0..100_000) |_| {
        if (replay.frames_played.load(.acquire) == 2 or replay.eof.load(.acquire)) break;
        std.Thread.yield() catch {};
    }
    const frames_played = replay.frames_played.load(.acquire);
    replay.stopAndDeinit();

    try std.testing.expectEqual(@as(u64, 2), frames_played);
    const rx_frame = rx_queue.pop().?;
    try std.testing.expectEqual(@as(u32, 192), rx_frame.id);
    const tx_event = tx_queue.pop().?;
    try std.testing.expectEqual(store.TxStatus.ok, tx_event.status);
    try std.testing.expectEqual(@as(u32, 192), tx_event.frame.id);
}

test "replay seek rebuilds ingest state at the target timestamp" {
    const allocator = std.testing.allocator;
    const Diagnostics = @import("../db/database.zig").Diagnostics;
    const database_source =
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
    var database = try Database.init(allocator, .dbc, database_source, &diagnostics);
    defer database.deinit();

    const log_lines =
        "{\"type\":\"header\",\"format\":\"can_dbz_vis/log\",\"version\":1,\"created_utc\":\"2026-11-04T00:00:00Z\",\"tool\":\"test\",\"database\":null,\"buses\":[{\"index\":0,\"name\":\"can0\",\"backend\":\"virtual\",\"channel\":\"virtual0\",\"fd\":false,\"timestamps\":\"software\"}]}\n" ++
        "{\"type\":\"frame\",\"t_ns\":1,\"bus\":0,\"dir\":\"rx\",\"id\":\"0C0\",\"len\":8,\"data\":\"1027800000000000\"}\n" ++
        "{\"type\":\"frame\",\"t_ns\":2,\"bus\":0,\"dir\":\"tx\",\"id\":\"0C0\",\"len\":8,\"data\":\"1027800000000000\",\"status\":\"ok\"}\n";
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "seek.canlog.jsonl", .data = log_lines });
    const path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &temporary.sub_path, "seek.canlog.jsonl" });
    defer allocator.free(path);

    var rx_queue: rx.FrameQueue = .{};
    var tx_queue: store.TxEventQueue = .{};
    var ingestor: Ingestor = .{};
    try ingestor.attachQueue(&rx_queue);
    ingestor.attachTxQueue(&tx_queue);
    var ingest_stop: std.atomic.Value(bool) = .init(false);
    const ingest_thread = try std.Thread.spawn(.{}, runTestIngestor, .{ &ingestor, &ingest_stop });
    defer {
        ingest_stop.store(true, .release);
        ingest_thread.join();
    }

    const replay = try ReplaySource.create(allocator, std.testing.io, path, &database, &rx_queue, &tx_queue);
    defer replay.stopAndDeinit();
    replay.attachIngestor(&ingestor);
    try replay.start();
    replay.play();
    for (0..100_000) |_| {
        if (replay.eof.load(.acquire)) break;
        std.Thread.yield() catch {};
    }
    try std.testing.expect(replay.eof.load(.acquire));

    replay.seekTo(1);
    for (0..100_000) |_| {
        if (replay.seek_completed.load(.acquire) == replay.seek_sequence.load(.acquire)) break;
        std.Thread.yield() catch {};
    }
    try std.testing.expectEqual(@as(u64, 1), replay.position_ns.load(.acquire));
    for (0..100_000) |_| {
        if (ingestor.readSnapshot().frames_total == 1) break;
        std.Thread.yield() catch {};
    }

    const snapshot = ingestor.readSnapshot();
    try std.testing.expectEqual(@as(u64, 1), snapshot.frames_total);
    try std.testing.expectEqual(@as(u64, 0), snapshot.tx_frames_total);
    try std.testing.expectEqual(@as(u16, 1), snapshot.row_count);
    try std.testing.expectEqual(@as(u64, 1), snapshot.rows[0].frame.timestamp_ns);

    replay.seekTo(2);
    for (0..100_000) |_| {
        if (replay.seek_completed.load(.acquire) == replay.seek_sequence.load(.acquire)) break;
        std.Thread.yield() catch {};
    }
    for (0..100_000) |_| {
        if (ingestor.readSnapshot().tx_frames_total == 1) break;
        std.Thread.yield() catch {};
    }
    try std.testing.expectEqual(@as(u64, 1), ingestor.readSnapshot().tx_frames_total);

    replay.seekTo(1);
    for (0..100_000) |_| {
        if (replay.seek_completed.load(.acquire) == replay.seek_sequence.load(.acquire)) break;
        std.Thread.yield() catch {};
    }
    for (0..100_000) |_| {
        if (ingestor.readSnapshot().frames_total == 1) break;
        std.Thread.yield() catch {};
    }
    try std.testing.expectEqual(@as(u64, 1), ingestor.readSnapshot().frames_total);
    try std.testing.expectEqual(@as(u64, 0), ingestor.readSnapshot().tx_frames_total);

    replay.stepBackward();
    const backward_sequence = replay.seek_sequence.load(.acquire) +% 1;
    for (0..100_000) |_| {
        if (replay.seek_completed.load(.acquire) == backward_sequence) break;
        std.Thread.yield() catch {};
    }
    for (0..100_000) |_| {
        if (ingestor.readSnapshot().frames_total == 0) break;
        std.Thread.yield() catch {};
    }
    try std.testing.expectEqual(@as(u64, 0), ingestor.readSnapshot().frames_total);
    try std.testing.expectEqual(@as(u64, 0), ingestor.readSnapshot().tx_frames_total);
}

test "replay restores nearest keyframe and fast-forwards from its byte offset" {
    const allocator = std.testing.allocator;
    const Diagnostics = @import("../db/database.zig").Diagnostics;
    const database_source =
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
    var database = try Database.init(allocator, .dbc, database_source, &diagnostics);
    defer database.deinit();

    const log_lines =
        "{\"type\":\"header\",\"format\":\"can_dbz_vis/log\",\"version\":1,\"created_utc\":\"2026-11-04T00:00:00Z\",\"tool\":\"test\",\"database\":null,\"buses\":[{\"index\":0,\"name\":\"can0\",\"backend\":\"virtual\",\"channel\":\"virtual0\",\"fd\":false,\"timestamps\":\"software\"}]}\n" ++
        "{\"type\":\"frame\",\"t_ns\":1,\"bus\":0,\"dir\":\"rx\",\"id\":\"0C0\",\"len\":8,\"data\":\"1027800000000000\"}\n" ++
        "not-json\n" ++
        "{\"type\":\"frame\",\"t_ns\":9000000000,\"bus\":0,\"dir\":\"rx\",\"id\":\"0C0\",\"len\":8,\"data\":\"1027800000000000\"}\n" ++
        "{\"type\":\"frame\",\"t_ns\":10000000000,\"bus\":0,\"dir\":\"tx\",\"id\":\"0C0\",\"len\":8,\"data\":\"1027800000000000\",\"status\":\"ok\"}\n" ++
        "{\"type\":\"frame\",\"t_ns\":10000000001,\"bus\":0,\"dir\":\"rx\",\"id\":\"0C0\",\"len\":8,\"data\":\"1027800000000000\"}\n";
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "keyframe-seek.canlog.jsonl", .data = log_lines });
    const path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &temporary.sub_path, "keyframe-seek.canlog.jsonl" });
    defer allocator.free(path);

    var rx_queue: rx.FrameQueue = .{};
    var tx_queue: store.TxEventQueue = .{};
    var ingestor: Ingestor = .{};
    try ingestor.attachQueue(&rx_queue);
    ingestor.attachTxQueue(&tx_queue);
    var ingest_stop: std.atomic.Value(bool) = .init(false);
    const ingest_thread = try std.Thread.spawn(.{}, runTestIngestor, .{ &ingestor, &ingest_stop });
    defer {
        ingest_stop.store(true, .release);
        ingest_thread.join();
    }

    const replay = try ReplaySource.create(allocator, std.testing.io, path, &database, &rx_queue, &tx_queue);
    defer replay.stopAndDeinit();
    replay.attachIngestor(&ingestor);
    replay.stop_requested.store(false, .release);
    replay.seek_requires_reset.store(true, .release);
    replay.performSeek(10_000_000_001, 0);

    for (0..100_000) |_| {
        const current = ingestor.readSnapshot();
        if (current.frames_total == 3 and current.tx_frames_total == 1) break;
        std.Thread.yield() catch {};
    }
    const snapshot = ingestor.readSnapshot();
    try std.testing.expectEqual(@as(u64, 3), snapshot.frames_total);
    try std.testing.expectEqual(@as(u64, 1), snapshot.tx_frames_total);
    try std.testing.expectEqual(@as(u128, 10_000_000_000), snapshot.rows[0].cycle_sum_ns);
    try std.testing.expectEqual(@as(u64, 0), replay.malformed_lines.load(.monotonic));

    try replay.start();
    for (0..100_000) |_| {
        if (replay.eof.load(.acquire)) break;
        std.Thread.yield() catch {};
    }
    replay.stepBackward();
    for (0..100_000) |_| {
        if (replay.seek_completed.load(.acquire) == 1) break;
        std.Thread.yield() catch {};
    }
    for (0..100_000) |_| {
        const current = ingestor.readSnapshot();
        if (current.frames_total == 2 and current.tx_frames_total == 1) break;
        std.Thread.yield() catch {};
    }
    try std.testing.expectEqual(@as(u64, 1), ingestor.readSnapshot().tx_frames_total);

    replay.stepBackward();
    for (0..100_000) |_| {
        if (replay.seek_completed.load(.acquire) == 2) break;
        std.Thread.yield() catch {};
    }
    for (0..100_000) |_| {
        const current = ingestor.readSnapshot();
        if (current.frames_total == 2 and current.tx_frames_total == 0) break;
        std.Thread.yield() catch {};
    }
    try std.testing.expectEqual(@as(u64, 0), ingestor.readSnapshot().tx_frames_total);

    replay.stepBackward();
    for (0..100_000) |_| {
        if (replay.seek_completed.load(.acquire) == 3) break;
        std.Thread.yield() catch {};
    }
    for (0..100_000) |_| {
        if (ingestor.readSnapshot().frames_total == 1) break;
        std.Thread.yield() catch {};
    }
    const stepped_back = ingestor.readSnapshot();
    try std.testing.expectEqual(@as(u64, 1), stepped_back.frames_total);
    try std.testing.expectEqual(@as(u64, 0), stepped_back.tx_frames_total);
}

fn runTestIngestor(ingestor: *Ingestor, stop: *const std.atomic.Value(bool)) void {
    ingestor.run(stop);
}
