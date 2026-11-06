const std = @import("std");
const can_dbz = @import("can_dbz");
const adapter = @import("../can/adapter.zig");
const registry = @import("../can/registry.zig");

pub const max_channels = 64;
pub const max_buses = 4;
pub const default_nominal_bitrate: u32 = 500_000;
pub const default_data_bitrate: u32 = 2_000_000;

const nominal_bitrates = [_]u32{ 5_000, 10_000, 20_000, 50_000, 100_000, 125_000, 250_000, 500_000, 800_000, 1_000_000 };
const data_bitrates = [_]u32{ 500_000, 1_000_000, 2_000_000, 4_000_000, 5_000_000, 8_000_000 };

pub const BusSettings = struct {
    nominal_bitrate: u32 = default_nominal_bitrate,
    data_bitrate: u32 = default_data_bitrate,
    use_fd: bool = false,
};

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
    bus_settings: [max_buses]BusSettings = @splat(.{}),
    notice: []const u8 = "",

    pub fn open(
        self: *Dialog,
        allocator: std.mem.Allocator,
        buses: []const can_dbz.model.Bus,
        messages: []const can_dbz.model.Message,
    ) void {
        self.active = true;
        self.choice_count = 0;
        self.selected_channel = 0;
        self.selected_bus = 0;
        self.mappings = @splat(null);
        self.bus_settings = @splat(.{});
        for (buses[0..@min(buses.len, self.bus_settings.len)], 0..) |bus, index| {
            self.bus_settings[index] = settingsForBus(bus, messages);
        }
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

    pub fn cycleNominalBitrate(self: *Dialog) void {
        const settings = &self.bus_settings[self.selected_bus];
        settings.nominal_bitrate = nextRate(settings.nominal_bitrate, &nominal_bitrates);
    }

    pub fn cycleDataBitrate(self: *Dialog) void {
        const settings = &self.bus_settings[self.selected_bus];
        settings.data_bitrate = nextRate(settings.data_bitrate, &data_bitrates);
    }

    pub fn toggleFd(self: *Dialog) void {
        const choice_index = self.mappings[self.selected_bus] orelse {
            self.notice = "Map an FD-capable channel before enabling CAN FD";
            return;
        };
        const choice = self.choices[choice_index].?;
        if (!choice.channel.capabilities.fd and !self.bus_settings[self.selected_bus].use_fd) {
            self.notice = "Selected channel does not support CAN FD";
            return;
        }
        self.bus_settings[self.selected_bus].use_fd = !self.bus_settings[self.selected_bus].use_fd;
        self.notice = if (self.bus_settings[self.selected_bus].use_fd) "CAN FD enabled" else "Classic CAN enabled";
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

fn nextRate(current: u32, choices: []const u32) u32 {
    for (choices, 0..) |rate, index| {
        if (rate == current) return choices[(index + 1) % choices.len];
    }
    return choices[0];
}

fn settingsForBus(bus: can_dbz.model.Bus, messages: []const can_dbz.model.Message) BusSettings {
    var settings = BusSettings{
        .nominal_bitrate = bus.nominal_bitrate orelse default_nominal_bitrate,
        .data_bitrate = bus.data_bitrate orelse default_data_bitrate,
        .use_fd = bus.data_bitrate != null,
    };
    for (messages) |message| {
        if (message.frame == .fd and std.mem.eql(u8, message.bus, bus.name)) settings.use_fd = true;
    }
    return settings;
}

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

test "connect settings propose database rates and detect FD messages" {
    const bus = can_dbz.model.Bus{ .name = "can0", .nominal_bitrate = 250_000, .data_bitrate = 2_000_000 };
    const messages = [_]can_dbz.model.Message{.{
        .name = "FastStatus",
        .bus = "can0",
        .id = "0x123",
        .extended = false,
        .frame = .fd,
        .length = 12,
    }};
    const settings = settingsForBus(bus, &messages);
    try std.testing.expectEqual(@as(u32, 250_000), settings.nominal_bitrate);
    try std.testing.expectEqual(@as(u32, 2_000_000), settings.data_bitrate);
    try std.testing.expect(settings.use_fd);
}

test "connect bitrate controls cycle their configured presets" {
    var dialog = Dialog{};
    dialog.cycleNominalBitrate();
    dialog.cycleDataBitrate();
    try std.testing.expectEqual(@as(u32, 800_000), dialog.bus_settings[0].nominal_bitrate);
    try std.testing.expectEqual(@as(u32, 4_000_000), dialog.bus_settings[0].data_bitrate);
}

test "connect FD mode requires an FD-capable mapped channel" {
    var dialog = Dialog{ .choice_count = 1 };
    dialog.choices[0] = .{
        .backend = registry.all()[0],
        .channel = try adapter.ChannelInfo.init("test", "channel0", "test channel", .{ .fd = true }),
    };
    dialog.mappings[0] = 0;
    dialog.toggleFd();
    try std.testing.expect(dialog.bus_settings[0].use_fd);

    dialog.choices[0].?.channel.capabilities.fd = false;
    dialog.toggleFd();
    try std.testing.expect(!dialog.bus_settings[0].use_fd);
    dialog.toggleFd();
    try std.testing.expect(!dialog.bus_settings[0].use_fd);
    try std.testing.expectEqualStrings("Selected channel does not support CAN FD", dialog.notice);
}
