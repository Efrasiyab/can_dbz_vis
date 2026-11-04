const std = @import("std");
const adapter = @import("../can/adapter.zig");
const Frame = @import("../can/frame.zig").Frame;
const clock = @import("../sync/clock.zig");
const ingest = @import("ingest.zig");
const rx = @import("rx.zig");
const store = @import("store.zig");
const tx = @import("tx.zig");
const plot = @import("plot.zig");
const can_dbz = @import("can_dbz");
const log_writer = @import("../log/writer.zig");
const log_format = @import("../log/format.zig");

pub const max_channels = ingest.max_channels;

const Channel = struct {
    device: ?adapter.Adapter = null,
    bus_index: u8 = 0,
    info: ?adapter.ChannelInfo = null,
    queue: rx.FrameQueue = .{},
    frames_read: std.atomic.Value(u64) = .init(0),
    errors: std.atomic.Value(u64) = .init(0),
    receiver: ?rx.Receiver = null,
};

pub const Engine = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    channels: [max_channels]Channel = @splat(.{}),
    channel_count: usize = 0,
    replay_queue: rx.FrameQueue = .{},
    replay_enabled: bool = false,
    tx_adapters: [max_channels]?tx.AdapterSlot = @splat(null),
    tx_commands: tx.CommandQueue = .{},
    tx_events: tx.EventQueue = .{},
    log_markers: log_writer.MarkerQueue = .{},
    tx_stop: std.atomic.Value(bool) = .init(true),
    tx_worker: ?tx.Worker = null,
    active_tx_jobs: std.atomic.Value(u32) = .init(0),
    skipped_tx_sends: std.atomic.Value(u64) = .init(0),
    plot_config: ?*const plot.Config = null,
    plot_samples: ?*plot.SampleQueue = null,
    compiled_database: ?*const can_dbz.compile.CompiledDatabase = null,
    logger: ?*log_writer.Logger = null,
    ingestor: ingest.Ingestor = .{},
    rx_stop: std.atomic.Value(bool) = .init(true),
    ingest_stop: std.atomic.Value(bool) = .init(true),
    ingest_thread: ?std.Thread = null,
    started: bool = false,
    stopped: bool = false,

    pub const AddError = error{EngineStarted} || ingest.Ingestor.AttachError;
    pub const StartError = error{ EngineStarted, EngineStopped, NoChannels } ||
        std.Thread.SpawnError ||
        rx.Receiver.StartError ||
        tx.Worker.StartError;

    pub fn create(allocator: std.mem.Allocator, io: std.Io) std.mem.Allocator.Error!*Engine {
        const self = try allocator.create(Engine);
        self.* = .{ .allocator = allocator, .io = io };
        self.ingestor.attachTxQueue(&self.tx_events);
        self.ingestor.attachMarkerQueue(&self.log_markers);
        return self;
    }

    pub fn addAdapter(self: *Engine, device: adapter.Adapter, bus_index: u8) AddError!void {
        return self.addAdapterInternal(device, bus_index, null);
    }

    pub fn attachReplayQueue(self: *Engine) (ingest.Ingestor.AttachError || error{EngineStarted})!*rx.FrameQueue {
        if (self.started or self.stopped) return error.EngineStarted;
        if (self.replay_enabled) return &self.replay_queue;
        try self.ingestor.attachQueue(&self.replay_queue);
        self.replay_enabled = true;
        return &self.replay_queue;
    }

    pub fn addAdapterWithInfo(self: *Engine, device: adapter.Adapter, bus_index: u8, info: adapter.ChannelInfo) AddError!void {
        return self.addAdapterInternal(device, bus_index, info);
    }

    fn addAdapterInternal(self: *Engine, device: adapter.Adapter, bus_index: u8, info: ?adapter.ChannelInfo) AddError!void {
        if (self.started or self.stopped) return error.EngineStarted;
        if (self.channel_count == max_channels) return error.TooManyChannels;

        const channel = &self.channels[self.channel_count];
        channel.device = device;
        channel.bus_index = bus_index;
        channel.info = info;
        self.ingestor.attachQueue(&channel.queue) catch |err| {
            channel.device = null;
            return err;
        };
        self.tx_adapters[self.channel_count] = .{ .device = &channel.device.?, .bus_index = bus_index };
        self.channel_count += 1;
    }

    pub fn channelInfo(self: *const Engine, bus_index: u8) ?adapter.ChannelInfo {
        for (self.channels[0..self.channel_count]) |channel| {
            if (channel.bus_index == bus_index) return channel.info;
        }
        return null;
    }

    pub fn start(self: *Engine) StartError!void {
        if (self.started) return error.EngineStarted;
        if (self.stopped) return error.EngineStopped;
        if (self.channel_count == 0 and !self.replay_enabled) return error.NoChannels;

        self.rx_stop.store(false, .release);
        self.ingest_stop.store(false, .release);
        self.ingest_thread = try std.Thread.spawn(.{}, runIngest, .{ &self.ingestor, &self.ingest_stop });

        for (0..self.channel_count) |index| {
            const channel = &self.channels[index];
            channel.receiver = .{
                .device = &channel.device.?,
                .queue = &channel.queue,
                .bus_index = channel.bus_index,
                .stop = &self.rx_stop,
                .frames_read = &channel.frames_read,
                .errors = &channel.errors,
            };
            channel.receiver.?.start() catch |err| {
                self.rollbackStart(index);
                return err;
            };
        }
        if (self.channel_count != 0) {
            self.tx_stop.store(false, .release);
            self.tx_worker = .{
                .io = self.io,
                .adapters = &self.tx_adapters,
                .adapter_count = &self.channel_count,
                .commands = &self.tx_commands,
                .events = &self.tx_events,
                .stop = &self.tx_stop,
                .active_jobs = &self.active_tx_jobs,
                .skipped_sends = &self.skipped_tx_sends,
            };
            self.tx_worker.?.start() catch |err| {
                self.rollbackStart(self.channel_count);
                return err;
            };
        }
        self.started = true;
    }

    pub fn stop(self: *Engine) void {
        if (!self.started) return;

        self.rx_stop.store(true, .release);
        self.joinReceivers();
        self.tx_stop.store(true, .release);
        if (self.tx_worker) |*worker| worker.join();
        self.tx_worker = null;
        self.ingest_stop.store(true, .release);
        if (self.ingest_thread) |thread| {
            thread.join();
            self.ingest_thread = null;
        }
        self.started = false;
        self.stopped = true;
    }

    pub fn deinit(self: *Engine) void {
        self.stop();
        if (self.logger) |logger| {
            logger.stopAndDeinit();
            self.logger = null;
        }
        for (self.channels[0..self.channel_count]) |*channel| {
            if (channel.device) |*device| device.deinit();
            channel.device = null;
        }
        self.allocator.destroy(self);
    }

    pub fn clearAdapters(self: *Engine) void {
        self.stop();
        for (self.channels[0..self.channel_count]) |*channel| {
            if (channel.device) |*device| device.deinit();
        }
        self.channels = @splat(.{});
        self.channel_count = 0;
        self.replay_queue = .{};
        self.replay_enabled = false;
        self.tx_adapters = @splat(null);
        self.tx_commands = .{};
        self.tx_events = .{};
        self.tx_worker = null;
        self.active_tx_jobs.store(0, .release);
        self.skipped_tx_sends.store(0, .release);
        self.ingestor = .{};
        self.ingestor.attachTxQueue(&self.tx_events);
        if (self.replay_enabled) self.ingestor.attachQueue(&self.replay_queue) catch unreachable;
        self.ingestor.attachMarkerQueue(&self.log_markers);
        if (self.plot_config) |config| self.ingestor.attachPlot(config, self.plot_samples.?, self.compiled_database.?);
        self.ingestor.attachLogger(self.logger);
        self.rx_stop.store(true, .release);
        self.ingest_stop.store(true, .release);
        self.ingest_thread = null;
        self.started = false;
        self.stopped = false;
    }

    pub fn attachPlot(self: *Engine, config: *const plot.Config, samples: *plot.SampleQueue, database: *const can_dbz.compile.CompiledDatabase) void {
        self.plot_config = config;
        self.plot_samples = samples;
        self.compiled_database = database;
        self.ingestor.attachPlot(config, samples, database);
    }

    pub fn startLogging(self: *Engine, path: []const u8, header: log_format.Header) anyerror!void {
        if (self.logger) |logger| {
            try logger.startNew(path, header);
        } else {
            self.logger = try log_writer.Logger.create(self.allocator, self.io, path, header);
        }
        self.ingestor.attachLogger(self.logger.?);
    }

    pub fn stopLogging(self: *Engine) void {
        if (self.logger) |logger| logger.stop();
    }

    pub fn isLogging(self: *const Engine) bool {
        if (self.logger) |logger| return logger.enabled.load(.acquire);
        return false;
    }

    pub fn enqueueLogMarker(self: *Engine, text: []const u8) bool {
        if (!self.isLogging()) return false;
        var marker = log_format.Marker{ .t_ns = clock.nowNs(self.io) };
        marker.text.set(text) catch return false;
        return self.log_markers.push(marker);
    }

    pub fn enqueueTx(self: *Engine, command: tx.Command) bool {
        if (!self.started or self.channel_count == 0) return false;
        return self.tx_commands.push(command);
    }

    pub fn sendOnce(self: *Engine, job: tx.Job) bool {
        return self.enqueueTx(.{ .send_once = job });
    }

    pub fn startPeriodic(self: *Engine, job: tx.Job) bool {
        return self.enqueueTx(.{ .start_periodic = job });
    }

    pub fn updatePeriodic(self: *Engine, job: tx.Job) bool {
        return self.enqueueTx(.{ .update = job });
    }

    pub fn stopPeriodic(self: *Engine, job_id: u16) bool {
        return self.enqueueTx(.{ .stop = job_id });
    }

    pub fn stopAllPeriodic(self: *Engine) bool {
        return self.enqueueTx(.stop_all);
    }

    pub fn isBusConnected(self: *const Engine, bus_index: u8) bool {
        for (self.tx_adapters[0..self.channel_count]) |slot| {
            if (slot) |connected| if (connected.bus_index == bus_index) return true;
        }
        return false;
    }

    pub fn channelStatus(self: *const Engine, bus_index: u8) ?adapter.Status {
        for (self.channels[0..self.channel_count]) |channel| {
            if (channel.bus_index == bus_index) {
                if (channel.device) |device| return device.status();
            }
        }
        return null;
    }

    pub fn activeTxJobs(self: *const Engine) u32 {
        return self.active_tx_jobs.load(.acquire);
    }

    pub fn skippedTxSends(self: *const Engine) u64 {
        return self.skipped_tx_sends.load(.monotonic);
    }

    pub fn readSnapshot(self: *Engine) store.Snapshot {
        return self.ingestor.readSnapshot();
    }

    pub fn droppedCount(self: *const Engine) u64 {
        return self.ingestor.droppedCount();
    }

    pub fn framesRead(self: *const Engine) u64 {
        var total: u64 = 0;
        for (self.channels[0..self.channel_count]) |channel| {
            total +%= channel.frames_read.load(.monotonic);
        }
        return total;
    }

    pub fn errorCount(self: *const Engine) u64 {
        var total: u64 = 0;
        for (self.channels[0..self.channel_count]) |channel| {
            total +%= channel.errors.load(.monotonic);
        }
        return total;
    }

    fn rollbackStart(self: *Engine, started_receivers: usize) void {
        self.rx_stop.store(true, .release);
        for (self.channels[0..started_receivers]) |*channel| {
            if (channel.receiver) |*receiver| receiver.join();
        }
        self.tx_stop.store(true, .release);
        if (self.tx_worker) |*worker| worker.join();
        self.tx_worker = null;
        self.ingest_stop.store(true, .release);
        if (self.ingest_thread) |thread| {
            thread.join();
            self.ingest_thread = null;
        }
        for (self.channels[0..self.channel_count]) |*channel| channel.receiver = null;
    }

    fn joinReceivers(self: *Engine) void {
        for (self.channels[0..self.channel_count]) |*channel| {
            if (channel.receiver) |*receiver| receiver.join();
        }
    }
};

fn runIngest(ingestor: *ingest.Ingestor, stop: *const std.atomic.Value(bool)) void {
    ingestor.run(stop);
}

test "engine starts workers, ingests virtual frames, and stops within deadline" {
    const allocator = std.testing.allocator;
    var sender = try @import("../can/virtual.zig").backend.open(allocator, .{ .channel = "virtual0" });
    defer sender.deinit();

    const engine = try Engine.create(allocator, std.testing.io);
    try engine.addAdapter(try @import("../can/virtual.zig").backend.open(allocator, .{ .channel = "virtual0" }), 0);
    try engine.start();

    const frame = Frame{
        .timestamp_ns = 10,
        .id = 0x321,
        .bus = 0,
        .len = 2,
        .flags = .{},
        ._pad = 0,
        .data = .{ 0x12, 0x34 } ++ @as([62]u8, @splat(0)),
    };
    for (0..64) |_| try sender.write(&frame, 0);

    var snapshot = engine.readSnapshot();
    for (0..100_000) |_| {
        if (snapshot.frames_total == 64) break;
        std.Thread.yield() catch {};
        snapshot = engine.readSnapshot();
    }
    try std.testing.expectEqual(@as(u64, 64), snapshot.frames_total);
    try std.testing.expectEqual(@as(u64, 0), engine.droppedCount());

    const stop_start = clock.nowNs(std.testing.io);
    engine.stop();
    const stop_duration = clock.nowNs(std.testing.io) - stop_start;
    try std.testing.expect(stop_duration < 100 * std.time.ns_per_ms);
    engine.deinit();
}

test "engine sends one-shot and periodic jobs into the Sent snapshot" {
    const allocator = std.testing.allocator;
    var receiver = try @import("../can/virtual.zig").backend.open(allocator, .{ .channel = "virtual0" });
    defer receiver.deinit();

    const engine = try Engine.create(allocator, std.testing.io);
    defer engine.deinit();
    try engine.addAdapter(try @import("../can/virtual.zig").backend.open(allocator, .{ .channel = "virtual0" }), 0);
    try engine.start();

    const frame = Frame{
        .timestamp_ns = 0,
        .id = 0x123,
        .bus = 0,
        .len = 2,
        .flags = .{},
        ._pad = 0,
        .data = .{ 0xAA, 0x55 } ++ @as([62]u8, @splat(0)),
    };
    try std.testing.expect(engine.sendOnce(.{ .id = 1, .bus_index = 0, .frame = frame }));

    var snapshot = engine.readSnapshot();
    for (0..100_000) |_| {
        if (snapshot.sent_count >= 1) break;
        std.Thread.yield() catch {};
        snapshot = engine.readSnapshot();
    }
    try std.testing.expectEqual(@as(u16, 1), snapshot.sent_count);
    try std.testing.expectEqual(store.TxStatus.ok, snapshot.sent[0].status);
    var received: [1]Frame = undefined;
    try std.testing.expectEqual(@as(usize, 1), try receiver.read(&received, 0));
    try std.testing.expectEqual(frame.id, received[0].id);

    try std.testing.expect(engine.startPeriodic(.{ .id = 2, .bus_index = 0, .frame = frame, .period_ns = 10 * std.time.ns_per_ms }));
    snapshot = engine.readSnapshot();
    for (0..100_000) |_| {
        if (snapshot.tx_frames_total >= 4) break;
        std.Thread.yield() catch {};
        snapshot = engine.readSnapshot();
    }
    try std.testing.expect(snapshot.tx_frames_total >= 4);
    try std.testing.expect(engine.stopPeriodic(2));
    for (0..100_000) |_| {
        if (engine.activeTxJobs() == 0) break;
        std.Thread.yield() catch {};
    }
    try std.testing.expectEqual(@as(u32, 0), engine.activeTxJobs());
    try std.testing.expectEqual(@as(u64, 0), engine.droppedCount());
}

test "Engine TX scheduler round-trips over vcan0 when available" {
    const allocator = std.testing.allocator;
    const backend = @import("../can/registry.zig").find("socketcan") orelse return error.SkipZigTest;
    const channels = try backend.enumerate(allocator);
    defer allocator.free(channels);
    var has_vcan0 = false;
    for (channels) |channel| {
        if (std.mem.eql(u8, channel.nameSlice(), "vcan0")) has_vcan0 = true;
    }
    if (!has_vcan0) return error.SkipZigTest;

    var receiver = try backend.open(allocator, .{ .channel = "vcan0" });
    defer receiver.deinit();
    const engine = try Engine.create(allocator, std.testing.io);
    defer engine.deinit();
    try engine.addAdapter(try backend.open(allocator, .{ .channel = "vcan0" }), 0);
    try engine.start();

    const frame = Frame{
        .timestamp_ns = 0,
        .id = 0x456,
        .bus = 0,
        .len = 2,
        .flags = .{},
        ._pad = 0,
        .data = .{ 0xA5, 0x5A } ++ @as([62]u8, @splat(0)),
    };
    try std.testing.expect(engine.sendOnce(.{ .id = 3, .bus_index = 0, .frame = frame }));

    var snapshot = engine.readSnapshot();
    for (0..100_000) |_| {
        if (snapshot.sent_count != 0) break;
        std.Thread.yield() catch {};
        snapshot = engine.readSnapshot();
    }
    try std.testing.expect(snapshot.sent_count != 0);
    try std.testing.expectEqual(store.TxStatus.ok, snapshot.sent[snapshot.sent_count - 1].status);
    var received: [1]Frame = undefined;
    try std.testing.expectEqual(@as(usize, 1), try receiver.read(&received, 50 * std.time.ns_per_ms));
    try std.testing.expectEqual(frame.id, received[0].id);
    try std.testing.expectEqualSlices(u8, frame.data[0..frame.len], received[0].data[0..received[0].len]);
}

test "Engine records virtual RX frames with header and footer" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &temporary.sub_path });
    defer allocator.free(directory_path);
    const path = try std.fs.path.join(allocator, &.{ directory_path, "engine.canlog.jsonl" });
    defer allocator.free(path);

    var sender = try @import("../can/virtual.zig").backend.open(allocator, .{ .channel = "virtual0" });
    defer sender.deinit();
    const engine = try Engine.create(allocator, std.testing.io);
    defer engine.deinit();
    try engine.addAdapter(try @import("../can/virtual.zig").backend.open(allocator, .{ .channel = "virtual0" }), 0);

    var header = log_format.Header{};
    try header.created_utc.set("2026-11-04T00:00:00.000000000Z");
    try header.tool.set("can_dbz_vis test");
    header.bus_count = 1;
    header.buses[0].index = 0;
    try header.buses[0].name.set("can0");
    try engine.startLogging(path, header);
    try engine.start();

    const frame = Frame{
        .timestamp_ns = clock.nowNs(std.testing.io),
        .id = 0x321,
        .bus = 0,
        .len = 2,
        .flags = .{},
        ._pad = 0,
        .data = .{ 0x12, 0x34 } ++ @as([62]u8, @splat(0)),
    };
    try sender.write(&frame, 0);
    for (0..100_000) |_| {
        if (engine.framesRead() != 0) break;
        std.Thread.yield() catch {};
    }
    try std.testing.expectEqual(@as(u64, 1), engine.framesRead());
    engine.stop();
    engine.stopLogging();

    const contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(64 * 1024));
    defer allocator.free(contents);
    var lines = std.mem.splitScalar(u8, contents, '\n');
    var header_seen = false;
    var frame_seen = false;
    var footer_seen = false;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const record = (try log_format.decodeLine(line)) orelse continue;
        switch (record) {
            .header => header_seen = true,
            .frame => |logged| {
                frame_seen = true;
                try std.testing.expectEqual(@as(u32, 0x321), logged.frame.id);
                try std.testing.expectEqual(@as(u8, 0x12), logged.frame.data[0]);
            },
            .footer => footer_seen = true,
            else => {},
        }
    }
    try std.testing.expect(header_seen and frame_seen and footer_seen);
}
