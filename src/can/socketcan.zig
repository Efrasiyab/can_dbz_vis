const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const adapter = @import("adapter.zig");
const clock = @import("../sync/clock.zig");
const Frame = @import("frame.zig").Frame;
const max_payload_len = @import("frame.zig").max_payload_len;

comptime {
    if (builtin.os.tag != .linux) @compileError("SocketCAN is only available on Linux");
}

const protocol_raw = 1;
const sol_can_raw = 101;
const can_raw_filter = 1;
const can_raw_err_filter = 2;
const can_raw_recv_own_msgs = 4;
const can_raw_fd_frames = 5;
const can_eff_flag: u32 = 0x80000000;
const can_rtr_flag: u32 = 0x40000000;
const can_err_flag: u32 = 0x20000000;
const can_eff_mask: u32 = 0x1fffffff;
const can_sff_mask: u32 = 0x000007ff;
const can_err_mask: u32 = 0x1fffffff;
const can_fd_brs: u8 = 0x01;
const can_fd_esi: u8 = 0x02;
const classic_mtu = 16;
const fd_mtu = 72;
const max_batch = 32;
const if_name_size = 16;

const SockAddrCan = extern struct {
    family: u16,
    ifindex: i32,
    address: [8]u8,
};

const IfReqData = extern union {
    index: i32,
    padding: [24]u8,
};

const IfReq = extern struct {
    name: [if_name_size]u8,
    data: IfReqData,
};

const CanFrame = extern struct {
    id: u32,
    len: u8,
    pad: u8,
    res0: u8,
    len8_dlc: u8,
    data: [8]u8,
};

const CanFdFrame = extern struct {
    id: u32,
    len: u8,
    flags: u8,
    res0: u8,
    res1: u8,
    data: [64]u8,
};

const SocketCan = struct {
    allocator: std.mem.Allocator,
    fd: linux.fd_t,
    listen_only: bool,
    normalizer: clock.Normalizer,
    status_code: std.atomic.Value(u8) = .init(@intCast(@backingInt(adapter.Status.ok))),
};

pub const backend = adapter.Backend{
    .name = "socketcan",
    .capabilities = .{ .fd = true, .hw_timestamps = true, .error_frames = true },
    .enumerate = enumerate,
    .open = open,
};

fn mapErrno(errno: linux.E) adapter.Error {
    return switch (errno) {
        .AGAIN, .NOBUFS => error.QueueFull,
        .NODEV, .NXIO, .NETDOWN => error.Disconnected,
        .INVAL => error.InvalidChannel,
        else => error.IoFailure,
    };
}

fn closeFd(fd: linux.fd_t) void {
    _ = linux.close(fd);
}

fn createSocket() adapter.Error!linux.fd_t {
    const result = linux.socket(linux.AF.CAN, linux.SOCK.RAW | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, protocol_raw);
    const errno = linux.errno(result);
    if (errno != .SUCCESS) return mapErrno(errno);
    return @intCast(result);
}

fn setSocketOption(fd: linux.fd_t, level: i32, option: u32, value: anytype) adapter.Error!void {
    const result = linux.setsockopt(fd, level, option, @ptrCast(&value), @intCast(@sizeOf(@TypeOf(value))));
    const errno = linux.errno(result);
    if (errno != .SUCCESS) return mapErrno(errno);
}

fn interfaceIndex(fd: linux.fd_t, name: []const u8) adapter.Error!i32 {
    if (name.len == 0 or name.len >= if_name_size) return error.InvalidChannel;
    var request = IfReq{
        .name = @splat(0),
        .data = .{ .padding = @splat(0) },
    };
    @memcpy(request.name[0..name.len], name);
    const result = linux.ioctl(fd, linux.SIOCGIFINDEX, @intFromPtr(&request));
    const errno = linux.errno(result);
    if (errno != .SUCCESS) return mapErrno(errno);
    return request.data.index;
}

fn bindInterface(fd: linux.fd_t, index: i32) adapter.Error!void {
    const address = SockAddrCan{
        .family = @intCast(linux.AF.CAN),
        .ifindex = index,
        .address = @splat(0),
    };
    const result = linux.bind(fd, @ptrCast(&address), @intCast(@sizeOf(SockAddrCan)));
    const errno = linux.errno(result);
    if (errno != .SUCCESS) return mapErrno(errno);
}

fn open(allocator: std.mem.Allocator, config: adapter.ChannelConfig) adapter.Error!adapter.Adapter {
    const fd = try createSocket();
    errdefer closeFd(fd);

    const enabled: u32 = 1;
    try setSocketOption(fd, sol_can_raw, can_raw_fd_frames, enabled);
    try setSocketOption(fd, sol_can_raw, can_raw_recv_own_msgs, @as(u32, @intFromBool(config.receive_own_messages)));
    try setSocketOption(fd, sol_can_raw, can_raw_err_filter, can_err_mask);
    try setSocketOption(fd, linux.SOL.SOCKET, linux.SO.TIMESTAMPNS_OLD, enabled);

    const index = try interfaceIndex(fd, config.channel);
    try bindInterface(fd, index);

    const realtime_anchor = try currentNs(.REALTIME);
    const monotonic_anchor = try currentNs(.MONOTONIC);
    const instance = allocator.create(SocketCan) catch return error.OutOfMemory;
    instance.* = .{
        .allocator = allocator,
        .fd = fd,
        .listen_only = config.listen_only,
        .normalizer = .init(realtime_anchor, monotonic_anchor),
    };
    errdefer allocator.destroy(instance);
    return .{ .ptr = instance, .vtable = &vtable };
}

fn enumerate(allocator: std.mem.Allocator) adapter.Error![]adapter.ChannelInfo {
    const directory_result = linux.openat(linux.AT.FDCWD, "/sys/class/net", .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .CLOEXEC = true,
    }, 0);
    const directory_errno = linux.errno(directory_result);
    if (directory_errno != .SUCCESS) return mapErrno(directory_errno);
    const directory_fd: linux.fd_t = @intCast(directory_result);
    defer closeFd(directory_fd);

    var channels: std.ArrayListUnmanaged(adapter.ChannelInfo) = .empty;
    errdefer channels.deinit(allocator);

    var buffer: [4096]u8 = undefined;
    while (true) {
        const result = linux.getdents64(directory_fd, &buffer, @intCast(buffer.len));
        const errno = linux.errno(result);
        if (errno != .SUCCESS) return mapErrno(errno);
        const bytes_read: usize = result;
        if (bytes_read == 0) break;

        var offset: usize = 0;
        while (offset < bytes_read) {
            const entry: *align(1) const linux.dirent64 = @ptrCast(&buffer[offset]);
            const record_len: usize = entry.reclen;
            const name_offset = @offsetOf(linux.dirent64, "name");
            if (record_len < name_offset + 1 or record_len > bytes_read - offset) return error.IoFailure;

            const name_ptr: [*:0]const u8 = @ptrCast(&buffer[offset + name_offset]);
            const name = std.mem.span(name_ptr);
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..") and isCanInterface(name)) {
                const info = try adapter.ChannelInfo.init(backend.name, name, "Linux SocketCAN interface", backend.capabilities);
                channels.append(allocator, info) catch return error.OutOfMemory;
            }
            offset += record_len;
        }
    }
    return channels.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn isCanInterface(name: []const u8) bool {
    const fd = createSocket() catch return false;
    defer closeFd(fd);
    const index = interfaceIndex(fd, name) catch return false;
    bindInterface(fd, index) catch return false;
    return true;
}

fn currentNs(clock_id: linux.clockid_t) adapter.Error!u64 {
    var timestamp: linux.timespec = undefined;
    const result = linux.clock_gettime(clock_id, &timestamp);
    const errno = linux.errno(result);
    if (errno != .SUCCESS) return mapErrno(errno);
    if (timestamp.sec < 0 or timestamp.nsec < 0) return error.IoFailure;
    const nanoseconds = @as(u128, @intCast(timestamp.sec)) * std.time.ns_per_s + @as(u128, @intCast(timestamp.nsec));
    return @intCast(@min(nanoseconds, std.math.maxInt(u64)));
}

fn read(ptr: *anyopaque, out: []Frame, timeout_ns: u64) adapter.Error!usize {
    if (out.len == 0) return 0;
    const instance: *SocketCan = @ptrCast(@alignCast(ptr));

    const timeout_ms = @min(timeout_ns / std.time.ns_per_ms, std.math.maxInt(i32));
    var poll_fds = [_]linux.pollfd{.{ .fd = instance.fd, .events = linux.POLL.IN }};
    const poll_result = linux.poll(&poll_fds, 1, @intCast(timeout_ms));
    const poll_errno = linux.errno(poll_result);
    if (poll_errno != .SUCCESS) {
        const err = mapErrno(poll_errno);
        recordError(instance, err);
        return err;
    }
    if (poll_result == 0) return 0;
    if (poll_fds[0].revents & (linux.POLL.ERR | linux.POLL.HUP | linux.POLL.NVAL) != 0) {
        recordError(instance, error.Disconnected);
        return error.Disconnected;
    }
    if (poll_fds[0].revents & linux.POLL.IN == 0) return 0;

    const message_count = @min(out.len, max_batch);
    var payloads: [max_batch][fd_mtu]u8 = @splat(@splat(0));
    var controls: [max_batch][64]u8 align(8) = @splat(@splat(0));
    var vectors: [max_batch]std.posix.iovec = undefined;
    var messages: [max_batch]linux.mmsghdr = undefined;
    for (0..message_count) |index| {
        vectors[index] = .{ .base = &payloads[index], .len = payloads[index].len };
        messages[index] = .{
            .hdr = .{
                .name = null,
                .namelen = 0,
                .iov = @ptrCast(&vectors[index]),
                .iovlen = 1,
                .control = &controls[index],
                .controllen = controls[index].len,
                .flags = 0,
            },
            .len = 0,
        };
    }

    const received = linux.recvmmsg(instance.fd, &messages, @intCast(message_count), linux.MSG.DONTWAIT, null);
    const receive_errno = linux.errno(received);
    if (receive_errno != .SUCCESS) {
        if (receive_errno == .AGAIN) return 0;
        const err = mapErrno(receive_errno);
        recordError(instance, err);
        return err;
    }

    const software_timestamp = currentNs(.MONOTONIC) catch 0;
    const received_count: usize = received;
    var decoded: usize = 0;
    for (0..received_count) |index| {
        const control_len = @min(messages[index].hdr.controllen, controls[index].len);
        const timestamp = timestampFromControl(controls[index][0..control_len], instance.normalizer) orelse software_timestamp;
        if (decodeFrame(payloads[index][0..messages[index].len], timestamp)) |frame| {
            out[decoded] = frame;
            decoded += 1;
        }
    }
    return decoded;
}

fn timestampFromControl(control: []const u8, normalizer: clock.Normalizer) ?u64 {
    if (control.len < @sizeOf(linux.cmsghdr)) return null;
    const header: *const linux.cmsghdr = @ptrCast(@alignCast(control.ptr));
    if (header.level != linux.SOL.SOCKET or header.type != linux.SO.TIMESTAMPNS_OLD) return null;
    if (header.len < @sizeOf(linux.cmsghdr) + @sizeOf(linux.timespec) or header.len > control.len) return null;

    var timestamp: linux.timespec = undefined;
    const value_start = @sizeOf(linux.cmsghdr);
    @memcpy(std.mem.asBytes(&timestamp), control[value_start .. value_start + @sizeOf(linux.timespec)]);
    if (timestamp.sec < 0 or timestamp.nsec < 0) return null;
    const source_ns = @as(u128, @intCast(timestamp.sec)) * std.time.ns_per_s + @as(u128, @intCast(timestamp.nsec));
    return normalizer.normalize(@intCast(@min(source_ns, std.math.maxInt(u64))));
}

fn decodeFrame(bytes: []const u8, timestamp_ns: u64) ?Frame {
    if (bytes.len == classic_mtu) {
        var raw: CanFrame = undefined;
        @memcpy(std.mem.asBytes(&raw), bytes);
        if (raw.len > 8) return null;
        const is_error = raw.id & can_err_flag != 0;
        const is_extended = raw.id & can_eff_flag != 0;
        var frame = Frame{
            .timestamp_ns = timestamp_ns,
            .id = raw.id & (if (is_error) can_err_mask else if (is_extended) can_eff_mask else can_sff_mask),
            .bus = 0,
            .len = raw.len,
            .flags = .{
                .extended = is_extended,
                .rtr = raw.id & can_rtr_flag != 0,
                .err = is_error,
            },
            ._pad = 0,
            .data = @splat(0),
        };
        @memcpy(frame.data[0..raw.len], raw.data[0..raw.len]);
        return frame;
    }
    if (bytes.len == fd_mtu) {
        var raw: CanFdFrame = undefined;
        @memcpy(std.mem.asBytes(&raw), bytes);
        if (raw.len > max_payload_len) return null;
        const is_error = raw.id & can_err_flag != 0;
        const is_extended = raw.id & can_eff_flag != 0;
        var frame = Frame{
            .timestamp_ns = timestamp_ns,
            .id = raw.id & (if (is_error) can_err_mask else if (is_extended) can_eff_mask else can_sff_mask),
            .bus = 0,
            .len = raw.len,
            .flags = .{
                .extended = is_extended,
                .fd = true,
                .brs = raw.flags & can_fd_brs != 0,
                .esi = raw.flags & can_fd_esi != 0,
                .err = is_error,
            },
            ._pad = 0,
            .data = @splat(0),
        };
        @memcpy(frame.data[0..raw.len], raw.data[0..raw.len]);
        return frame;
    }
    return null;
}

fn encodeCanId(frame: *const Frame) u32 {
    return (if (frame.flags.extended) can_eff_flag else 0) |
        (if (frame.flags.rtr) can_rtr_flag else 0) |
        (frame.id & (if (frame.flags.extended) can_eff_mask else can_sff_mask));
}

fn validFdLength(len: u8) bool {
    return len <= 8 or switch (len) {
        12, 16, 20, 24, 32, 48, 64 => true,
        else => false,
    };
}

fn write(ptr: *anyopaque, frame: *const Frame, timeout_ns: u64) adapter.Error!void {
    _ = timeout_ns;
    const instance: *SocketCan = @ptrCast(@alignCast(ptr));
    if (instance.listen_only) return error.ListenOnly;
    if (frame.flags.err or frame.len > max_payload_len) return error.InvalidFrame;
    if ((!frame.flags.extended and frame.id > can_sff_mask) or (frame.flags.extended and frame.id > can_eff_mask)) return error.InvalidFrame;

    if (frame.flags.fd) {
        if (!validFdLength(frame.len) or frame.flags.rtr) return error.InvalidFrame;
        var raw = CanFdFrame{
            .id = encodeCanId(frame),
            .len = frame.len,
            .flags = (if (frame.flags.brs) can_fd_brs else 0) | (if (frame.flags.esi) can_fd_esi else 0),
            .res0 = 0,
            .res1 = 0,
            .data = @splat(0),
        };
        @memcpy(raw.data[0..frame.len], frame.data[0..frame.len]);
        writeRaw(instance.fd, &raw, @sizeOf(CanFdFrame)) catch |err| {
            recordError(instance, err);
            return err;
        };
        return;
    }

    if (frame.len > 8 or frame.flags.brs or frame.flags.esi) return error.InvalidFrame;
    var raw = CanFrame{
        .id = encodeCanId(frame),
        .len = frame.len,
        .pad = 0,
        .res0 = 0,
        .len8_dlc = 0,
        .data = @splat(0),
    };
    if (!frame.flags.rtr) @memcpy(raw.data[0..frame.len], frame.data[0..frame.len]);
    writeRaw(instance.fd, &raw, @sizeOf(CanFrame)) catch |err| {
        recordError(instance, err);
        return err;
    };
}

fn writeRaw(fd: linux.fd_t, raw: anytype, len: usize) adapter.Error!void {
    const result = linux.write(fd, @ptrCast(raw), len);
    const errno = linux.errno(result);
    if (errno != .SUCCESS) return mapErrno(errno);
    if (result != len) return error.IoFailure;
}

fn status(ptr: *anyopaque) adapter.Status {
    const instance: *SocketCan = @ptrCast(@alignCast(ptr));
    return @fromBackingInt(@intCast(instance.status_code.load(.acquire)));
}

fn recordError(instance: *SocketCan, err: adapter.Error) void {
    const state: adapter.Status = switch (err) {
        error.Disconnected => .disconnected,
        error.BusOff => .bus_off,
        error.QueueFull => .warning,
        else => .warning,
    };
    instance.status_code.store(@intCast(@backingInt(state)), .release);
}

fn close(ptr: *anyopaque) void {
    const instance: *SocketCan = @ptrCast(@alignCast(ptr));
    closeFd(instance.fd);
    instance.allocator.destroy(instance);
}

const vtable = adapter.Adapter.VTable{
    .read = read,
    .write = write,
    .status = status,
    .close = close,
};

test "SocketCAN decodes classic and FD frames" {
    var classic = CanFrame{
        .id = can_eff_flag | 0x18ff50e5,
        .len = 8,
        .pad = 0,
        .res0 = 0,
        .len8_dlc = 0,
        .data = .{ 1, 2, 3, 4, 5, 6, 7, 8 },
    };
    const decoded_classic = decodeFrame(std.mem.asBytes(&classic), 99).?;
    try std.testing.expectEqual(@as(u32, 0x18ff50e5), decoded_classic.id);
    try std.testing.expect(decoded_classic.flags.extended);
    try std.testing.expectEqual(@as(u8, 8), decoded_classic.len);
    try std.testing.expectEqualSlices(u8, &classic.data, decoded_classic.data[0..8]);

    var fd = CanFdFrame{
        .id = can_eff_flag | 0x18ff50e5,
        .len = 12,
        .flags = can_fd_brs,
        .res0 = 0,
        .res1 = 0,
        .data = @splat(0),
    };
    fd.data[0] = 0xa5;
    const decoded_fd = decodeFrame(std.mem.asBytes(&fd), 100).?;
    try std.testing.expect(decoded_fd.flags.fd and decoded_fd.flags.brs);
    try std.testing.expectEqual(@as(u8, 12), decoded_fd.len);
    try std.testing.expectEqual(@as(u8, 0xa5), decoded_fd.data[0]);
}

test "SocketCAN classic frame round-trip on vcan0 when available" {
    const allocator = std.testing.allocator;
    const channels = try backend.enumerate(allocator);
    defer allocator.free(channels);
    var has_vcan0 = false;
    for (channels) |channel| {
        if (std.mem.eql(u8, channel.nameSlice(), "vcan0")) has_vcan0 = true;
    }
    if (!has_vcan0) return error.SkipZigTest;

    var sender = try backend.open(allocator, .{ .channel = "vcan0" });
    defer sender.deinit();
    var receiver = try backend.open(allocator, .{ .channel = "vcan0" });
    defer receiver.deinit();
    const frame = Frame{
        .timestamp_ns = 0,
        .id = 0x321,
        .bus = 0,
        .len = 8,
        .flags = .{},
        ._pad = 0,
        .data = .{ 1, 2, 3, 4, 5, 6, 7, 8 } ++ @as([56]u8, @splat(0)),
    };
    sender.write(&frame, 0) catch |err| {
        if (err == error.Disconnected) return error.SkipZigTest;
        return err;
    };

    var received: [1]Frame = undefined;
    const count = try receiver.read(&received, 50 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(frame.id, received[0].id);
    try std.testing.expectEqual(frame.len, received[0].len);
    try std.testing.expectEqualSlices(u8, frame.data[0..frame.len], received[0].data[0..received[0].len]);
}
