const std = @import("std");
const spsc = @import("../sync/spsc.zig");
const Frame = @import("../can/frame.zig").Frame;
const format = @import("format.zig");

pub const queue_capacity = 4096;
const flush_interval_ns = 100 * std.time.ns_per_ms;
const sync_interval_ns = std.time.ns_per_s;

pub const Item = union(enum) {
    frame: format.FrameRecord,
    marker: format.Marker,
    event: format.Event,
};

pub const Queue = spsc.Spsc(Item, queue_capacity);
pub const MarkerQueue = spsc.Spsc(format.Marker, 16);

pub const Logger = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: ?std.Io.File,
    header: format.Header,
    queue: Queue,
    stop_requested: std.atomic.Value(bool),
    enabled: std.atomic.Value(bool),
    in_flight: std.atomic.Value(u32),
    failed: std.atomic.Value(bool),
    thread: ?std.Thread,
    started_ns: u64,
    records: u64,
    frames: u64,
    pending_overflow: u64,

    pub const StartError = std.Thread.SpawnError || error{AlreadyStarted};

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        header: format.Header,
    ) !*Logger {
        const self = try allocator.create(Logger);
        self.allocator = allocator;
        self.io = io;
        self.file = null;
        self.header = .{};
        self.queue = undefined;
        self.queue.write_index = .init(0);
        self.queue.read_index = .init(0);
        self.queue.dropped = .init(0);
        self.stop_requested = .init(true);
        self.enabled = .init(false);
        self.in_flight = .init(0);
        self.failed = .init(false);
        self.thread = null;
        self.started_ns = 0;
        self.records = 0;
        self.frames = 0;
        self.pending_overflow = 0;
        errdefer self.stopAndDeinit();
        try self.startNew(path, header);
        return self;
    }

    pub fn startNew(self: *Logger, path: []const u8, header: format.Header) !void {
        if (self.thread != null) return error.AlreadyStarted;
        if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(self.io, parent);
        const file = try std.Io.Dir.cwd().createFile(self.io, path, .{ .truncate = true });
        self.file = file;
        self.header = header;
        self.queue.write_index.store(0, .monotonic);
        self.queue.read_index.store(0, .monotonic);
        self.queue.dropped.store(0, .monotonic);
        self.stop_requested.store(false, .release);
        self.enabled.store(true, .release);
        self.failed.store(false, .release);
        self.started_ns = monotonicNow(self.io);
        self.records = 0;
        self.frames = 0;
        self.pending_overflow = 0;
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn enqueueFrame(self: *Logger, record: format.FrameRecord) bool {
        return self.enqueue(.{ .frame = record });
    }

    pub fn enqueueMarker(self: *Logger, timestamp_ns: u64, text: []const u8) bool {
        var marker = format.Marker{ .t_ns = timestamp_ns };
        marker.text.set(text) catch return false;
        return self.enqueue(.{ .marker = marker });
    }

    pub fn enqueueEvent(self: *Logger, event: format.Event) bool {
        return self.enqueue(.{ .event = event });
    }

    pub fn droppedCount(self: *const Logger) u64 {
        return self.queue.droppedCount() +% self.pending_overflow;
    }

    pub fn stopAndDeinit(self: *Logger) void {
        self.stop();
        self.allocator.destroy(self);
    }

    pub fn stop(self: *Logger) void {
        self.enabled.store(false, .release);
        while (self.in_flight.load(.acquire) != 0) std.Thread.yield() catch {};
        self.stop_requested.store(true, .release);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        if (self.file) |file| {
            file.close(self.io);
            self.file = null;
        }
    }

    fn enqueue(self: *Logger, item: Item) bool {
        if (!self.enabled.load(.acquire) or self.failed.load(.acquire)) return false;
        _ = self.in_flight.fetchAdd(1, .acq_rel);
        defer _ = self.in_flight.fetchSub(1, .release);
        if (!self.enabled.load(.acquire)) return false;
        return self.queue.push(item);
    }

    fn run(self: *Logger) void {
        var buffer: [64 * 1024]u8 = undefined;
        const file = self.file.?;
        var writer = file.writer(self.io, &buffer);
        var last_flush = monotonicNow(self.io);
        var last_sync = last_flush;
        var last_written_ns: u64 = 0;

        format.encode(&writer.interface, .{ .header = self.header }) catch {
            self.failed.store(true, .release);
            return;
        };
        writer.interface.flush() catch {
            self.failed.store(true, .release);
            return;
        };

        while (!self.stop_requested.load(.acquire) or self.queue.lenApprox() != 0) {
            if (self.queue.pop()) |item| {
                const timestamp = itemTimestamp(item);
                const relative_ns = @max(timestamp -| self.started_ns, last_written_ns);
                last_written_ns = relative_ns;
                writeItem(&writer.interface, item, relative_ns) catch {
                    self.failed.store(true, .release);
                    break;
                };
                if (item == .frame) self.frames +%= 1;
                self.records +%= 1;
                const now = monotonicNow(self.io);
                if (now -| last_flush >= flush_interval_ns) {
                    writer.interface.flush() catch {
                        self.failed.store(true, .release);
                        break;
                    };
                    last_flush = now;
                }
                if (now -| last_sync >= sync_interval_ns) {
                    file.sync(self.io) catch {
                        self.failed.store(true, .release);
                        break;
                    };
                    last_sync = now;
                }
                continue;
            }

            const now = monotonicNow(self.io);
            if (self.queue.droppedCount() > self.pending_overflow) {
                const newly_dropped = self.queue.droppedCount() - self.pending_overflow;
                self.pending_overflow += newly_dropped;
                _ = self.writeOverflow(&writer.interface, now -| self.started_ns, newly_dropped);
            }
            if (now -| last_flush >= flush_interval_ns) {
                writer.interface.flush() catch {
                    self.failed.store(true, .release);
                    break;
                };
                last_flush = now;
            }
            if (now -| last_sync >= sync_interval_ns) {
                file.sync(self.io) catch {
                    self.failed.store(true, .release);
                    break;
                };
                last_sync = now;
            }
            std.Thread.yield() catch {};
        }

        if (!self.failed.load(.acquire)) {
            const now = monotonicNow(self.io);
            const footer = format.Footer{
                .t_ns = now -| self.started_ns,
                .records = self.records + 1,
                .frames = self.frames,
                .dropped = self.queue.droppedCount(),
            };
            format.encode(&writer.interface, .{ .footer = footer }) catch self.failed.store(true, .release);
            writer.interface.flush() catch self.failed.store(true, .release);
            file.sync(self.io) catch self.failed.store(true, .release);
        }
    }

    fn writeItem(writer: *std.Io.Writer, item: Item, timestamp_ns: u64) !void {
        switch (item) {
            .frame => |source| {
                var record = source;
                record.t_ns = timestamp_ns;
                record.frame.timestamp_ns = timestamp_ns;
                try format.encode(writer, .{ .frame = record });
            },
            .marker => |source| {
                var marker = source;
                marker.t_ns = timestamp_ns;
                try format.encode(writer, .{ .marker = marker });
            },
            .event => |source| {
                var event = source;
                event.t_ns = timestamp_ns;
                try format.encode(writer, .{ .event = event });
            },
        }
    }

    fn writeOverflow(self: *Logger, writer: *std.Io.Writer, timestamp_ns: u64, count: u64) bool {
        var event = format.Event{ .t_ns = timestamp_ns, .dropped = count };
        event.name.set("log_overflow") catch return false;
        format.encode(writer, .{ .event = event }) catch {
            self.failed.store(true, .release);
            return false;
        };
        self.records +%= 1;
        return true;
    }
};

fn monotonicNow(io: std.Io) u64 {
    const value = std.Io.Clock.awake.now(io).nanoseconds;
    return @intCast(@max(value, 0));
}

fn itemTimestamp(item: Item) u64 {
    return switch (item) {
        .frame => |record| record.t_ns,
        .marker => |record| record.t_ns,
        .event => |record| record.t_ns,
    };
}

test "logger writes header, frame, and footer as JSONL" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &temporary.sub_path });
    defer allocator.free(directory_path);
    const path = try std.fs.path.join(allocator, &.{ directory_path, "recording.canlog.jsonl" });
    defer allocator.free(path);

    var header = format.Header{};
    try header.created_utc.set("2026-11-04T00:00:00.000000000Z");
    try header.tool.set("can_dbz_vis test");
    header.bus_count = 1;
    header.buses[0].index = 0;
    try header.buses[0].name.set("can0");
    try header.buses[0].backend.set("virtual");
    try header.buses[0].channel.set("virtual0");

    const logger = try Logger.create(allocator, std.testing.io, path, header);
    const frame = Frame{
        .timestamp_ns = monotonicNow(std.testing.io),
        .id = 0x321,
        .bus = 0,
        .len = 2,
        .flags = .{},
        ._pad = 0,
        .data = .{ 0x12, 0x34 } ++ @as([62]u8, @splat(0)),
    };
    try std.testing.expect(logger.enqueueFrame(.{ .t_ns = frame.timestamp_ns, .bus = 0, .direction = .rx, .frame = frame }));
    logger.stopAndDeinit();

    const contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(64 * 1024));
    defer allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"type\":\"header\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"type\":\"frame\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"type\":\"footer\"") != null);
}
