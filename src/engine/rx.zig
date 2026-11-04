const std = @import("std");
const adapter = @import("../can/adapter.zig");
const Frame = @import("../can/frame.zig").Frame;
const spsc = @import("../sync/spsc.zig");

pub const batch_capacity = 32;
pub const queue_capacity = 4096;
pub const read_timeout_ns = 10 * std.time.ns_per_ms;
pub const FrameQueue = spsc.Spsc(Frame, queue_capacity);

pub const Receiver = struct {
    device: *adapter.Adapter,
    queue: *FrameQueue,
    bus_index: u8,
    stop: *std.atomic.Value(bool),
    frames_read: *std.atomic.Value(u64),
    errors: *std.atomic.Value(u64),
    thread: ?std.Thread = null,

    pub const StartError = std.Thread.SpawnError || error{AlreadyStarted};

    pub fn start(self: *Receiver) StartError!void {
        if (self.thread != null) return error.AlreadyStarted;
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn join(self: *Receiver) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    fn run(self: *Receiver) void {
        var frames: [batch_capacity]Frame = undefined;
        while (!self.stop.load(.acquire)) {
            const count = self.device.read(&frames, read_timeout_ns) catch |err| {
                _ = self.errors.fetchAdd(1, .monotonic);
                if (err == error.Disconnected) break;
                std.Thread.yield() catch {};
                continue;
            };
            if (count == 0) {
                std.Thread.yield() catch {};
                continue;
            }

            self.enqueue(frames[0..count]);
        }

        var drained: usize = 0;
        while (drained < queue_capacity) {
            const count = self.device.read(&frames, 0) catch {
                _ = self.errors.fetchAdd(1, .monotonic);
                break;
            };
            if (count == 0) break;
            self.enqueue(frames[0..count]);
            drained += count;
        }
    }

    fn enqueue(self: *Receiver, frames: []const Frame) void {
        for (frames) |source_frame| {
            var frame = source_frame;
            frame.bus = self.bus_index;
            _ = self.queue.push(frame);
        }
        _ = self.frames_read.fetchAdd(frames.len, .monotonic);
    }
};
