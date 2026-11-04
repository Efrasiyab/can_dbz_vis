pub const max_payload_len = 64;

pub const Flags = packed struct(u8) {
    extended: bool = false,
    fd: bool = false,
    brs: bool = false,
    esi: bool = false,
    rtr: bool = false,
    err: bool = false,
    tx_echo: bool = false,
    _pad: bool = false,
};

pub const Frame = extern struct {
    timestamp_ns: u64,
    id: u32,
    bus: u8,
    len: u8,
    flags: Flags,
    _pad: u8,
    data: [max_payload_len]u8,
};

test "Frame has a fixed layout and byte-sized flags" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(Frame));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(Frame));

    const flags: Flags = .{
        .extended = true,
        .fd = true,
        .brs = true,
        .esi = true,
        .rtr = true,
        .err = true,
        .tx_echo = true,
    };
    try std.testing.expectEqual(@as(u8, 0x7f), @as(u8, @bitCast(flags)));
}
