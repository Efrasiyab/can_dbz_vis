const std = @import("std");
const database = @import("db/database.zig");
const registry = @import("can/registry.zig");
const zz = @import("zigzag");
const Engine = @import("engine/engine.zig").Engine;
const config = @import("ui/config.zig");
const app_ui = @import("ui/ui.zig");
const log_format = @import("log/format.zig");
const ReplaySource = @import("log/replay.zig").ReplaySource;
const DemoSource = @import("demo.zig").Source;

test {
    _ = @import("can/frame.zig");
    _ = @import("can/adapter.zig");
    _ = @import("can/virtual.zig");
    if (@import("build_options").peak) {
        _ = @import("can/pcan_api.zig");
        _ = @import("can/pcan.zig");
    }
    if (@import("builtin").os.tag == .linux) _ = @import("can/socketcan.zig");
    _ = @import("can/registry.zig");
    _ = @import("db/database.zig");
    _ = @import("engine/ingest.zig");
    _ = @import("engine/plot.zig");
    _ = @import("engine/engine.zig");
    _ = @import("engine/rx.zig");
    _ = @import("engine/store.zig");
    _ = @import("engine/tx.zig");
    _ = @import("demo.zig");
    _ = @import("sync/clock.zig");
    _ = @import("sync/spsc.zig");
    _ = @import("sync/triple_buffer.zig");
    _ = @import("ui/config.zig");
    _ = @import("ui/connect.zig");
    _ = @import("ui/monitor.zig");
    _ = @import("ui/plot.zig");
    _ = @import("ui/ui.zig");
    _ = @import("ui/transmit.zig");
    _ = @import("keymap.zig");
    _ = @import("log/format.zig");
    _ = @import("log/index.zig");
    _ = @import("log/replay.zig");
    _ = @import("log/writer.zig");
}

const version = "0.1.0";

const usage =
    \\usage: can_dbz_vis [-h | --help] [--version] [--log PATH] FILE.dbc | FILE.can.json
    \\       can_dbz_vis --replay LOG.canlog.jsonl [FILE.dbc | FILE.can.json]
    \\       can_dbz_vis --replay LOG.canlog.jsonl --speed 2.0 [FILE.dbc | FILE.can.json]
    \\       can_dbz_vis --demo [--log PATH] FILE.dbc | FILE.can.json
    \\       can_dbz_vis --log PATH FILE.dbc | FILE.can.json
    \\       can_dbz_vis --list-channels
    \\
    \\Default mode opens the CAN monitor for the selected database.
    \\--list-channels: list available CAN channels and exit.
    \\--speed X: initial replay speed from 0.1 to 10.0 (default 1.0).
    \\--demo: generate synthetic traffic from the selected database.
    \\
;

fn parseReplaySpeed(value: []const u8) ?u32 {
    const speed = std.fmt.parseFloat(f64, value) catch return null;
    if (!std.math.isFinite(speed) or speed < 0.1 or speed > 10.0) return null;
    return @intFromFloat(speed * 1000);
}

test "replay speed parser enforces the supported range" {
    try std.testing.expectEqual(@as(?u32, 100), parseReplaySpeed("0.1"));
    try std.testing.expectEqual(@as(?u32, 2500), parseReplaySpeed("2.5"));
    try std.testing.expectEqual(@as(?u32, 10_000), parseReplaySpeed("10"));
    try std.testing.expectEqual(@as(?u32, null), parseReplaySpeed("0.01"));
    try std.testing.expectEqual(@as(?u32, null), parseReplaySpeed("NaN"));
}

fn writeChannelList(allocator: std.mem.Allocator, out: *std.Io.Writer) !void {
    for (registry.all()) |backend| {
        const channels = backend.enumerate(allocator) catch |err| {
            try out.print("{s}: unavailable ({s})\n", .{ backend.name, @errorName(err) });
            continue;
        };
        defer allocator.free(channels);
        if (channels.len == 0) {
            try out.print("{s}: no channels found\n", .{backend.name});
            continue;
        }
        for (channels) |channel| {
            try out.print("{s}:{s}  {s}{s}\n", .{
                backend.name,
                channel.nameSlice(),
                channel.description,
                if (channel.capabilities.fd) " [FD]" else "",
            });
        }
    }
}

fn readReplayHeader(io: std.Io, path: []const u8) !log_format.Header {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [8192]u8 = undefined;
    var reader = std.Io.File.Reader.init(file, io, &buffer);
    const line = try reader.interface.takeDelimiterInclusive('\n');
    const record = (try log_format.decodeLine(line[0 .. line.len - 1])) orelse return error.InvalidReplayHeader;
    if (record != .header) return error.InvalidReplayHeader;
    return record.header;
}

fn makeRawReplayDatabase(allocator: std.mem.Allocator, header: log_format.Header) ![]u8 {
    const ReplayBus = struct { name: []const u8 };
    const ReplayMessage = struct {};
    const ReplayDocument = struct {
        format: []const u8 = "can-db",
        format_version: u32 = 1,
        name: []const u8 = "Raw replay",
        buses: []const ReplayBus,
        messages: []const ReplayMessage,
    };
    var buses: [log_format.max_buses]ReplayBus = undefined;
    for (header.buses[0..header.bus_count], 0..) |bus, index| buses[index] = .{ .name = bus.name.slice() };
    const messages: [0]ReplayMessage = .{};
    return std.json.Stringify.valueAlloc(allocator, ReplayDocument{
        .buses = buses[0..header.bus_count],
        .messages = &messages,
    }, .{});
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    var path: ?[]const u8 = null;
    var log_path: ?[]const u8 = null;
    var replay_path: ?[]const u8 = null;
    var expecting_log_path = false;
    var expecting_replay_path = false;
    var expecting_speed = false;
    var replay_speed_milli: u32 = 1000;
    var speed_supplied = false;
    var demo_enabled = false;
    var list_channels = false;
    for (args[1..]) |arg| {
        if (expecting_speed) {
            replay_speed_milli = parseReplaySpeed(arg) orelse return error.InvalidArguments;
            expecting_speed = false;
            continue;
        }
        if (expecting_replay_path) {
            if (replay_path != null or std.mem.startsWith(u8, arg, "-")) return error.InvalidArguments;
            replay_path = arg;
            expecting_replay_path = false;
            continue;
        }
        if (expecting_log_path) {
            if (log_path != null or std.mem.startsWith(u8, arg, "-")) return error.InvalidArguments;
            log_path = arg;
            expecting_log_path = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try out.writeAll(usage);
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            try out.print("can_dbz_vis {s} (backends:", .{version});
            for (registry.all()) |backend| try out.print(" {s}", .{backend.name});
            try out.writeAll(")\n");
            return;
        } else if (std.mem.eql(u8, arg, "--list-channels")) {
            list_channels = true;
        } else if (std.mem.eql(u8, arg, "--demo")) {
            if (demo_enabled) return error.InvalidArguments;
            demo_enabled = true;
        } else if (std.mem.eql(u8, arg, "--log")) {
            if (log_path != null) return error.InvalidArguments;
            expecting_log_path = true;
        } else if (std.mem.startsWith(u8, arg, "--log=")) {
            if (log_path != null or arg["--log=".len..].len == 0) return error.InvalidArguments;
            log_path = arg["--log=".len..];
        } else if (std.mem.eql(u8, arg, "--replay")) {
            if (replay_path != null) return error.InvalidArguments;
            expecting_replay_path = true;
        } else if (std.mem.eql(u8, arg, "--speed")) {
            if (speed_supplied) return error.InvalidArguments;
            speed_supplied = true;
            expecting_speed = true;
        } else if (std.mem.startsWith(u8, arg, "--speed=")) {
            if (speed_supplied) return error.InvalidArguments;
            replay_speed_milli = parseReplaySpeed(arg["--speed=".len..]) orelse return error.InvalidArguments;
            speed_supplied = true;
        } else if (std.mem.startsWith(u8, arg, "--replay=")) {
            if (replay_path != null or arg["--replay=".len..].len == 0) return error.InvalidArguments;
            replay_path = arg["--replay=".len..];
        } else if (path == null and !std.mem.startsWith(u8, arg, "-")) {
            path = arg;
        } else {
            std.debug.print("{s}", .{usage});
            return error.InvalidArguments;
        }
    }
    if (expecting_log_path) return error.InvalidArguments;
    if (expecting_replay_path) return error.InvalidArguments;
    if (expecting_speed) return error.InvalidArguments;

    if (list_channels) {
        if (path != null or log_path != null or replay_path != null or demo_enabled) return error.InvalidArguments;
        try writeChannelList(gpa, out);
        return;
    }

    if (replay_path == null and path == null) {
        std.debug.print("{s}", .{usage});
        return error.InvalidArguments;
    }
    if (replay_path != null and log_path != null) return error.InvalidArguments;
    if (demo_enabled and (replay_path != null or path == null)) return error.InvalidArguments;
    if (speed_supplied and replay_path == null) return error.InvalidArguments;

    var replay_header: ?log_format.Header = null;
    if (replay_path) |replay_file| replay_header = try readReplayHeader(io, replay_file);
    var db_format: database.Format = .can_json;
    var source: []u8 = undefined;
    if (path) |db_path| {
        db_format = database.detectFormat(db_path) orelse {
            std.debug.print("{s}: unknown database format (expected .dbc or .can.json)\n", .{db_path});
            return error.UnknownFormat;
        };
        source = std.Io.Dir.cwd().readFileAlloc(io, db_path, gpa, .limited(database.max_file_size)) catch |err| {
            std.debug.print("{s}: cannot read file: {s}\n", .{ db_path, @errorName(err) });
            return err;
        };
    } else {
        source = try makeRawReplayDatabase(gpa, replay_header.?);
    }
    defer gpa.free(source);

    var diags: database.Diagnostics = .empty;
    defer diags.deinit(gpa);

    var db = database.Database.init(gpa, db_format, source, &diags) catch |err| {
        try out.print("{s}: failed to load database: {s}\n", .{ path orelse "<raw replay>", @errorName(err) });
        try database.writeDiagnostics(out, diags.items);
        return err;
    };
    defer db.deinit();

    try database.writeDiagnostics(out, diags.items);
    try out.flush();

    const home = init.environ_map.get("HOME") orelse init.environ_map.get("USERPROFILE") orelse "/";
    const config_dir = try config.configDirectory(gpa, init.environ_map.get("XDG_CONFIG_HOME"), home);
    defer gpa.free(config_dir);
    const settings = config.loadSettings(gpa, io, config_dir) catch config.Settings{};

    const engine = try Engine.create(gpa, io);
    defer engine.deinit();

    var replay_source: ?*ReplaySource = null;
    defer if (replay_source) |replay| replay.stopAndDeinit();
    var demo_source: ?*DemoSource = null;
    defer if (demo_source) |demo| demo.stopAndDeinit();
    if (replay_path) |replay_file| {
        const replay_queue = try engine.attachReplayQueue();
        replay_source = try ReplaySource.create(gpa, io, replay_file, &db, replay_queue, &engine.tx_events);
        replay_source.?.attachIngestor(&engine.ingestor);
        replay_source.?.setSpeed(replay_speed_milli);
        try engine.start();
        try replay_source.?.start();
    } else if (demo_enabled) {
        const demo_queue = try engine.attachReplayQueue();
        demo_source = try DemoSource.create(gpa, io, &db, demo_queue);
        try engine.start();
        try demo_source.?.start();
    }

    var program = zz.Program(app_ui.App).initWithModel(gpa, io, init.environ_map, .{
        .database = &db,
        .engine = engine,
        .allocator = gpa,
        .io = io,
        .config_directory = config_dir,
        .database_file = if (path) |db_path| std.fs.path.basename(db_path) else "raw-replay",
        .database_hash = config.databaseHash(source),
        .settings = settings,
        .log_path = log_path,
        .replay_source = replay_source,
        .demo_source = demo_source,
    }, .{
        .fps = settings.fps,
        .title = "can_dbz_vis",
        .mouse = true,
    });
    program.model.program_options = &program.options;
    defer program.deinit();
    try program.run();
}
