const std = @import("std");

pub fn nowNs(io: std.Io) u64 {
    const timestamp = std.Io.Clock.awake.now(io);
    return @intCast(@max(timestamp.nanoseconds, 0));
}

pub const Normalizer = struct {
    source_anchor_ns: u64,
    monotonic_anchor_ns: u64,

    pub fn init(source_anchor_ns: u64, monotonic_anchor_ns: u64) Normalizer {
        return .{
            .source_anchor_ns = source_anchor_ns,
            .monotonic_anchor_ns = monotonic_anchor_ns,
        };
    }

    pub fn normalize(self: Normalizer, source_ns: u64) u64 {
        const offset = @as(i128, source_ns) - @as(i128, self.source_anchor_ns);
        const mapped = @as(i128, self.monotonic_anchor_ns) + offset;
        if (mapped <= 0) return 0;
        if (mapped >= std.math.maxInt(u64)) return std.math.maxInt(u64);
        return @intCast(mapped);
    }
};

test "timestamp normalizer maps into the monotonic anchor domain" {
    const normalizer = Normalizer.init(5_000, 20_000);
    try std.testing.expectEqual(@as(u64, 20_000), normalizer.normalize(5_000));
    try std.testing.expectEqual(@as(u64, 20_250), normalizer.normalize(5_250));
    try std.testing.expectEqual(@as(u64, 19_750), normalizer.normalize(4_750));
}

test "timestamp normalizer saturates at unsigned bounds" {
    const below_zero = Normalizer.init(10, 0);
    try std.testing.expectEqual(@as(u64, 0), below_zero.normalize(0));

    const above_max = Normalizer.init(0, std.math.maxInt(u64));
    try std.testing.expectEqual(std.math.maxInt(u64), above_max.normalize(1));
}

test "software timestamps use a nondecreasing monotonic clock" {
    const first = nowNs(std.testing.io);
    const second = nowNs(std.testing.io);
    try std.testing.expect(second >= first);
}
