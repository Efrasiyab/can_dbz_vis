const std = @import("std");
const zz = @import("zigzag");
const Database = @import("../db/database.zig").Database;
const engine_plot = @import("../engine/plot.zig");

pub const State = struct {
    selected_message: usize = 0,
    selected_signal: usize = 0,
    selected_target: usize = 0,
    window_seconds: u32 = 10,
    scroll_seconds: u32 = 0,
    targets: [engine_plot.max_signals]?engine_plot.Target = @splat(null),
    target_count: usize = 0,
    notice: []const u8 = "",

    pub fn moveMessage(self: *State, database: *const Database, delta: isize) void {
        const count = database.compiled.messages.len;
        if (count == 0) return;
        var index: isize = @intCast(self.selected_message);
        if (delta < 0) {
            index = if (index == 0) @intCast(count - 1) else index - 1;
        } else {
            index = if (index + 1 >= count) 0 else index + 1;
        }
        self.selected_message = @intCast(index);
        self.selected_signal = 0;
    }

    pub fn moveSignal(self: *State, database: *const Database, delta: isize) void {
        if (database.compiled.messages.len == 0) return;
        const count = database.compiled.messages[self.selected_message].signals.len;
        if (count == 0) return;
        if (delta < 0) {
            self.selected_signal = if (self.selected_signal == 0) count - 1 else self.selected_signal - 1;
        } else {
            self.selected_signal = if (self.selected_signal + 1 >= count) 0 else self.selected_signal + 1;
        }
    }

    pub fn addSelected(self: *State, database: *const Database, config: *engine_plot.Config) void {
        if (database.compiled.messages.len == 0) return;
        const message = database.compiled.messages[self.selected_message];
        if (self.selected_signal >= message.signals.len) return;
        const bus_index = findBusIndex(database, message.bus) orelse {
            self.notice = "Signal bus is not configured";
            return;
        };
        const target = engine_plot.Target{
            .bus_index = bus_index,
            .message_handle = self.selected_message,
            .signal_index = self.selected_signal,
            .id = message.id,
            .extended = message.extended,
        };
        for (self.targets[0..self.target_count]) |existing| {
            if (std.meta.eql(existing.?, target)) {
                self.notice = "Signal is already plotted";
                return;
            }
        }
        if (self.target_count == engine_plot.max_signals) {
            self.notice = "Plot signal limit reached";
            return;
        }
        self.targets[self.target_count] = target;
        self.target_count += 1;
        self.selected_target = self.target_count - 1;
        self.publishConfig(config);
        self.notice = "Signal added to plot";
    }

    pub fn removeSelected(self: *State, config: *engine_plot.Config) void {
        if (self.target_count == 0) return;
        if (self.selected_target >= self.target_count) self.selected_target = self.target_count - 1;
        for (self.selected_target..self.target_count - 1) |index| self.targets[index] = self.targets[index + 1];
        self.target_count -= 1;
        self.targets[self.target_count] = null;
        if (self.selected_target >= self.target_count and self.target_count > 0) self.selected_target = self.target_count - 1;
        self.publishConfig(config);
        self.notice = "Signal removed from plot";
    }

    pub fn adjustWindow(self: *State, config: *engine_plot.Config, delta_seconds: i32) void {
        const next = @as(i32, @intCast(self.window_seconds)) + delta_seconds;
        self.window_seconds = @intCast(@min(@max(next, 1), 600));
        config.setWindow(@as(u64, self.window_seconds) * std.time.ns_per_s);
    }

    pub fn adjustScroll(self: *State, config: *engine_plot.Config, delta_seconds: i32) void {
        const next = @as(i32, @intCast(self.scroll_seconds)) + delta_seconds;
        self.scroll_seconds = @intCast(@min(@max(next, 0), 600));
        config.setScrollOffset(@as(u64, self.scroll_seconds) * std.time.ns_per_s);
    }

    pub fn publishConfig(self: *const State, config: *engine_plot.Config) void {
        var targets: [engine_plot.max_signals]engine_plot.Target = undefined;
        for (self.targets[0..self.target_count], 0..) |target, index| targets[index] = target.?;
        config.setTargets(targets[0..self.target_count]);
    }
};

pub fn render(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    width: u16,
    height: u16,
    database: *const Database,
    state: *const State,
    snapshot: *const engine_plot.Snapshot,
) !void {
    try writer.print("Plot signals {d}/{d}  window {d}s  scroll {d}s  p add  x remove  +/- window\n", .{
        state.target_count,
        engine_plot.max_signals,
        state.window_seconds,
        state.scroll_seconds,
    });
    if (database.compiled.messages.len != 0) {
        const message = database.compiled.messages[state.selected_message];
        try writer.print("Select: {s} 0x{X:0>3}  ", .{ message.name, message.id });
        if (state.selected_signal < message.signals.len) try writer.print("{s}\n", .{message.signals[state.selected_signal].name}) else try writer.writeAll("no signals\n");
    }
    if (state.notice.len != 0) try writer.print("{s}\n", .{state.notice});

    var chart = zz.Chart.init(allocator);
    defer chart.deinit();
    chart.setSize(@max(width -| 2, 20), @max(height -| 5, 8));
    chart.setMarker(.braille);
    chart.x_axis = .{ .title = "Time (s)", .tick_count = 5, .show_grid = true };
    chart.y_axis = .{ .title = "Physical", .tick_count = 5, .show_grid = true };
    chart.legend_position = if (snapshot.series_count > 1) .bottom else .hidden;

    const colors = [_]zz.Color{ .cyan, .yellow, .green, .magenta, .blue, .red, .white, zz.Color.gray(8) };
    for (snapshot.series[0..snapshot.series_count], 0..) |series, index| {
        if (series.point_count == 0) continue;
        const target = series.target;
        const message = database.compiled.messages[target.message_handle];
        const signal = message.signals[target.signal_index];
        const label = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ message.name, signal.name });
        defer allocator.free(label);
        var dataset = try zz.ChartDataset.init(allocator, label);
        dataset.setStyle((zz.Style{}).fg(colors[index % colors.len]));
        var points: [engine_plot.max_decimated_points]zz.components.charting.Point = undefined;
        for (series.points[0..series.point_count], 0..) |point, point_index| {
            points[point_index] = .{ .x = point.x, .y = point.y };
        }
        try dataset.setPoints(points[0..series.point_count]);
        try chart.addDataset(dataset);
    }

    if (snapshot.series_count == 0 or countSamples(snapshot) == 0) {
        try writer.writeAll("No plotted samples\n");
        return;
    }
    const graph = try chart.view(allocator);
    defer allocator.free(graph);
    try writer.writeAll(graph);
    try writer.print("\nDropped plot samples: {d}\n", .{snapshot.dropped});
}

fn findBusIndex(database: *const Database, bus_name: []const u8) ?u8 {
    for (database.doc.buses.items, 0..) |bus, index| {
        if (std.mem.eql(u8, bus.name, bus_name)) return @intCast(index);
    }
    return null;
}

fn countSamples(snapshot: *const engine_plot.Snapshot) usize {
    var count: usize = 0;
    for (snapshot.series[0..snapshot.series_count]) |series| count += series.point_count;
    return count;
}

test "plot picker adds and removes a selected database signal" {
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
    defer diagnostics.deinit(std.testing.allocator);
    var database = try Database.init(std.testing.allocator, .dbc, source, &diagnostics);
    defer database.deinit();
    var state: State = .{};
    var config: engine_plot.Config = .{};
    state.addSelected(&database, &config);
    try std.testing.expectEqual(@as(usize, 1), state.target_count);
    try std.testing.expectEqual(@as(u8, 1), config.read().count);
    state.removeSelected(&config);
    try std.testing.expectEqual(@as(usize, 0), state.target_count);
}

test "plot view renders a decimated series into chart output" {
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
    defer diagnostics.deinit(std.testing.allocator);
    var database = try Database.init(std.testing.allocator, .dbc, source, &diagnostics);
    defer database.deinit();
    var state: State = .{};
    var snapshot: engine_plot.Snapshot = .{ .series_count = 1 };
    snapshot.series[0].target = .{ .bus_index = 0, .message_handle = 0, .signal_index = 0, .id = 192, .extended = false };
    snapshot.series[0].point_count = 2;
    snapshot.series[0].points[0] = .{ .timestamp_ns = 0, .x = 0, .y = 1200 };
    snapshot.series[0].points[1] = .{ .timestamp_ns = std.time.ns_per_s, .x = 1, .y = 2500 };

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try render(std.testing.allocator, &output.writer, 80, 24, &database, &state, &snapshot);
    try std.testing.expect(output.written().len > 100);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "No plotted samples") == null);
}
