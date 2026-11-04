const std = @import("std");
const Frame = @import("frame.zig").Frame;

pub const Error = error{
    OutOfMemory,
    InvalidChannel,
    Unsupported,
    ListenOnly,
    InvalidFrame,
    Disconnected,
    QueueFull,
    ResourceExhausted,
    BackendUnavailable,
    BusOff,
    IoFailure,
};

pub const Status = enum {
    ok,
    warning,
    passive,
    bus_off,
    disconnected,
};

pub const Capabilities = struct {
    fd: bool = false,
    hw_timestamps: bool = false,
    error_frames: bool = false,
    set_bitrate: bool = false,
};

pub const ChannelInfo = struct {
    pub const name_capacity = 32;

    backend: []const u8,
    name: [name_capacity]u8,
    description: []const u8,
    capabilities: Capabilities,

    pub fn init(backend_name: []const u8, channel_name: []const u8, description: []const u8, capabilities: Capabilities) Error!ChannelInfo {
        if (channel_name.len >= name_capacity) return error.InvalidChannel;
        var name: [name_capacity]u8 = @splat(0);
        @memcpy(name[0..channel_name.len], channel_name);
        return .{
            .backend = backend_name,
            .name = name,
            .description = description,
            .capabilities = capabilities,
        };
    }

    pub fn nameSlice(self: *const ChannelInfo) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }
};

pub const ChannelConfig = struct {
    channel: []const u8,
    nominal_bitrate: ?u32 = null,
    data_bitrate: ?u32 = null,
    listen_only: bool = false,
    receive_own_messages: bool = false,
};

pub const Adapter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (*anyopaque, out: []Frame, timeout_ns: u64) Error!usize,
        write: *const fn (*anyopaque, frame: *const Frame, timeout_ns: u64) Error!void,
        status: *const fn (*anyopaque) Status,
        close: *const fn (*anyopaque) void,
    };

    pub fn read(self: *Adapter, out: []Frame, timeout_ns: u64) Error!usize {
        return self.vtable.read(self.ptr, out, timeout_ns);
    }

    pub fn write(self: *Adapter, frame: *const Frame, timeout_ns: u64) Error!void {
        return self.vtable.write(self.ptr, frame, timeout_ns);
    }

    pub fn status(self: *const Adapter) Status {
        return self.vtable.status(self.ptr);
    }

    pub fn deinit(self: *Adapter) void {
        self.vtable.close(self.ptr);
        self.* = undefined;
    }
};

pub const Backend = struct {
    name: []const u8,
    capabilities: Capabilities,
    enumerate: *const fn (std.mem.Allocator) Error![]ChannelInfo,
    open: *const fn (std.mem.Allocator, ChannelConfig) Error!Adapter,
};
