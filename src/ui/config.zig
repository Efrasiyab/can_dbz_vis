const std = @import("std");
const Database = @import("../db/database.zig").Database;

pub const max_pins = 64;

pub const Settings = struct {
    version: u8 = 1,
    fps: u32 = 30,
    plot_window_seconds: u32 = 10,
};

pub const Pin = struct {
    message: usize,
    signal: ?usize = null,
};

pub const PinSet = struct {
    items: [max_pins]?Pin = @splat(null),
    len: usize = 0,

    pub const Error = error{TooManyPins};

    pub fn contains(self: *const PinSet, pin: Pin) bool {
        for (self.items[0..self.len]) |item| {
            if (item.?.message == pin.message and item.?.signal == pin.signal) return true;
        }
        return false;
    }

    pub fn toggle(self: *PinSet, pin: Pin) Error!void {
        for (0..self.len) |index| {
            const existing = self.items[index].?;
            if (existing.message != pin.message or existing.signal != pin.signal) continue;
            for (index..self.len - 1) |move_index| self.items[move_index] = self.items[move_index + 1];
            self.len -= 1;
            self.items[self.len] = null;
            return;
        }
        if (self.len == max_pins) return error.TooManyPins;
        self.items[self.len] = pin;
        self.len += 1;
    }
};

pub const max_plotted_signals = 20;

pub const PlotSignal = struct {
    message: usize,
    signal: usize,
    plot_index: u8 = 0,
    window_ns: u64 = 10 * std.time.ns_per_s,
};

pub const PlotSet = struct {
    items: [max_plotted_signals]?PlotSignal = @splat(null),
    len: usize = 0,
    plot_count: usize = 0,
    plot_windows_ns: [max_plotted_signals]u64 = @splat(10 * std.time.ns_per_s),
    columns_override: ?u8 = null,

    pub const Error = error{TooManySignals};

    pub fn contains(self: *const PlotSet, item: PlotSignal) bool {
        for (self.items[0..self.len]) |existing| {
            if (existing.?.message == item.message and existing.?.signal == item.signal) return true;
        }
        return false;
    }

    pub fn toggle(self: *PlotSet, item: PlotSignal) Error!void {
        for (0..self.len) |index| {
            const existing = self.items[index].?;
            if (existing.message != item.message or existing.signal != item.signal) continue;
            for (index..self.len - 1) |move_index| self.items[move_index] = self.items[move_index + 1];
            self.len -= 1;
            self.items[self.len] = null;
            return;
        }
        if (self.len == max_plotted_signals) return error.TooManySignals;
        self.items[self.len] = item;
        self.len += 1;
        self.plot_count = @max(self.plot_count, @as(usize, item.plot_index) + 1);
        self.plot_windows_ns[item.plot_index] = item.window_ns;
    }
};

const SavedPin = struct {
    kind: []const u8,
    bus: []const u8,
    id: []const u8,
    ext: bool,
    message: []const u8,
    signal: ?[]const u8 = null,
    plot: ?u8 = null,
    window_ns: ?u64 = null,
    columns: ?u8 = null,
};

const PinsFile = struct {
    version: u8 = 1,
    database: []const u8,
    pins: []const SavedPin,
};

pub fn databaseHash(source: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn configDirectory(allocator: std.mem.Allocator, xdg_config_home: ?[]const u8, home: []const u8) std.mem.Allocator.Error![]u8 {
    if (xdg_config_home) |path| {
        if (path.len != 0) return std.fs.path.join(allocator, &.{ path, "can_dbz_vis" });
    }
    return std.fs.path.join(allocator, &.{ home, ".config", "can_dbz_vis" });
}

pub fn loadSettings(allocator: std.mem.Allocator, io: std.Io, config_dir: []const u8) !Settings {
    try std.Io.Dir.cwd().createDirPath(io, config_dir);
    var directory = try std.Io.Dir.cwd().openDir(io, config_dir, .{});
    defer directory.close(io);
    const source = directory.readFileAlloc(io, "settings.json", allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer allocator.free(source);
    const parsed = std.json.parseFromSlice(Settings, allocator, source, .{ .allocate = .alloc_always }) catch return error.InvalidSettingsFile;
    defer parsed.deinit();
    if (parsed.value.version != 1 or parsed.value.fps < 10 or parsed.value.fps > 120 or parsed.value.plot_window_seconds == 0 or parsed.value.plot_window_seconds > 600) return .{};
    return parsed.value;
}

pub fn saveSettings(allocator: std.mem.Allocator, io: std.Io, config_dir: []const u8, settings: Settings) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, settings, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    try writeAtomic(io, config_dir, "settings.json", json);
}

pub fn loadPins(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_dir: []const u8,
    hash: []const u8,
    database: *const Database,
) !PinSet {
    const directory_path = try std.fs.path.join(allocator, &.{ config_dir, "pins" });
    defer allocator.free(directory_path);
    try std.Io.Dir.cwd().createDirPath(io, directory_path);
    var directory = try std.Io.Dir.cwd().openDir(io, directory_path, .{});
    defer directory.close(io);

    const file_name = try std.fmt.allocPrint(allocator, "{s}.json", .{hash});
    defer allocator.free(file_name);
    const source = directory.readFileAlloc(io, file_name, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer allocator.free(source);

    const parsed = std.json.parseFromSlice(PinsFile, allocator, source, .{ .allocate = .alloc_always }) catch return error.InvalidPinsFile;
    defer parsed.deinit();
    if (parsed.value.version != 1) return error.UnsupportedPinsVersion;

    var result: PinSet = .{};
    for (parsed.value.pins) |saved| {
        const id = std.fmt.parseInt(u32, saved.id, 16) catch continue;
        const handle = database.compiled.findMessage(saved.bus, id, saved.ext) orelse continue;
        const message = database.compiled.messages[handle];
        if (!std.mem.eql(u8, message.name, saved.message)) continue;
        const signal = if (saved.signal) |name| try database.compiled.findSignal(handle, name) else null;
        if (saved.signal != null and signal == null) continue;
        try result.toggle(.{ .message = handle, .signal = signal });
    }
    return result;
}

pub fn savePins(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_dir: []const u8,
    hash: []const u8,
    database: *const Database,
    pins: *const PinSet,
) !void {
    const directory_path = try std.fs.path.join(allocator, &.{ config_dir, "pins" });
    defer allocator.free(directory_path);
    try std.Io.Dir.cwd().createDirPath(io, directory_path);
    var directory = try std.Io.Dir.cwd().openDir(io, directory_path, .{});
    defer directory.close(io);

    var saved: [max_pins]SavedPin = undefined;
    var id_buffers: [max_pins][8]u8 = undefined;
    for (pins.items[0..pins.len], 0..) |item, index| {
        const pin = item.?;
        const message = database.compiled.messages[pin.message];
        const id = try std.fmt.bufPrint(&id_buffers[index], "{X}", .{message.id});
        saved[index] = .{
            .kind = if (pin.signal == null) "message" else "signal",
            .bus = message.bus,
            .id = id,
            .ext = message.extended,
            .message = message.name,
            .signal = if (pin.signal) |signal_index| message.signals[signal_index].name else null,
        };
    }

    const json = try std.json.Stringify.valueAlloc(allocator, PinsFile{
        .database = database.doc.name orelse "",
        .pins = saved[0..pins.len],
    }, .{ .whitespace = .indent_2 });
    defer allocator.free(json);

    const file_name = try std.fmt.allocPrint(allocator, "{s}.json", .{hash});
    defer allocator.free(file_name);
    try writeAtomic(io, directory_path, file_name, json);
}

pub fn loadPlots(allocator: std.mem.Allocator, io: std.Io, config_dir: []const u8, hash: []const u8, database: *const Database) !PlotSet {
    const directory_path = try std.fs.path.join(allocator, &.{ config_dir, "plots" });
    defer allocator.free(directory_path);
    try std.Io.Dir.cwd().createDirPath(io, directory_path);
    var directory = try std.Io.Dir.cwd().openDir(io, directory_path, .{});
    defer directory.close(io);
    const file_name = try std.fmt.allocPrint(allocator, "{s}.json", .{hash});
    defer allocator.free(file_name);
    const source = directory.readFileAlloc(io, file_name, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer allocator.free(source);
    const parsed = std.json.parseFromSlice(PinsFile, allocator, source, .{ .allocate = .alloc_always }) catch return error.InvalidPlotsFile;
    defer parsed.deinit();
    if (parsed.value.version != 1) return error.UnsupportedPlotsVersion;

    var result: PlotSet = .{};
    for (parsed.value.pins) |saved| {
        const signal_name = saved.signal orelse continue;
        const id = std.fmt.parseInt(u32, saved.id, 16) catch continue;
        const handle = database.compiled.findMessage(saved.bus, id, saved.ext) orelse continue;
        const message = database.compiled.messages[handle];
        if (!std.mem.eql(u8, message.name, saved.message)) continue;
        const signal = try database.compiled.findSignal(handle, signal_name) orelse continue;
        const plot_index = saved.plot orelse 0;
        const window_ns = saved.window_ns orelse 10 * std.time.ns_per_s;
        result.toggle(.{ .message = handle, .signal = signal, .plot_index = plot_index, .window_ns = window_ns }) catch break;
        result.columns_override = saved.columns;
    }
    return result;
}

pub fn savePlots(allocator: std.mem.Allocator, io: std.Io, config_dir: []const u8, hash: []const u8, database: *const Database, plots: *const PlotSet) !void {
    const directory_path = try std.fs.path.join(allocator, &.{ config_dir, "plots" });
    defer allocator.free(directory_path);
    try std.Io.Dir.cwd().createDirPath(io, directory_path);
    var saved: [max_plotted_signals]SavedPin = undefined;
    var id_buffers: [max_plotted_signals][8]u8 = undefined;
    for (plots.items[0..plots.len], 0..) |maybe_plot, index| {
        const plot = maybe_plot.?;
        const message = database.compiled.messages[plot.message];
        const signal_index = plot.signal;
        const id = try std.fmt.bufPrint(&id_buffers[index], "{X}", .{message.id});
        saved[index] = .{
            .kind = "signal",
            .bus = message.bus,
            .id = id,
            .ext = message.extended,
            .message = message.name,
            .signal = message.signals[signal_index].name,
            .plot = plot.plot_index,
            .window_ns = plots.plot_windows_ns[plot.plot_index],
            .columns = plots.columns_override,
        };
    }
    const json = try std.json.Stringify.valueAlloc(allocator, PinsFile{
        .database = database.doc.name orelse "",
        .pins = saved[0..plots.len],
    }, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    const file_name = try std.fmt.allocPrint(allocator, "{s}.json", .{hash});
    defer allocator.free(file_name);
    try writeAtomic(io, directory_path, file_name, json);
}

fn writeAtomic(io: std.Io, directory_path: []const u8, file_name: []const u8, contents: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, directory_path);
    var directory = try std.Io.Dir.cwd().openDir(io, directory_path, .{});
    defer directory.close(io);
    var atomic = try directory.createFileAtomic(io, file_name, .{ .replace = true });
    defer atomic.deinit(io);
    var buffer: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    try writer.interface.writeAll(contents);
    try writer.interface.flush();
    try atomic.replace(io);
}

test "pin set toggles message and signal pins independently" {
    var pins: PinSet = .{};
    try pins.toggle(.{ .message = 7 });
    try pins.toggle(.{ .message = 7, .signal = 2 });
    try std.testing.expectEqual(@as(usize, 2), pins.len);
    try std.testing.expect(pins.contains(.{ .message = 7 }));
    try std.testing.expect(pins.contains(.{ .message = 7, .signal = 2 }));

    try pins.toggle(.{ .message = 7 });
    try std.testing.expectEqual(@as(usize, 1), pins.len);
    try std.testing.expect(!pins.contains(.{ .message = 7 }));
}

test "database config directory honors XDG override" {
    const path = try configDirectory(std.testing.allocator, "/tmp/config", "/home/test");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/config/can_dbz_vis", path);
}

test "pins persist as database-scoped JSON and reload to compiled handles" {
    const allocator = std.testing.allocator;
    const Diagnostics = @import("../db/database.zig").Diagnostics;
    const source =
        \\VERSION ""
        \\
        \\NS_ :
        \\
        \\BS_:
        \\
        \\BU_: ECU
        \\
        \\BO_ 192 EngineData: 8 ECU
        \\ SG_ RPM : 0|16@1+ (0.25,0) [0|16383.75] "rpm" Vector__XXX
        \\
    ;
    var diagnostics: Diagnostics = .empty;
    defer diagnostics.deinit(allocator);
    var database = try Database.init(allocator, .dbc, source, &diagnostics);
    defer database.deinit();
    const handle = database.compiled.findMessage("can0", 192, false).?;
    var pins: PinSet = .{};
    try pins.toggle(.{ .message = handle });
    try pins.toggle(.{ .message = handle, .signal = 0 });

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const config_dir = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &temporary.sub_path });
    defer allocator.free(config_dir);
    const hash = databaseHash(source);
    try savePins(allocator, std.testing.io, config_dir, &hash, &database, &pins);
    const loaded = try loadPins(allocator, std.testing.io, config_dir, &hash, &database);
    try std.testing.expectEqual(@as(usize, 2), loaded.len);
    try std.testing.expect(loaded.contains(.{ .message = handle }));
    try std.testing.expect(loaded.contains(.{ .message = handle, .signal = 0 }));

    var plots: PlotSet = .{};
    plots.columns_override = 3;
    try plots.toggle(.{ .message = handle, .signal = 0, .plot_index = 2, .window_ns = 100_000 });
    try savePlots(allocator, std.testing.io, config_dir, &hash, &database, &plots);
    const loaded_plots = try loadPlots(allocator, std.testing.io, config_dir, &hash, &database);
    try std.testing.expectEqual(@as(usize, 1), loaded_plots.len);
    try std.testing.expect(loaded_plots.contains(.{ .message = handle, .signal = 0, .plot_index = 2, .window_ns = 100_000 }));
    try std.testing.expectEqual(@as(u64, 100_000), loaded_plots.plot_windows_ns[2]);
    try std.testing.expectEqual(@as(?u8, 3), loaded_plots.columns_override);

    const settings = Settings{ .fps = 45, .plot_window_seconds = 20 };
    try saveSettings(allocator, std.testing.io, config_dir, settings);
    const loaded_settings = try loadSettings(allocator, std.testing.io, config_dir);
    try std.testing.expectEqual(settings.fps, loaded_settings.fps);
    try std.testing.expectEqual(settings.plot_window_seconds, loaded_settings.plot_window_seconds);
}
