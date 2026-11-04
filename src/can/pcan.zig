const std = @import("std");
const builtin = @import("builtin");
const adapter = @import("adapter.zig");
const Frame = @import("frame.zig").Frame;
const clock = @import("../sync/clock.zig");
const api_mod = @import("pcan_api.zig");

comptime {
    if (builtin.os.tag != .linux and builtin.os.tag != .windows) @compileError("PEAK PCAN-Basic is only available on Linux and Windows");
}

const fd_flag: u8 = 0x01;
const fd_brs: u8 = 0x02;
const fd_esi: u8 = 0x04;
const fd_extended: u8 = 0x08;
const fd_rtr: u8 = 0x10;
const fd_error: u8 = 0x40;
const classic_rtr: u8 = 0x01;
const classic_extended: u8 = 0x02;
const classic_error: u8 = 0x04;
const wait_slice_ns = 20 * std.time.ns_per_ms;
const error_text_length = 256;
const queue_capacity = 1024;

const ReceiveEvent = if (builtin.os.tag == .windows) ?std.os.windows.HANDLE else i32;

const Pcan = struct {
    allocator: std.mem.Allocator,
    api: api_mod.Api,
    handle: api_mod.Handle,
    listen_only: bool,
    fd: bool,
    receive_own_messages: bool,
    receive_event: ReceiveEvent,
    normalizer: ?clock.Normalizer = null,
    status_code: std.atomic.Value(u32) = .init(api_mod.ok),
    own_echoes: @import("../sync/spsc.zig").Spsc(Frame, queue_capacity) = .{},
};

const Channel = struct {
    handle: api_mod.Handle,
    prefix: []const u8,
    index: u8,
};

const channels = [_]Channel{
    .{ .handle = 0x21, .prefix = "PCAN_PCIBUS", .index = 1 },
    .{ .handle = 0x22, .prefix = "PCAN_PCIBUS", .index = 2 },
    .{ .handle = 0x23, .prefix = "PCAN_PCIBUS", .index = 3 },
    .{ .handle = 0x24, .prefix = "PCAN_PCIBUS", .index = 4 },
    .{ .handle = 0x25, .prefix = "PCAN_PCIBUS", .index = 5 },
    .{ .handle = 0x26, .prefix = "PCAN_PCIBUS", .index = 6 },
    .{ .handle = 0x27, .prefix = "PCAN_PCIBUS", .index = 7 },
    .{ .handle = 0x28, .prefix = "PCAN_PCIBUS", .index = 8 },
    .{ .handle = 0x51, .prefix = "PCAN_USBBUS", .index = 1 },
    .{ .handle = 0x52, .prefix = "PCAN_USBBUS", .index = 2 },
    .{ .handle = 0x53, .prefix = "PCAN_USBBUS", .index = 3 },
    .{ .handle = 0x54, .prefix = "PCAN_USBBUS", .index = 4 },
    .{ .handle = 0x55, .prefix = "PCAN_USBBUS", .index = 5 },
    .{ .handle = 0x56, .prefix = "PCAN_USBBUS", .index = 6 },
    .{ .handle = 0x57, .prefix = "PCAN_USBBUS", .index = 7 },
    .{ .handle = 0x58, .prefix = "PCAN_USBBUS", .index = 8 },
};

pub const backend = adapter.Backend{
    .name = "peak",
    .capabilities = .{ .fd = true, .hw_timestamps = false, .error_frames = true, .set_bitrate = true },
    .enumerate = enumerate,
    .open = open,
};

fn enumerate(allocator: std.mem.Allocator) adapter.Error![]adapter.ChannelInfo {
    var api = api_mod.Api.load() catch |err| return switch (err) {
        error.LibraryNotFound => error.BackendUnavailable,
        error.MissingSymbol => error.Unsupported,
    };
    defer api.close();

    var result: std.ArrayListUnmanaged(adapter.ChannelInfo) = .empty;
    errdefer result.deinit(allocator);
    for (channels) |channel| {
        var condition: u32 = 0;
        const status = api.get_value(channel.handle, api_mod.channel_condition_parameter, @ptrCast(&condition), @sizeOf(u32));
        if (status != api_mod.ok or condition & (api_mod.channel_available | api_mod.channel_occupied) == 0) continue;
        var name: [adapter.ChannelInfo.name_capacity]u8 = undefined;
        const channel_name = std.fmt.bufPrint(&name, "{s}{d}", .{ channel.prefix, channel.index }) catch return error.InvalidChannel;
        const description = if (condition & api_mod.channel_occupied != 0) "PEAK PCAN channel (in use)" else "PEAK PCAN channel";
        try result.append(allocator, try adapter.ChannelInfo.init(backend.name, channel_name, description, backend.capabilities));
    }
    return result.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn open(allocator: std.mem.Allocator, config: adapter.ChannelConfig) adapter.Error!adapter.Adapter {
    const channel_handle = parseChannel(config.channel) orelse return error.InvalidChannel;
    var api = api_mod.Api.load() catch |err| return switch (err) {
        error.LibraryNotFound => error.BackendUnavailable,
        error.MissingSymbol => error.Unsupported,
    };
    errdefer api.close();

    var fd_bitrate_storage: [160:0]u8 = undefined;
    const fd_bitrate: ?[*:0]const u8 = if (config.data_bitrate) |data_bitrate| blk: {
        const nominal = config.nominal_bitrate orelse 500_000;
        break :blk makeFdBitrate(&fd_bitrate_storage, nominal, data_bitrate) orelse return error.InvalidFrame;
    } else null;
    if (fd_bitrate != null and (api.initialize_fd == null or api.read_fd == null or api.write_fd == null)) return error.Unsupported;

    if (config.listen_only) {
        var listen: u8 = 1;
        const status = api.set_value(channel_handle, api_mod.listen_only_parameter, @ptrCast(&listen), @sizeOf(u8));
        if (status != api_mod.ok) return mapError(status);
    }

    const init_status = if (fd_bitrate) |bitrate|
        (api.initialize_fd orelse return error.Unsupported)(channel_handle, bitrate)
    else
        api.initialize(channel_handle, classicBitrate(config.nominal_bitrate orelse 500_000) orelse return error.Unsupported, 0, 0, 0);
    if (init_status != api_mod.ok) return mapError(init_status);
    errdefer _ = api.uninitialize(channel_handle);

    var receive_event: ReceiveEvent = if (builtin.os.tag == .windows) null else -1;
    _ = api.get_value(channel_handle, api_mod.receive_event_parameter, @ptrCast(&receive_event), @sizeOf(ReceiveEvent));

    const instance = allocator.create(Pcan) catch return error.OutOfMemory;
    instance.* = .{
        .allocator = allocator,
        .api = api,
        .handle = channel_handle,
        .listen_only = config.listen_only,
        .fd = fd_bitrate != null,
        .receive_own_messages = config.receive_own_messages,
        .receive_event = receive_event,
    };
    return .{ .ptr = instance, .vtable = &vtable };
}

fn parseChannel(name: []const u8) ?api_mod.Handle {
    for (channels) |channel| {
        if (!std.mem.startsWith(u8, name, channel.prefix)) continue;
        const index = std.fmt.parseInt(u8, name[channel.prefix.len..], 10) catch return null;
        if (index != channel.index) continue;
        return channel.handle;
    }
    return null;
}

fn classicBitrate(bitrate: u32) ?u16 {
    return switch (bitrate) {
        1_000_000 => 0x0014,
        800_000 => 0x0016,
        500_000 => 0x001c,
        250_000 => 0x011c,
        125_000 => 0x031c,
        100_000 => 0x432f,
        50_000 => 0x472f,
        20_000 => 0x532f,
        10_000 => 0x672f,
        5_000 => 0x7f7f,
        else => null,
    };
}

fn makeFdBitrate(output: *[160:0]u8, nominal: u32, data: u32) ?[*:0]const u8 {
    const nominal_timing = timing(nominal, 80) orelse return null;
    const data_timing = timing(data, 70) orelse return null;
    const result = std.fmt.bufPrint(output[0..], "f_clock_mhz=80, nom_brp=1, nom_tseg1={d}, nom_tseg2={d}, nom_sjw=1, data_brp=1, data_tseg1={d}, data_tseg2={d}, data_sjw=1", .{
        nominal_timing.tseg1,
        nominal_timing.tseg2,
        data_timing.tseg1,
        data_timing.tseg2,
    }) catch return null;
    output[result.len] = 0;
    return output[0..result.len :0].ptr;
}

const Timing = struct { tseg1: u16, tseg2: u16 };

fn timing(bitrate: u32, sample_point_percent: u32) ?Timing {
    if (bitrate == 0 or 80_000_000 % bitrate != 0) return null;
    const quanta = 80_000_000 / bitrate;
    if (quanta < 4 or quanta > 512) return null;
    const tseg1: u32 = @max(1, quanta * sample_point_percent / 100 - 1);
    const tseg2 = quanta - tseg1 - 1;
    if (tseg2 == 0 or tseg1 > std.math.maxInt(u16) or tseg2 > std.math.maxInt(u16)) return null;
    return .{ .tseg1 = @intCast(tseg1), .tseg2 = @intCast(tseg2) };
}

fn read(ptr: *anyopaque, out: []Frame, timeout_ns: u64) adapter.Error!usize {
    if (out.len == 0) return 0;
    const instance: *Pcan = @ptrCast(@alignCast(ptr));
    var count: usize = 0;
    var waited = false;
    while (count < out.len) {
        if (instance.own_echoes.pop()) |echo| {
            out[count] = echo;
            count += 1;
            continue;
        }
        const status = readOne(instance, &out[count]);
        if (status == .frame) {
            count += 1;
            continue;
        }
        if (status == .empty and count == 0 and timeout_ns != 0 and !waited) {
            waitForReceive(instance, timeout_ns);
            waited = true;
            continue;
        }
        if (status == .empty) break;
        return status.err;
    }
    return count;
}

const ReadResult = union(enum) { frame, empty, err: adapter.Error };

fn readOne(instance: *Pcan, out: *Frame) ReadResult {
    if (instance.fd) {
        var message = api_mod.MessageFd{};
        var driver_timestamp: api_mod.TimestampFd = 0;
        const status = (instance.api.read_fd orelse return .{ .err = error.Unsupported })(instance.handle, &message, &driver_timestamp);
        instance.status_code.store(status, .release);
        if (api_mod.mapStatus(status) == .empty) return .empty;
        if (status != api_mod.ok) return .{ .err = mapError(status) };
        const length = dlcToLength(message.dlc) orelse return .{ .err = error.InvalidFrame };
        const timestamp = normalizeTimestamp(instance, driver_timestamp * std.time.ns_per_us);
        out.* = .{
            .timestamp_ns = timestamp,
            .id = message.id,
            .bus = 0,
            .len = length,
            .flags = .{
                .extended = message.message_type & fd_extended != 0,
                .fd = message.message_type & fd_flag != 0,
                .brs = message.message_type & fd_brs != 0,
                .esi = message.message_type & fd_esi != 0,
                .rtr = message.message_type & fd_rtr != 0,
                .err = message.message_type & fd_error != 0,
            },
            ._pad = 0,
            .data = @splat(0),
        };
        if (!out.flags.rtr) @memcpy(out.data[0..length], message.data[0..length]);
        return .frame;
    }

    var message = api_mod.Message{};
    var driver_timestamp = api_mod.Timestamp{};
    const status = instance.api.read(instance.handle, &message, &driver_timestamp);
    instance.status_code.store(status, .release);
    if (api_mod.mapStatus(status) == .empty) return .empty;
    if (status != api_mod.ok) return .{ .err = mapError(status) };
    if (message.len > 8) return .{ .err = error.InvalidFrame };
    const driver_ns = (@as(u128, driver_timestamp.millis_overflow) << 32 | driver_timestamp.millis) * std.time.ns_per_ms + @as(u128, driver_timestamp.micros) * std.time.ns_per_us;
    const timestamp = normalizeTimestamp(instance, @intCast(@min(driver_ns, std.math.maxInt(u64))));
    out.* = .{
        .timestamp_ns = timestamp,
        .id = message.id,
        .bus = 0,
        .len = message.len,
        .flags = .{
            .extended = message.message_type & classic_extended != 0,
            .fd = false,
            .brs = false,
            .esi = false,
            .rtr = message.message_type & classic_rtr != 0,
            .err = message.message_type & classic_error != 0,
        },
        ._pad = 0,
        .data = @splat(0),
    };
    if (!out.flags.rtr) @memcpy(out.data[0..message.len], message.data[0..message.len]);
    return .frame;
}

fn write(ptr: *anyopaque, frame: *const Frame, timeout_ns: u64) adapter.Error!void {
    _ = timeout_ns;
    const instance: *Pcan = @ptrCast(@alignCast(ptr));
    if (instance.listen_only) return error.ListenOnly;
    if (frame.flags.err or frame.len > 64 or frame.flags.fd != instance.fd) return error.InvalidFrame;
    const status = if (instance.fd) writeFd(instance, frame) else writeClassic(instance, frame);
    instance.status_code.store(status, .release);
    if (status != api_mod.ok) return mapError(status);
    if (instance.receive_own_messages) {
        var echo = frame.*;
        echo.timestamp_ns = monotonicNow();
        _ = instance.own_echoes.push(echo);
    }
}

fn writeClassic(instance: *Pcan, frame: *const Frame) api_mod.StatusCode {
    if (frame.len > 8) return api_mod.transmit_full;
    var message = api_mod.Message{
        .message_type = (if (frame.flags.extended) classic_extended else 0) | (if (frame.flags.rtr) classic_rtr else 0),
        .id = frame.id,
        .len = if (frame.flags.rtr) 0 else frame.len,
        .data = @splat(0),
    };
    if (!frame.flags.rtr) @memcpy(message.data[0..frame.len], frame.data[0..frame.len]);
    return instance.api.write(instance.handle, &message);
}

fn writeFd(instance: *Pcan, frame: *const Frame) api_mod.StatusCode {
    const dlc = lengthToDlc(frame.len) orelse return api_mod.transmit_full;
    var message = api_mod.MessageFd{
        .id = frame.id,
        .message_type = fd_flag |
            (if (frame.flags.brs) fd_brs else 0) |
            (if (frame.flags.esi) fd_esi else 0) |
            (if (frame.flags.extended) fd_extended else 0) |
            (if (frame.flags.rtr) fd_rtr else 0),
        .dlc = dlc,
        .data = @splat(0),
    };
    if (!frame.flags.rtr) @memcpy(message.data[0..frame.len], frame.data[0..frame.len]);
    return (instance.api.write_fd orelse return api_mod.transmit_full)(instance.handle, &message);
}

fn adapterStatus(ptr: *anyopaque) adapter.Status {
    const instance: *Pcan = @ptrCast(@alignCast(ptr));
    const code = instance.api.get_status(instance.handle);
    instance.status_code.store(code, .release);
    return switch (api_mod.mapStatus(code)) {
        .ok, .empty, .queue_full => .ok,
        .warning => .warning,
        .passive => .passive,
        .bus_off => .bus_off,
        .disconnected => .disconnected,
        .failure => .disconnected,
    };
}

fn close(ptr: *anyopaque) void {
    const instance: *Pcan = @ptrCast(@alignCast(ptr));
    _ = instance.api.uninitialize(instance.handle);
    instance.api.close();
    instance.allocator.destroy(instance);
}

const vtable = adapter.Adapter.VTable{ .read = read, .write = write, .status = adapterStatus, .close = close };

fn mapError(status_code: api_mod.StatusCode) adapter.Error {
    return switch (api_mod.mapStatus(status_code)) {
        .ok, .empty => error.IoFailure,
        .queue_full => error.QueueFull,
        .warning, .passive => error.IoFailure,
        .bus_off => error.BusOff,
        .disconnected => error.Disconnected,
        .failure => error.IoFailure,
    };
}

fn dlcToLength(dlc: u8) ?u8 {
    const lengths = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 12, 16, 20, 24, 32, 48, 64 };
    if (dlc >= lengths.len) return null;
    return lengths[dlc];
}

fn lengthToDlc(length: u8) ?u8 {
    const lengths = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 12, 16, 20, 24, 32, 48, 64 };
    for (lengths, 0..) |candidate, dlc| if (length == candidate) return @intCast(dlc);
    return null;
}

fn hasReceiveEvent(instance: *const Pcan) bool {
    return if (builtin.os.tag == .windows) instance.receive_event != null else instance.receive_event >= 0;
}

fn normalizeTimestamp(instance: *Pcan, driver_ns: u64) u64 {
    if (instance.normalizer == null) instance.normalizer = .init(driver_ns, monotonicNow());
    return instance.normalizer.?.normalize(driver_ns);
}

fn monotonicNow() u64 {
    if (builtin.os.tag == .linux) {
        var timestamp: std.os.linux.timespec = undefined;
        if (std.os.linux.errno(std.os.linux.clock_gettime(.MONOTONIC, &timestamp)) != .SUCCESS) return 0;
        if (timestamp.sec < 0 or timestamp.nsec < 0) return 0;
        const value = @as(u128, @intCast(timestamp.sec)) * std.time.ns_per_s + @as(u128, @intCast(timestamp.nsec));
        return @intCast(@min(value, std.math.maxInt(u64)));
    }
    var counter: std.os.windows.LARGE_INTEGER = 0;
    var frequency: std.os.windows.LARGE_INTEGER = 0;
    if (!std.os.windows.ntdll.RtlQueryPerformanceCounter(&counter).toBool() or !std.os.windows.ntdll.RtlQueryPerformanceFrequency(&frequency).toBool() or frequency <= 0) return 0;
    const value = @as(u128, @intCast(counter)) * std.time.ns_per_s / @as(u128, @intCast(frequency));
    return @intCast(@min(value, std.math.maxInt(u64)));
}

fn waitForReceive(instance: *Pcan, timeout_ns: u64) void {
    if (!hasReceiveEvent(instance)) return;
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var descriptors = [_]linux.pollfd{.{ .fd = instance.receive_event, .events = linux.POLL.IN }};
        const timeout_ms = @min((timeout_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms, std.math.maxInt(i32));
        _ = linux.poll(&descriptors, 1, @intCast(timeout_ms));
    } else if (builtin.os.tag == .windows) {
        const units_100ns: i64 = @max(1, @as(i64, @intCast(@min(timeout_ns / 100, std.math.maxInt(i64)))));
        const interval: i64 = -units_100ns;
        _ = std.os.windows.ntdll.NtWaitForSingleObject(instance.receive_event.?, .FALSE, &interval);
    }
}

test "PEAK channel parser and bitrate mappings are bounded" {
    try std.testing.expectEqual(@as(?api_mod.Handle, 0x51), parseChannel("PCAN_USBBUS1"));
    try std.testing.expectEqual(@as(?api_mod.Handle, 0x28), parseChannel("PCAN_PCIBUS8"));
    try std.testing.expectEqual(@as(?api_mod.Handle, null), parseChannel("PCAN_USBBUS9"));
    try std.testing.expectEqual(@as(?u16, 0x001c), classicBitrate(500_000));
    try std.testing.expectEqual(@as(?u16, null), classicBitrate(333_333));
    try std.testing.expectEqual(@as(?u8, 9), lengthToDlc(12));
    try std.testing.expectEqual(@as(?u8, null), lengthToDlc(9));
    const nominal = timing(500_000, 80).?;
    try std.testing.expectEqual(@as(u16, 127), nominal.tseg1);
    try std.testing.expectEqual(@as(u16, 32), nominal.tseg2);
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(api_mod.Message));
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(api_mod.MessageFd));
}
