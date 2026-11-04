const std = @import("std");
const builtin = @import("builtin");

const is_linux = builtin.os.tag == .linux;
const is_windows = builtin.os.tag == .windows;
const CallConv = if (is_windows) std.lang.CallingConvention.winapi else std.lang.CallingConvention.c;
const LinuxDynLib = if (is_linux) std.DynLib else void;

pub const Handle = u16;
pub const StatusCode = u32;

pub const ok: StatusCode = 0x0000_0000;
pub const transmit_full: StatusCode = 0x0000_0001;
pub const receive_empty: StatusCode = 0x0000_0020;
pub const queue_overrun: StatusCode = 0x0000_0040;
pub const queue_transmit_full: StatusCode = 0x0000_0080;
pub const bus_light: StatusCode = 0x0000_0004;
pub const bus_heavy: StatusCode = 0x0000_0008;
pub const bus_off: StatusCode = 0x0000_0010;
pub const device_not_found: StatusCode = 0x0000_0200;
pub const hardware_in_use: StatusCode = 0x0000_0400;

pub const channel_condition_parameter: u8 = 0x02;
pub const receive_event_parameter: u8 = 0x03;
pub const listen_only_parameter: u8 = 0x08;
pub const channel_available: u32 = 0x01;
pub const channel_occupied: u32 = 0x02;

pub const Message = extern struct {
    message_type: u8 = 0,
    id: u32 = 0,
    len: u8 = 0,
    data: [8]u8 = @splat(0),
};

pub const MessageFd = extern struct {
    id: u32 = 0,
    message_type: u8 = 0,
    dlc: u8 = 0,
    data: [64]u8 = @splat(0),
};

pub const Timestamp = extern struct {
    millis: u32 = 0,
    millis_overflow: u16 = 0,
    micros: u16 = 0,
};

pub const TimestampFd = u64;

pub const InitializeFn = *const fn (Handle, u16, u32, u32, u16) callconv(CallConv) StatusCode;
pub const InitializeFdFn = *const fn (Handle, [*:0]const u8) callconv(CallConv) StatusCode;
pub const UninitializeFn = *const fn (Handle) callconv(CallConv) StatusCode;
pub const ReadFn = *const fn (Handle, *Message, *Timestamp) callconv(CallConv) StatusCode;
pub const ReadFdFn = *const fn (Handle, *MessageFd, *TimestampFd) callconv(CallConv) StatusCode;
pub const WriteFn = *const fn (Handle, *const Message) callconv(CallConv) StatusCode;
pub const WriteFdFn = *const fn (Handle, *const MessageFd) callconv(CallConv) StatusCode;
pub const GetStatusFn = *const fn (Handle) callconv(CallConv) StatusCode;
pub const GetValueFn = *const fn (Handle, u8, *anyopaque, u32) callconv(CallConv) StatusCode;
pub const SetValueFn = *const fn (Handle, u8, *const anyopaque, u32) callconv(CallConv) StatusCode;
pub const GetErrorTextFn = *const fn (StatusCode, u16, [*]u8) callconv(CallConv) StatusCode;

pub const Library = union(enum) {
    linux: LinuxDynLib,
    windows: *anyopaque,

    pub fn open() error{LibraryNotFound}!Library {
        if (comptime is_linux) {
            inline for (.{ "libpcanbasic.so", "libpcanbasic.so.0" }) |name| {
                const zero_terminated: [:0]const u8 = name ++ "\x00";
                if (std.DynLib.openZ(zero_terminated)) |library| return .{ .linux = library } else |_| {}
            }
            return error.LibraryNotFound;
        } else if (comptime is_windows) {
            inline for (.{ "PCANBasic.dll", "PCANBasic_x64.dll" }) |name| {
                if (loadWindows(name)) |handle| return .{ .windows = handle } else |_| {}
            }
            return error.LibraryNotFound;
        } else {
            return error.LibraryNotFound;
        }
    }

    pub fn close(self: *Library) void {
        switch (self.*) {
            .linux => |*library| if (comptime is_linux) library.close(),
            .windows => |handle| if (comptime is_windows) unloadWindows(handle),
        }
    }

    pub fn symbol(self: *Library, comptime T: type, name: [:0]const u8) ?T {
        return switch (self.*) {
            .linux => |*library| if (comptime is_linux) library.lookup(T, name) else null,
            .windows => |handle| if (comptime is_windows) lookupWindows(T, handle, name) else null,
        };
    }
};

pub const Api = struct {
    library: Library,
    initialize: InitializeFn,
    initialize_fd: ?InitializeFdFn,
    uninitialize: UninitializeFn,
    read: ReadFn,
    read_fd: ?ReadFdFn,
    write: WriteFn,
    write_fd: ?WriteFdFn,
    get_status: GetStatusFn,
    get_value: GetValueFn,
    set_value: SetValueFn,
    get_error_text: ?GetErrorTextFn,

    pub const LoadError = error{LibraryNotFound} || error{MissingSymbol};

    pub fn load() LoadError!Api {
        var library = try Library.open();
        errdefer library.close();
        return .{
            .library = library,
            .initialize = library.symbol(InitializeFn, "CAN_Initialize") orelse return error.MissingSymbol,
            .initialize_fd = library.symbol(InitializeFdFn, "CAN_InitializeFD"),
            .uninitialize = library.symbol(UninitializeFn, "CAN_Uninitialize") orelse return error.MissingSymbol,
            .read = library.symbol(ReadFn, "CAN_Read") orelse return error.MissingSymbol,
            .read_fd = library.symbol(ReadFdFn, "CAN_ReadFD"),
            .write = library.symbol(WriteFn, "CAN_Write") orelse return error.MissingSymbol,
            .write_fd = library.symbol(WriteFdFn, "CAN_WriteFD"),
            .get_status = library.symbol(GetStatusFn, "CAN_GetStatus") orelse return error.MissingSymbol,
            .get_value = library.symbol(GetValueFn, "CAN_GetValue") orelse return error.MissingSymbol,
            .set_value = library.symbol(SetValueFn, "CAN_SetValue") orelse return error.MissingSymbol,
            .get_error_text = library.symbol(GetErrorTextFn, "CAN_GetErrorText"),
        };
    }

    pub fn close(self: *Api) void {
        self.library.close();
    }
};

pub fn mapStatus(code: StatusCode) enum { ok, empty, queue_full, warning, passive, bus_off, disconnected, failure } {
    if (code == ok) return .ok;
    if (code & receive_empty != 0) return .empty;
    if (code & (transmit_full | queue_transmit_full) != 0) return .queue_full;
    if (code & bus_off != 0) return .bus_off;
    if (code & bus_heavy != 0) return .passive;
    if (code & bus_light != 0) return .warning;
    if (code & (device_not_found | hardware_in_use) != 0) return .disconnected;
    return .failure;
}

fn loadWindows(name: []const u8) error{LibraryNotFound}!*anyopaque {
    const windows = std.os.windows;
    var wide: [32]u16 = undefined;
    if (name.len + 1 > wide.len) return error.LibraryNotFound;
    for (name, 0..) |byte, index| wide[index] = byte;
    wide[name.len] = 0;
    var unicode = windows.UNICODE_STRING{
        .Length = @intCast(name.len * 2),
        .MaximumLength = @intCast(name.len * 2),
        .Buffer = &wide,
    };
    var handle: *anyopaque = undefined;
    const status = windows.ntdll.LdrLoadDll(null, null, &unicode, &handle);
    if (@backingInt(status) & 0x8000_0000 != 0) return error.LibraryNotFound;
    return handle;
}

fn unloadWindows(handle: *anyopaque) void {
    _ = std.os.windows.ntdll.LdrUnloadDll(handle);
}

fn lookupWindows(comptime T: type, handle: *anyopaque, name: [:0]const u8) ?T {
    const windows = std.os.windows;
    var address: *anyopaque = undefined;
    const ansi = windows.ANSI_STRING.init(name);
    const status = windows.ntdll.LdrGetProcedureAddress(handle, &ansi, 0, &address);
    if (@backingInt(status) & 0x8000_0000 != 0) return null;
    return @ptrCast(@alignCast(address));
}

test "PCAN status mapping distinguishes queue, bus, and device states" {
    try std.testing.expectEqual(.ok, mapStatus(ok));
    try std.testing.expectEqual(.empty, mapStatus(receive_empty));
    try std.testing.expectEqual(.empty, mapStatus(receive_empty | queue_overrun));
    try std.testing.expectEqual(.queue_full, mapStatus(queue_transmit_full));
    try std.testing.expectEqual(.warning, mapStatus(bus_light));
    try std.testing.expectEqual(.passive, mapStatus(bus_heavy));
    try std.testing.expectEqual(.bus_off, mapStatus(bus_off));
    try std.testing.expectEqual(.disconnected, mapStatus(device_not_found));
}
