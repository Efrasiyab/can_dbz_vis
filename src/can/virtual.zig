const std = @import("std");
const adapter = @import("adapter.zig");
const Frame = @import("frame.zig").Frame;

const queue_capacity = 4096;
const virtual_channel_count = 4;
const max_open_adapters = 16;

const VirtualAdapter = struct {
    allocator: std.mem.Allocator,
    channel_index: u8,
    listen_only: bool,
    receive_own_messages: bool,
    queue: [queue_capacity]Frame = undefined,
    read_index: usize = 0,
    write_index: usize = 0,
};

const VirtualBus = struct {
    mutex: std.atomic.Mutex = .unlocked,
    adapters: [max_open_adapters]?*VirtualAdapter = @splat(null),
};

var buses: [virtual_channel_count]VirtualBus = @splat(.{});

fn lockBus(channel_index: u8) void {
    while (!buses[channel_index].mutex.tryLock()) {}
}

pub const backend = adapter.Backend{
    .name = "virtual",
    .capabilities = .{ .fd = true, .error_frames = true },
    .enumerate = enumerate,
    .open = open,
};

fn enumerate(allocator: std.mem.Allocator) adapter.Error![]adapter.ChannelInfo {
    const channels = allocator.alloc(adapter.ChannelInfo, virtual_channel_count) catch return error.OutOfMemory;
    errdefer allocator.free(channels);
    for (channels, 0..) |*channel, index| {
        var name_buffer: [adapter.ChannelInfo.name_capacity]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buffer, "virtual{d}", .{index}) catch unreachable;
        channel.* = try adapter.ChannelInfo.init(backend.name, name, "In-process loopback bus", backend.capabilities);
    }
    return channels;
}

fn open(allocator: std.mem.Allocator, config: adapter.ChannelConfig) adapter.Error!adapter.Adapter {
    const prefix = "virtual";
    if (!std.mem.startsWith(u8, config.channel, prefix)) return error.InvalidChannel;
    const channel_index = std.fmt.parseInt(u8, config.channel[prefix.len..], 10) catch return error.InvalidChannel;
    if (channel_index >= virtual_channel_count) return error.InvalidChannel;

    const instance = allocator.create(VirtualAdapter) catch return error.OutOfMemory;
    instance.* = .{
        .allocator = allocator,
        .channel_index = channel_index,
        .listen_only = config.listen_only,
        .receive_own_messages = config.receive_own_messages,
    };

    const bus = &buses[channel_index];
    lockBus(channel_index);
    defer bus.mutex.unlock();
    for (&bus.adapters) |*slot| {
        if (slot.* == null) {
            slot.* = instance;
            return .{ .ptr = instance, .vtable = &vtable };
        }
    }

    allocator.destroy(instance);
    return error.ResourceExhausted;
}

fn read(ptr: *anyopaque, out: []Frame, timeout_ns: u64) adapter.Error!usize {
    _ = timeout_ns;
    const instance: *VirtualAdapter = @ptrCast(@alignCast(ptr));

    const bus = &buses[instance.channel_index];
    lockBus(instance.channel_index);
    defer bus.mutex.unlock();

    var count: usize = 0;
    while (count < out.len and instance.read_index != instance.write_index) : (count += 1) {
        out[count] = instance.queue[instance.read_index & (queue_capacity - 1)];
        instance.read_index +%= 1;
    }
    return count;
}

fn write(ptr: *anyopaque, frame: *const Frame, timeout_ns: u64) adapter.Error!void {
    _ = timeout_ns;
    const sender: *VirtualAdapter = @ptrCast(@alignCast(ptr));
    if (sender.listen_only) return error.ListenOnly;

    const bus = &buses[sender.channel_index];
    lockBus(sender.channel_index);
    defer bus.mutex.unlock();

    for (bus.adapters) |maybe_recipient| {
        const recipient = maybe_recipient orelse continue;
        if (recipient == sender and !recipient.receive_own_messages) continue;
        if (recipient.write_index -% recipient.read_index >= queue_capacity) return error.QueueFull;
    }

    for (bus.adapters) |maybe_recipient| {
        const recipient = maybe_recipient orelse continue;
        if (recipient == sender and !recipient.receive_own_messages) continue;
        recipient.queue[recipient.write_index & (queue_capacity - 1)] = frame.*;
        recipient.write_index +%= 1;
    }
}

fn status(ptr: *anyopaque) adapter.Status {
    _ = ptr;
    return .ok;
}

fn close(ptr: *anyopaque) void {
    const instance: *VirtualAdapter = @ptrCast(@alignCast(ptr));

    const bus = &buses[instance.channel_index];
    lockBus(instance.channel_index);
    for (&bus.adapters) |*slot| {
        if (slot.* == instance) {
            slot.* = null;
            break;
        }
    }
    bus.mutex.unlock();

    instance.allocator.destroy(instance);
}

const vtable = adapter.Adapter.VTable{
    .read = read,
    .write = write,
    .status = status,
    .close = close,
};

test "virtual backend enumerates and round-trips a CAN FD frame" {
    const allocator = std.testing.allocator;
    const channels = try backend.enumerate(allocator);
    defer allocator.free(channels);
    try std.testing.expectEqual(@as(usize, virtual_channel_count), channels.len);
    try std.testing.expectEqualStrings("virtual0", channels[0].nameSlice());

    var sender = try backend.open(allocator, .{ .channel = "virtual0" });
    defer sender.deinit();
    var receiver = try backend.open(allocator, .{ .channel = "virtual0" });
    defer receiver.deinit();

    const frame = Frame{
        .timestamp_ns = 123456,
        .id = 0x18ff50e5,
        .bus = 1,
        .len = 12,
        .flags = .{ .extended = true, .fd = true, .brs = true },
        ._pad = 0,
        .data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 } ++ @as([52]u8, @splat(0)),
    };
    try sender.write(&frame, 0);

    var received: [1]Frame = undefined;
    try std.testing.expectEqual(@as(usize, 1), try receiver.read(&received, 0));
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&frame), std.mem.asBytes(&received[0]));
    try std.testing.expectEqual(adapter.Status.ok, receiver.status());
}

test "virtual channels do not share traffic" {
    const allocator = std.testing.allocator;
    var sender = try backend.open(allocator, .{ .channel = "virtual0" });
    defer sender.deinit();
    var receiver = try backend.open(allocator, .{ .channel = "virtual1" });
    defer receiver.deinit();

    const frame = Frame{
        .timestamp_ns = 0,
        .id = 7,
        .bus = 0,
        .len = 0,
        .flags = .{},
        ._pad = 0,
        .data = @splat(0),
    };
    try sender.write(&frame, 0);
    var received: [1]Frame = undefined;
    try std.testing.expectEqual(@as(usize, 0), try receiver.read(&received, 0));
}

test "virtual backend honors listen-only and receive-own settings" {
    const allocator = std.testing.allocator;
    var listen_only = try backend.open(allocator, .{ .channel = "virtual0", .listen_only = true });
    defer listen_only.deinit();
    const frame = Frame{
        .timestamp_ns = 0,
        .id = 1,
        .bus = 0,
        .len = 0,
        .flags = .{},
        ._pad = 0,
        .data = @splat(0),
    };
    try std.testing.expectError(error.ListenOnly, listen_only.write(&frame, 0));

    var loopback = try backend.open(allocator, .{ .channel = "virtual0", .receive_own_messages = true });
    defer loopback.deinit();
    try loopback.write(&frame, 0);
    var received: [1]Frame = undefined;
    try std.testing.expectEqual(@as(usize, 1), try loopback.read(&received, 0));
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&frame), std.mem.asBytes(&received[0]));
}
