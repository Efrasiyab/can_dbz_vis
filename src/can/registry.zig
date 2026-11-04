const builtin = @import("builtin");
const adapter = @import("adapter.zig");
const virtual = @import("virtual.zig");
const build_options = @import("build_options");

const virtual_backends = [_]*const adapter.Backend{&virtual.backend};
const linux_backends = [_]*const adapter.Backend{ &virtual.backend, &@import("socketcan.zig").backend };
const linux_peak_backends = [_]*const adapter.Backend{ &virtual.backend, &@import("socketcan.zig").backend, &@import("pcan.zig").backend };
const windows_peak_backends = [_]*const adapter.Backend{ &virtual.backend, &@import("pcan.zig").backend };

pub fn all() []const *const adapter.Backend {
    if (builtin.os.tag == .linux) {
        if (build_options.peak) return &linux_peak_backends;
        return &linux_backends;
    }
    if (builtin.os.tag == .windows and build_options.peak) return &windows_peak_backends;
    return &virtual_backends;
}

pub fn find(name: []const u8) ?*const adapter.Backend {
    for (all()) |backend| {
        if (@import("std").mem.eql(u8, backend.name, name)) return backend;
    }
    return null;
}

test "PEAK registry presence follows build option and target" {
    const found = find("peak") != null;
    try @import("std").testing.expectEqual(build_options.peak and (builtin.os.tag == .linux or builtin.os.tag == .windows), found);
}
