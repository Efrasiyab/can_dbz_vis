const std = @import("std");
const format = @import("format.zig");
const store = @import("../engine/store.zig");

pub const seek_interval_ns = 250 * std.time.ns_per_ms;
pub const keyframe_interval_ns = 10 * std.time.ns_per_s;
const keyframe_row_capacity = store.max_message_table_entries;
const Table = store.MessageTable(keyframe_row_capacity, 1024);

pub const SeekPoint = struct {
    t_ns: u64,
    byte_offset: u64,
};

pub const MarkerPoint = struct {
    t_ns: u64,
    byte_offset: u64,
    text: format.Text(256),
};

pub const Keyframe = struct {
    t_ns: u64,
    byte_offset: u64,
    snapshot: store.Snapshot,
    rows: []store.MessageRow = &.{},
    backstep_target: ?BackstepTarget = null,
};

pub const BackstepTarget = struct {
    t_ns: u64,
    byte_offset: u64,
    stop_before: bool = false,
};

pub const Index = struct {
    allocator: std.mem.Allocator,
    data_offset: u64,
    seek_points: std.ArrayListUnmanaged(SeekPoint) = .empty,
    markers: std.ArrayListUnmanaged(MarkerPoint) = .empty,
    keyframes: std.ArrayListUnmanaged(Keyframe) = .empty,
    duration_ns: u64 = 0,
    frame_count: u64 = 0,
    malformed_lines: u64 = 0,

    pub const CreateError = std.Io.File.OpenError || std.Io.File.Reader.SeekError || std.mem.Allocator.Error || error{ Canceled, ReadFailed, StreamTooLong };

    pub fn create(allocator: std.mem.Allocator, io: std.Io, path: []const u8, data_offset: u64) CreateError!Index {
        return createWithProgress(allocator, io, path, data_offset, null, null);
    }

    pub fn createWithProgress(
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        data_offset: u64,
        bytes_scanned: ?*std.atomic.Value(u64),
        cancel: ?*const std.atomic.Value(bool),
    ) CreateError!Index {
        var result = Index{ .allocator = allocator, .data_offset = data_offset };
        errdefer result.deinit();
        var rx_table: Table = .{};
        var sent_events: [store.max_snapshot_trace]store.TxEvent = undefined;
        var sent_write: usize = 0;
        var sent_len: usize = 0;
        var tx_frames_total: u64 = 0;
        var next_keyframe_ns: u64 = keyframe_interval_ns;
        var previous_frame: ?SeekPoint = null;
        var last_frame: ?SeekPoint = null;
        try result.keyframes.append(allocator, .{ .t_ns = 0, .byte_offset = data_offset, .snapshot = .{} });

        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        var buffer: [format.max_line_bytes]u8 = undefined;
        var reader = std.Io.File.Reader.init(file, io, &buffer);
        try reader.seekTo(data_offset);

        var next_seek_ns: u64 = 0;
        while (true) {
            if (cancel) |flag| if (flag.load(.acquire)) return error.Canceled;
            const byte_offset = reader.logicalPos();
            if (bytes_scanned) |progress| progress.store(byte_offset -| data_offset, .release);
            const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.EndOfStream => break,
                error.StreamTooLong => {
                    _ = reader.interface.discardDelimiterInclusive('\n') catch |discard_err| switch (discard_err) {
                        error.EndOfStream => break,
                        else => return error.ReadFailed,
                    };
                    result.malformed_lines +%= 1;
                    continue;
                },
                else => return err,
            };
            const record = format.decodeLine(line[0 .. line.len - 1]) catch {
                result.malformed_lines +%= 1;
                continue;
            };
            const value = record orelse continue;
            switch (value) {
                .frame => |frame| {
                    while (frame.t_ns >= next_keyframe_ns) {
                        const backstep_target: ?BackstepTarget = if (previous_frame) |prior|
                            .{ .t_ns = prior.t_ns, .byte_offset = prior.byte_offset }
                        else if (last_frame != null)
                            .{ .t_ns = 0, .byte_offset = data_offset, .stop_before = true }
                        else
                            null;
                        try result.appendKeyframe(allocator, next_keyframe_ns, byte_offset, &rx_table, &sent_events, sent_write, sent_len, tx_frames_total, backstep_target);
                        next_keyframe_ns +|= keyframe_interval_ns;
                    }
                    result.frame_count +%= 1;
                    result.duration_ns = @max(result.duration_ns, frame.t_ns);
                    if (result.seek_points.items.len == 0 or frame.t_ns >= next_seek_ns) {
                        try result.seek_points.append(allocator, .{ .t_ns = frame.t_ns, .byte_offset = byte_offset });
                        next_seek_ns = frame.t_ns +| seek_interval_ns;
                    }
                    if (frame.direction == .rx) {
                        _ = rx_table.update(frame.frame);
                    } else {
                        sent_events[sent_write & (store.max_snapshot_trace - 1)] = .{
                            .frame = frame.frame,
                            .status = txStatus(frame.status),
                            .timestamp_ns = frame.frame.timestamp_ns,
                        };
                        sent_write +%= 1;
                        sent_len = @min(sent_len + 1, store.max_snapshot_trace);
                        tx_frames_total +%= 1;
                    }
                    previous_frame = last_frame;
                    last_frame = .{ .t_ns = frame.t_ns, .byte_offset = byte_offset };
                },
                .marker => |marker| {
                    try result.markers.append(allocator, .{
                        .t_ns = marker.t_ns,
                        .byte_offset = byte_offset,
                        .text = marker.text,
                    });
                    result.duration_ns = @max(result.duration_ns, marker.t_ns);
                },
                .event => |event| result.duration_ns = @max(result.duration_ns, event.t_ns),
                .footer => |footer| result.duration_ns = @max(result.duration_ns, footer.t_ns),
                .header => {},
            }
        }
        if (bytes_scanned) |progress| progress.store(reader.logicalPos() -| data_offset, .release);
        return result;
    }

    pub fn deinit(self: *Index) void {
        self.seek_points.deinit(self.allocator);
        self.markers.deinit(self.allocator);
        for (self.keyframes.items) |keyframe| {
            if (keyframe.rows.len != 0) self.allocator.free(keyframe.rows);
        }
        self.keyframes.deinit(self.allocator);
    }

    pub fn offsetAtOrBefore(self: *const Index, timestamp_ns: u64) u64 {
        var offset = self.data_offset;
        for (self.seek_points.items) |point| {
            if (point.t_ns > timestamp_ns) break;
            offset = point.byte_offset;
        }
        return offset;
    }

    pub fn markerAtOrAfter(self: *const Index, timestamp_ns: u64) ?MarkerPoint {
        for (self.markers.items) |marker| {
            if (marker.t_ns >= timestamp_ns) return marker;
        }
        return null;
    }

    pub fn markerBefore(self: *const Index, timestamp_ns: u64) ?MarkerPoint {
        var previous: ?MarkerPoint = null;
        for (self.markers.items) |marker| {
            if (marker.t_ns >= timestamp_ns) break;
            previous = marker;
        }
        return previous;
    }

    pub fn keyframeAtOrBefore(self: *const Index, timestamp_ns: u64) ?*const Keyframe {
        var previous: ?*const Keyframe = null;
        for (self.keyframes.items) |*keyframe| {
            if (keyframe.t_ns > timestamp_ns) break;
            previous = keyframe;
        }
        return previous;
    }

    fn appendKeyframe(
        self: *Index,
        allocator: std.mem.Allocator,
        t_ns: u64,
        byte_offset: u64,
        rx_table: *const Table,
        sent_events: *const [store.max_snapshot_trace]store.TxEvent,
        sent_write: usize,
        sent_len: usize,
        tx_frames_total: u64,
        backstep_target: ?BackstepTarget,
    ) std.mem.Allocator.Error!void {
        var snapshot: store.Snapshot = .{};
        rx_table.publish(&snapshot, self.keyframes.items.len);
        var rows_buffer: [keyframe_row_capacity]store.MessageRow = undefined;
        const row_count = rx_table.copyRows(&rows_buffer);
        const rows = try allocator.dupe(store.MessageRow, rows_buffer[0..row_count]);
        errdefer allocator.free(rows);
        snapshot.tx_frames_total = tx_frames_total;
        snapshot.sent_count = @intCast(sent_len);
        const first_sent = sent_write -% sent_len;
        for (0..sent_len) |index| snapshot.sent[index] = sent_events[(first_sent + index) & (store.max_snapshot_trace - 1)];
        try self.keyframes.append(allocator, .{
            .t_ns = t_ns,
            .byte_offset = byte_offset,
            .snapshot = snapshot,
            .rows = rows,
            .backstep_target = backstep_target,
        });
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

test "log index records duration, sparse seek points, markers, and complete lines" {
    const allocator = std.testing.allocator;
    const contents =
        "{\"type\":\"header\",\"format\":\"can_dbz_vis/log\",\"version\":1,\"created_utc\":\"test\",\"tool\":\"test\",\"database\":null,\"buses\":[]}\n" ++
        "{\"type\":\"frame\",\"t_ns\":0,\"bus\":0,\"dir\":\"rx\",\"id\":\"123\",\"len\":0,\"data\":\"\"}\n" ++
        "not-json\n" ++
        "{\"type\":\"marker\",\"t_ns\":200000000,\"text\":\"pit\"}\n" ++
        "{\"type\":\"frame\",\"t_ns\":300000000,\"bus\":0,\"dir\":\"rx\",\"id\":\"123\",\"len\":0,\"data\":\"\"}\n" ++
        "{\"type\":\"frame\",\"t_ns\":400000000,\"bus\":0,\"dir\":\"rx\",\"id\":\"123\",\"len\":0,\"data\":\"\"}";
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "index.canlog.jsonl", .data = contents });
    const path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &temporary.sub_path, "index.canlog.jsonl" });
    defer allocator.free(path);

    var bytes_scanned: std.atomic.Value(u64) = .init(0);
    const data_offset = std.mem.indexOfScalar(u8, contents, '\n').? + 1;
    var index = try Index.createWithProgress(allocator, std.testing.io, path, data_offset, &bytes_scanned, null);
    defer index.deinit();
    try std.testing.expect(bytes_scanned.load(.acquire) > 0);
    try std.testing.expect(bytes_scanned.load(.acquire) <= contents.len - data_offset);
    try std.testing.expectEqual(@as(u64, 2), index.frame_count);
    try std.testing.expectEqual(@as(u64, 300_000_000), index.duration_ns);
    try std.testing.expectEqual(@as(u64, 1), index.malformed_lines);
    try std.testing.expectEqual(@as(usize, 2), index.seek_points.items.len);
    try std.testing.expectEqual(@as(u64, 200_000_000), index.markerAtOrAfter(100_000_000).?.t_ns);
    try std.testing.expectEqual(@as(u64, 200_000_000), index.markerBefore(250_000_000).?.t_ns);
}

test "log index keyframes preserve state immediately before each boundary" {
    const allocator = std.testing.allocator;
    const contents =
        "{\"type\":\"header\",\"format\":\"can_dbz_vis/log\",\"version\":1,\"created_utc\":\"test\",\"tool\":\"test\",\"database\":null,\"buses\":[]}\n" ++
        "{\"type\":\"frame\",\"t_ns\":1,\"bus\":0,\"dir\":\"rx\",\"id\":\"123\",\"len\":0,\"data\":\"\"}\n" ++
        "{\"type\":\"frame\",\"t_ns\":9000000000,\"bus\":0,\"dir\":\"rx\",\"id\":\"123\",\"len\":0,\"data\":\"\"}\n" ++
        "{\"type\":\"frame\",\"t_ns\":10000000000,\"bus\":0,\"dir\":\"tx\",\"id\":\"123\",\"len\":0,\"data\":\"\",\"status\":\"ok\"}\n";
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "keyframes.canlog.jsonl", .data = contents });
    const path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &temporary.sub_path, "keyframes.canlog.jsonl" });
    defer allocator.free(path);

    var index = try Index.create(allocator, std.testing.io, path, std.mem.indexOfScalar(u8, contents, '\n').? + 1);
    defer index.deinit();
    try std.testing.expectEqual(@as(usize, 2), index.keyframes.items.len);
    const keyframe = index.keyframeAtOrBefore(keyframe_interval_ns).?;
    try std.testing.expectEqual(keyframe_interval_ns, keyframe.t_ns);
    try std.testing.expectEqual(@as(u64, 2), keyframe.snapshot.frames_total);
    try std.testing.expectEqual(@as(u64, 0), keyframe.snapshot.tx_frames_total);
    try std.testing.expectEqual(@as(u32, 0x123), keyframe.snapshot.rows[0].frame.id);
    try std.testing.expectEqual(@as(usize, 1), keyframe.rows.len);
    try std.testing.expectEqual(@as(u64, 1), keyframe.backstep_target.?.t_ns);
    try std.testing.expect(!keyframe.backstep_target.?.stop_before);
}
