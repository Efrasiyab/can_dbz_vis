const std = @import("std");
const adapter = @import("can/adapter.zig");
const clock = @import("sync/clock.zig");
const Frame = @import("can/frame.zig").Frame;
const Engine = @import("engine/engine.zig").Engine;
const virtual = @import("can/virtual.zig");

const default_rate = 10_000;
const default_seconds = 3;
const max_channels = 4;

const CountingAllocator = struct {
    parent: std.mem.Allocator,
    allocations: std.atomic.Value(u64) = .init(0),

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        _ = self.allocations.fetchAdd(1, .monotonic);
        return self.parent.rawAlloc(len, alignment, return_address);
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        return self.parent.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const result = self.parent.rawRemap(memory, alignment, new_len, return_address);
        if (result != null) _ = self.allocations.fetchAdd(1, .monotonic);
        return result;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.parent.rawFree(memory, alignment, return_address);
    }
};

const Producer = struct {
    io: std.Io,
    senders: *[max_channels]?adapter.Adapter,
    channel_count: usize,
    rate: u64,
    start_ns: u64,
    end_ns: u64,
    sent: *[max_channels]std.atomic.Value(u64),
    failures: *[max_channels]std.atomic.Value(u64),

    fn run(self: *Producer) void {
        const interval_ns = @max(1, std.time.ns_per_s / self.rate);
        const batch_size = @max(1, @min(self.rate / 1000, 256));
        const batch_interval_ns = interval_ns * batch_size;
        var batch_start_ns = self.start_ns;
        var sequences: [max_channels]u64 = @splat(0);
        while (batch_start_ns < self.end_ns) {
            const now_ns = clock.nowNs(self.io);
            if (now_ns < batch_start_ns) {
                if (batch_start_ns == self.start_ns) {
                    std.Thread.yield() catch {};
                } else {
                    while (clock.nowNs(self.io) < batch_start_ns) {}
                }
                continue;
            }

            for (0..batch_size) |batch_index| {
                const timestamp_ns = batch_start_ns +| batch_index * interval_ns;
                if (timestamp_ns >= self.end_ns) break;
                for (0..self.channel_count) |channel| {
                    const sequence = sequences[channel];
                    var frame = Frame{
                        .timestamp_ns = timestamp_ns,
                        .id = 0x100 + @as(u32, @truncate(sequence % 64)),
                        .bus = @intCast(channel),
                        .len = 8,
                        .flags = .{},
                        ._pad = 0,
                        .data = @splat(0),
                    };
                    frame.data[0] = @truncate(sequence);
                    frame.data[1] = @truncate(sequence >> 8);
                    self.senders[channel].?.write(&frame, 0) catch {
                        _ = self.failures[channel].fetchAdd(1, .monotonic);
                        sequences[channel] +%= 1;
                        continue;
                    };
                    _ = self.sent[channel].fetchAdd(1, .monotonic);
                    sequences[channel] +%= 1;
                }
            }
            batch_start_ns +|= batch_interval_ns;
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var rate: u64 = default_rate;
    var seconds: u64 = default_seconds;
    var channel_count: usize = max_channels;
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--rate=")) {
            rate = try std.fmt.parseInt(u64, arg["--rate=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--seconds=")) {
            seconds = try std.fmt.parseInt(u64, arg["--seconds=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--channels=")) {
            channel_count = try std.fmt.parseInt(usize, arg["--channels=".len..], 10);
        } else {
            return error.InvalidArguments;
        }
    }
    if (rate == 0 or rate > 1_000_000 or seconds == 0 or seconds > 3600 or channel_count == 0 or channel_count > max_channels) return error.InvalidArguments;

    var counting_allocator = CountingAllocator{ .parent = init.gpa };
    const allocator = counting_allocator.allocator();
    const engine = try Engine.create(allocator, init.io);
    defer engine.deinit();

    var senders: [max_channels]?adapter.Adapter = @splat(null);
    defer for (&senders) |*sender| {
        if (sender.*) |*device| device.deinit();
    };

    for (0..channel_count) |index| {
        var name_buffer: [adapter.ChannelInfo.name_capacity]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "virtual{d}", .{index});
        try engine.addAdapter(try virtual.backend.open(allocator, .{ .channel = name }), @intCast(index));
        senders[index] = try virtual.backend.open(allocator, .{ .channel = name });
    }

    try engine.start();
    const start_ns = clock.nowNs(init.io) +| 50 * std.time.ns_per_ms;
    const end_ns = start_ns +| seconds * std.time.ns_per_s;
    var sent: [max_channels]std.atomic.Value(u64) = @splat(.init(0));
    var failures: [max_channels]std.atomic.Value(u64) = @splat(.init(0));
    const allocation_start = counting_allocator.allocations.load(.monotonic);
    var producer = Producer{
        .io = init.io,
        .senders = &senders,
        .channel_count = channel_count,
        .rate = rate,
        .start_ns = start_ns,
        .end_ns = end_ns,
        .sent = &sent,
        .failures = &failures,
    };
    producer.run();

    engine.stop();
    const measurement_end = clock.nowNs(init.io);
    const total_sent = sumCounters(&sent, channel_count);
    const total_failures = sumCounters(&failures, channel_count);
    const received = engine.framesRead();
    const drops = engine.droppedCount() +% total_failures;
    const allocations = counting_allocator.allocations.load(.monotonic) - allocation_start;
    const elapsed_ns = measurement_end - start_ns;
    const actual_rate = if (elapsed_ns == 0) 0 else @as(u128, received) * std.time.ns_per_s / elapsed_ns;

    std.debug.print(
        "channels={d} target_per_channel={d}/s sent={d} received={d} rx_rate={d}/s drops={d} steady_allocations={d} elapsed_ms={d}\n",
        .{ channel_count, rate, total_sent, received, actual_rate, drops, allocations, elapsed_ns / std.time.ns_per_ms },
    );
    if (drops != 0 or allocations != 0) return error.BenchmarkFailed;
}

fn sumCounters(counters: []const std.atomic.Value(u64), count: usize) u64 {
    var total: u64 = 0;
    for (counters[0..count]) |counter| total +%= counter.load(.monotonic);
    return total;
}
