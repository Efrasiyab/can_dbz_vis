const std = @import("std");
const adapter = @import("../can/adapter.zig");
const registry = @import("../can/registry.zig");

pub const max_channels = 64;
pub const max_buses = 4;

pub const Choice = struct {
    backend: *const adapter.Backend,
    channel: adapter.ChannelInfo,
};

pub const Dialog = struct {
    active: bool = false,
    choices: [max_channels]?Choice = @splat(null),
    choice_count: usize = 0,
    selected_channel: usize = 0,
    selected_bus: usize = 0,
    mappings: [max_buses]?usize = @splat(null),
    notice: []const u8 = "",

    pub fn open(self: *Dialog, allocator: std.mem.Allocator) void {
        self.active = true;
        self.choice_count = 0;
        self.selected_channel = 0;
        self.selected_bus = 0;
        self.mappings = @splat(null);
        self.notice = "Select a channel, choose a logical bus, then press m to map";
        var peak_unavailable = false;

        for (registry.all()) |backend| {
            const channels = backend.enumerate(allocator) catch |err| {
                if (std.mem.eql(u8, backend.name, "peak")) {
                    peak_unavailable = true;
                    self.notice = if (err == error.BackendUnavailable)
                        "PEAK unavailable: PCAN-Basic library not found"
                    else
                        "PEAK unavailable: PCAN-Basic could not be loaded";
                }
                continue;
            };
            defer allocator.free(channels);
            for (channels) |channel| {
                if (self.choice_count == self.choices.len) break;
                self.choices[self.choice_count] = .{ .backend = backend, .channel = channel };
                self.choice_count += 1;
            }
        }
        if (self.choice_count == 0 and !peak_unavailable) self.notice = "No channels found";
    }

    pub fn close(self: *Dialog) void {
        self.active = false;
    }

    pub fn moveChannel(self: *Dialog, delta: isize) void {
        if (self.choice_count == 0) return;
        const next = @as(i128, @intCast(self.selected_channel)) + delta;
        self.selected_channel = @intCast(@min(@max(next, 0), @as(i128, @intCast(self.choice_count - 1))));
    }

    pub fn moveBus(self: *Dialog, delta: isize, bus_count: usize) void {
        const count = @min(bus_count, max_buses);
        if (count == 0) return;
        const next = @as(i128, @intCast(self.selected_bus)) + delta;
        self.selected_bus = @intCast(@min(@max(next, 0), @as(i128, @intCast(count - 1))));
    }

    pub fn toggleMapping(self: *Dialog) void {
        if (self.choice_count == 0) return;
        if (self.mappings[self.selected_bus] == self.selected_channel) {
            self.mappings[self.selected_bus] = null;
            self.notice = "Mapping removed";
            return;
        }
        for (self.mappings, 0..) |mapping, bus_index| {
            if (mapping == self.selected_channel and bus_index != self.selected_bus) {
                self.notice = "Channel is already mapped to another bus";
                return;
            }
        }
        self.mappings[self.selected_bus] = self.selected_channel;
        self.notice = "Mapping added";
    }

    pub fn mappedCount(self: *const Dialog, bus_count: usize) usize {
        var count: usize = 0;
        for (self.mappings[0..@min(bus_count, self.mappings.len)]) |mapping| {
            if (mapping != null) count += 1;
        }
        return count;
    }

    pub fn selectedChoice(self: *const Dialog) ?Choice {
        if (self.selected_channel >= self.choice_count) return null;
        return self.choices[self.selected_channel];
    }
};

test "connect dialog maps a channel to one logical bus" {
    var dialog = Dialog{
        .choice_count = 2,
        .choices = @splat(null),
    };
    dialog.selected_channel = 1;
    dialog.toggleMapping();
    try std.testing.expectEqual(@as(?usize, 1), dialog.mappings[0]);
    dialog.moveBus(1, 2);
    dialog.moveChannel(-1);
    dialog.toggleMapping();
    try std.testing.expectEqual(@as(?usize, 0), dialog.mappings[1]);
    try std.testing.expectEqual(@as(usize, 2), dialog.mappedCount(2));
}
