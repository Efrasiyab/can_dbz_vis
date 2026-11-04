const std = @import("std");
const can_dbz = @import("can_dbz");
const Frame = @import("can/frame.zig").Frame;
const Database = @import("db/database.zig").Database;
const rx = @import("engine/rx.zig");
const clock = @import("sync/clock.zig");

pub const frame_interval_ns = 20 * std.time.ns_per_ms;

pub const Source = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    database: *const Database,
    queue: *rx.FrameQueue,
    stop_requested: std.atomic.Value(bool) = .init(true),
    sequence: u64 = 0,
    thread: ?std.Thread = null,

    pub const StartError = std.Thread.SpawnError || error{AlreadyStarted};

    pub fn create(allocator: std.mem.Allocator, io: std.Io, database: *const Database, queue: *rx.FrameQueue) std.mem.Allocator.Error!*Source {
        const source = try allocator.create(Source);
        source.* = .{ .allocator = allocator, .io = io, .database = database, .queue = queue };
        return source;
    }

    pub fn start(self: *Source) StartError!void {
        if (self.thread != null) return error.AlreadyStarted;
        self.stop_requested.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn stopAndDeinit(self: *Source) void {
        self.stop();
        self.allocator.destroy(self);
    }

    pub fn stop(self: *Source) void {
        self.stop_requested.store(true, .release);
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    pub fn nextFrame(self: *Source, timestamp_ns: u64) ?Frame {
        if (self.database.compiled.messages.len == 0) return null;
        const message_index = self.sequence % self.database.compiled.messages.len;
        const message = self.database.compiled.messages[message_index];
        const bus_index = busIndex(self.database, message.bus) orelse return null;
        var frame = Frame{
            .timestamp_ns = timestamp_ns,
            .id = message.id,
            .bus = bus_index,
            .len = @intCast(message.length),
            .flags = .{
                .extended = message.extended,
                .fd = message.frame == .fd,
                .brs = message.frame == .fd,
            },
            ._pad = 0,
            .data = @splat(0),
        };
        fillPayload(&frame, self.sequence);
        self.sequence +%= 1;
        return frame;
    }

    fn run(self: *Source) void {
        while (!self.stop_requested.load(.acquire)) {
            if (self.nextFrame(clock.nowNs(self.io))) |frame| {
                _ = self.queue.push(frame);
                std.Io.sleep(self.io, .{ .nanoseconds = frame_interval_ns }, .awake) catch {};
            } else {
                std.Io.sleep(self.io, .{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch {};
            }
        }
    }
};

fn busIndex(database: *const Database, name: []const u8) ?u8 {
    for (database.doc.buses.items, 0..) |bus, index| {
        if (std.mem.eql(u8, bus.name, name)) return @intCast(index);
    }
    return null;
}

fn fillPayload(frame: *Frame, sequence: u64) void {
    var state = sequence ^ (@as(u64, frame.id) << 32) ^ 0x9e3779b97f4a7c15;
    for (frame.data[0..frame.len], 0..) |*byte, index| {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        byte.* = @truncate(state +% index);
    }
}

test "demo source emits database-shaped classic and FD frames" {
    const allocator = std.testing.allocator;
    const Diagnostics = @import("db/database.zig").Diagnostics;
    const source_text =
        \\VERSION ""
        \\
        \\NS_ :
        \\
        \\BS_:
        \\
        \\BU_: ECU
        \\
        \\BO_ 192 Classic: 8 ECU
        \\ SG_ Value : 0|8@1+ (1,0) [0|255] "" Vector__XXX
        \\
    ;
    var diagnostics: Diagnostics = .empty;
    defer diagnostics.deinit(allocator);
    var database = try Database.init(allocator, .dbc, source_text, &diagnostics);
    defer database.deinit();

    var queue: rx.FrameQueue = .{};
    const source = try Source.create(allocator, std.testing.io, &database, &queue);
    defer source.stopAndDeinit();
    const frame = source.nextFrame(1234).?;
    try std.testing.expectEqual(@as(u32, 192), frame.id);
    try std.testing.expectEqual(@as(u8, 8), frame.len);
    try std.testing.expect(!frame.flags.fd);
    try std.testing.expectEqual(@as(u64, 1234), frame.timestamp_ns);
}
