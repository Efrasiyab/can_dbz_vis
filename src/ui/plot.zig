const std = @import("std");
const zz = @import("zigzag");
const codec = @import("can_dbz").codec;
const Database = @import("../db/database.zig").Database;
const engine_plot = @import("../engine/plot.zig");
const ui_config = @import("config.zig");

const series_colors = [_]zz.Color{ .cyan, .yellow, .green, .magenta, .blue, .red, .white, zz.Color.gray(8) };

const PickerRow = union(enum) {
    bus: usize,
    message: usize,
    signal: struct { message: usize, signal: usize },
};

pub const PickerMode = enum { plot, pins };

pub const PickerSignal = struct { message: usize, signal: usize };

pub const InspectionCursor = struct {
    plot_index: usize,
    timestamp_ns: u64,
};

pub const State = struct {
    selected_message: usize = 0,
    selected_signal: usize = 0,
    selected_target: usize = 0,
    window_seconds: u32 = 10,
    scroll_seconds: u32 = 0,
    targets: [engine_plot.max_signals]?engine_plot.Target = @splat(null),
    target_count: usize = 0,
    plot_count: usize = 0,
    selected_plot: usize = 0,
    plot_windows_ns: [engine_plot.max_signals]u64 = @splat(engine_plot.default_window_ns),
    notice: []const u8 = "",
    running: bool = false,
    window_edit_active: bool = false,
    window_input: [32]u8 = @splat(0),
    window_input_len: usize = 0,
    inspect_enabled: bool = false,
    inspection: ?InspectionCursor = null,
    columns_override: ?u8 = null,
    layout_edit_active: bool = false,
    layout_input: [8]u8 = @splat(0),
    layout_input_len: usize = 0,
    picker_open: bool = false,
    assignment_signal: ?PickerSignal = null,
    assignment_plot: usize = 0,
    picker_cursor: usize = 0,
    picker_expanded_buses: [256]bool = @splat(false),
    picker_expanded_messages: []bool = &.{},

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.picker_expanded_messages.len != 0) allocator.free(self.picker_expanded_messages);
        self.picker_expanded_messages = &.{};
    }

    pub fn openPicker(self: *State, allocator: std.mem.Allocator, database: *const Database) std.mem.Allocator.Error!void {
        if (self.picker_expanded_messages.len != database.compiled.messages.len) {
            const expanded = try allocator.alloc(bool, database.compiled.messages.len);
            @memset(expanded, false);
            @memcpy(expanded[0..@min(expanded.len, self.picker_expanded_messages.len)], self.picker_expanded_messages[0..@min(expanded.len, self.picker_expanded_messages.len)]);
            if (self.picker_expanded_messages.len != 0) allocator.free(self.picker_expanded_messages);
            self.picker_expanded_messages = expanded;
        }
        self.picker_open = true;
        self.picker_cursor = @min(self.picker_cursor, pickerRowCount(self, database) -| 1);
    }

    pub fn movePicker(self: *State, database: *const Database, delta: isize) void {
        const count = pickerRowCount(self, database);
        if (count == 0) {
            self.picker_cursor = 0;
            return;
        }
        const next = @as(i128, @intCast(self.picker_cursor)) + delta;
        self.picker_cursor = @intCast(@min(@max(next, 0), @as(i128, @intCast(count - 1))));
    }

    pub fn expandPickerRow(self: *State, database: *const Database) void {
        const row = pickerRowAt(self, database, self.picker_cursor) orelse return;
        switch (row) {
            .bus => |bus_index| self.picker_expanded_buses[bus_index] = !self.picker_expanded_buses[bus_index],
            .message => |message_index| self.picker_expanded_messages[message_index] = !self.picker_expanded_messages[message_index],
            .signal => {},
        }
        self.picker_cursor = @min(self.picker_cursor, pickerRowCount(self, database) -| 1);
    }

    pub fn collapsePickerRow(self: *State, database: *const Database) void {
        const row = pickerRowAt(self, database, self.picker_cursor) orelse return;
        switch (row) {
            .bus => |bus_index| self.picker_expanded_buses[bus_index] = false,
            .message => |message_index| {
                if (self.picker_expanded_messages[message_index]) {
                    self.picker_expanded_messages[message_index] = false;
                } else if (findBusIndex(database, database.compiled.messages[message_index].bus)) |bus_index| {
                    self.picker_expanded_buses[bus_index] = false;
                    self.picker_cursor = pickerBusRowIndex(self, database, bus_index) orelse self.picker_cursor;
                }
            },
            .signal => |selection| {
                self.picker_cursor = pickerMessageRowIndex(self, database, selection.message) orelse self.picker_cursor;
                self.picker_expanded_messages[selection.message] = false;
            },
        }
    }

    pub fn togglePickerSignal(self: *State, database: *const Database, config: *engine_plot.Config) void {
        const selection = self.pickerSignal(database) orelse return;
        self.selected_message = selection.message;
        self.selected_signal = selection.signal;
        for (0..self.target_count) |index| {
            const target = self.targets[index].?;
            if (target.message_handle != selection.message or target.signal_index != selection.signal) continue;
            self.selected_target = index;
            self.removeSelected(config);
            return;
        }
        self.assignment_signal = selection;
        self.assignment_plot = self.plot_count;
    }

    pub fn moveAssignment(self: *State, delta: isize) void {
        const maximum = @min(self.plot_count, engine_plot.max_signals - 1);
        const next = @as(i128, @intCast(self.assignment_plot)) + delta;
        self.assignment_plot = @intCast(@min(@max(next, 0), @as(i128, @intCast(maximum))));
    }

    pub fn selectPlot(self: *State, delta: isize) void {
        if (self.plot_count == 0) return;
        const next = @as(i128, @intCast(self.selected_plot)) + delta;
        self.selected_plot = @intCast(@min(@max(next, 0), @as(i128, @intCast(self.plot_count - 1))));
    }

    pub fn beginWindowEdit(self: *State) void {
        if (self.plot_count == 0) return;
        self.window_edit_active = true;
        self.window_input = @splat(0);
        self.window_input_len = 0;
    }

    pub fn toggleInspect(self: *State) void {
        self.inspect_enabled = !self.inspect_enabled;
        if (!self.inspect_enabled) self.inspection = null;
    }

    pub fn captureClick(self: *State, x: u16, y: u16, width: u16, grid_height: u16, snapshot: *const engine_plot.Snapshot) bool {
        if (!self.inspect_enabled or self.plot_count == 0) return false;
        const layout = gridLayoutWithColumns(self.plot_count, width, grid_height, self.columns_override);
        const column_step = layout.cell_width + 2;
        const column = @as(usize, x) / column_step;
        const row = @as(usize, y) / layout.cell_height;
        if (column >= layout.columns or row >= layout.rows or @as(usize, x) % column_step >= layout.cell_width) return false;
        const plot_index = row * layout.columns + column;
        if (plot_index >= self.plot_count) return false;
        const cell_x = column * column_step;
        const cell_y = row * layout.cell_height;
        const plot_series = countPlotSeries(self, plot_index);
        const local_y = @as(usize, y) -| cell_y;
        if (local_y < 1 + plot_series) return false;

        const plot_left = @min(@as(usize, 6), layout.cell_width -| 2);
        const plot_width = @max(layout.cell_width -| plot_left, 2);
        const local_x = @as(usize, x) -| cell_x;
        const x_offset = @min(local_x -| plot_left, plot_width - 1);
        const fraction = @as(f64, @floatFromInt(x_offset)) / @as(f64, @floatFromInt(plot_width - 1));
        const window_ns = self.plot_windows_ns[plot_index];
        const window_start_ns = snapshot.window_end_ns -| window_ns;
        const timestamp_offset: u64 = @intFromFloat(@as(f64, @floatFromInt(window_ns)) * fraction);
        self.inspection = .{ .plot_index = plot_index, .timestamp_ns = window_start_ns +| timestamp_offset };
        return true;
    }

    pub fn appendWindowCharacter(self: *State, character: u8) void {
        if (self.window_input_len == self.window_input.len) return;
        if (character == '.') {
            if (std.mem.indexOfScalar(u8, self.window_input[0..self.window_input_len], '.')) |index| {
                _ = index;
                return;
            }
        } else if (!std.ascii.isDigit(character)) {
            return;
        }
        self.window_input[self.window_input_len] = character;
        self.window_input_len += 1;
    }

    pub fn backspaceWindowInput(self: *State) void {
        if (self.window_input_len == 0) return;
        self.window_input_len -= 1;
        self.window_input[self.window_input_len] = 0;
    }

    pub fn beginLayoutEdit(self: *State) void {
        self.layout_edit_active = true;
        self.layout_input = @splat(0);
        self.layout_input_len = 0;
        if (self.columns_override) |columns| {
            const text = std.fmt.bufPrint(&self.layout_input, "{d}", .{columns}) catch return;
            self.layout_input_len = text.len;
        }
    }

    pub fn appendLayoutCharacter(self: *State, character: u8) void {
        if (self.layout_input_len == self.layout_input.len or !std.ascii.isDigit(character)) return;
        self.layout_input[self.layout_input_len] = character;
        self.layout_input_len += 1;
    }

    pub fn backspaceLayoutInput(self: *State) void {
        if (self.layout_input_len == 0) return;
        self.layout_input_len -= 1;
        self.layout_input[self.layout_input_len] = 0;
    }

    pub fn commitLayoutEdit(self: *State, plot_count: usize) bool {
        const columns = std.fmt.parseInt(u8, self.layout_input[0..self.layout_input_len], 10) catch return false;
        if (columns > engine_plot.max_signals or columns > plot_count) return false;
        self.columns_override = if (columns == 0) null else columns;
        self.layout_edit_active = false;
        self.layout_input = @splat(0);
        self.layout_input_len = 0;
        return true;
    }

    pub fn commitWindowEdit(self: *State, config: *engine_plot.Config) bool {
        const milliseconds = std.fmt.parseFloat(f64, self.window_input[0..self.window_input_len]) catch return false;
        if (!std.math.isFinite(milliseconds) or milliseconds <= 0 or milliseconds > 600_000) return false;
        const nanoseconds_float = milliseconds * std.time.ns_per_ms;
        if (nanoseconds_float < engine_plot.min_plot_window_ns or nanoseconds_float > engine_plot.max_plot_window_ns) return false;
        const nanoseconds: u64 = @intFromFloat(nanoseconds_float);
        self.plot_windows_ns[self.selected_plot] = nanoseconds;
        config.setPlotWindow(self.selected_plot, nanoseconds);
        self.window_edit_active = false;
        self.window_input = @splat(0);
        self.window_input_len = 0;
        self.notice = "Plot window updated";
        return true;
    }

    pub fn confirmAssignment(self: *State, database: *const Database, config: *engine_plot.Config) void {
        if (self.assignment_signal == null) return;
        self.selected_message = self.assignment_signal.?.message;
        self.selected_signal = self.assignment_signal.?.signal;
        self.addSelectedToPlot(database, config, self.assignment_plot);
        self.assignment_signal = null;
    }

    pub fn pickerSignal(self: *const State, database: *const Database) ?PickerSignal {
        const row = pickerRowAt(self, database, self.picker_cursor) orelse return null;
        return switch (row) {
            .signal => |selection| .{ .message = selection.message, .signal = selection.signal },
            else => null,
        };
    }

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
        self.addSelectedToPlot(database, config, 0);
    }

    pub fn addSelectedToPlot(self: *State, database: *const Database, config: *engine_plot.Config, plot_index: usize) void {
        if (database.compiled.messages.len == 0) return;
        if (plot_index >= engine_plot.max_signals) return;
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
            .plot_index = @intCast(plot_index),
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
        self.plot_count = @max(self.plot_count, plot_index + 1);
        self.plot_windows_ns[plot_index] = @max(self.plot_windows_ns[plot_index], engine_plot.min_plot_window_ns);
        config.setPlotWindow(plot_index, self.plot_windows_ns[plot_index]);
        self.selected_plot = plot_index;
        self.selected_target = self.target_count - 1;
        self.publishConfig(config);
        self.notice = "Signal added to plot";
    }

    pub fn removeSelected(self: *State, config: *engine_plot.Config) void {
        if (self.target_count == 0) return;
        if (self.selected_target >= self.target_count) self.selected_target = self.target_count - 1;
        const removed_plot = self.targets[self.selected_target].?.plot_index;
        for (self.selected_target..self.target_count - 1) |index| self.targets[index] = self.targets[index + 1];
        self.target_count -= 1;
        self.targets[self.target_count] = null;
        if (self.selected_target >= self.target_count and self.target_count > 0) self.selected_target = self.target_count - 1;
        var plot_still_used = false;
        for (self.targets[0..self.target_count]) |target| {
            if (target.?.plot_index == removed_plot) plot_still_used = true;
        }
        if (!plot_still_used) {
            for (self.targets[0..self.target_count]) |*target| {
                if (target.*.?.plot_index > removed_plot) target.*.?.plot_index -= 1;
            }
            for (removed_plot..self.plot_count - 1) |plot_index| {
                self.plot_windows_ns[plot_index] = self.plot_windows_ns[plot_index + 1];
            }
            self.plot_count -|= 1;
            self.plot_windows_ns[self.plot_count] = engine_plot.default_window_ns;
            if (self.plot_count != 0 and self.selected_plot >= self.plot_count) self.selected_plot = self.plot_count - 1;
        }
        self.publishConfig(config);
        self.notice = "Signal removed from plot";
    }

    pub fn adjustWindow(self: *State, config: *engine_plot.Config, delta_seconds: i32) void {
        if (self.plot_count == 0) return;
        const current_seconds = @as(i32, @intCast(self.plot_windows_ns[self.selected_plot] / std.time.ns_per_s));
        const next = current_seconds + delta_seconds;
        const seconds = @min(@max(next, 1), 600);
        self.plot_windows_ns[self.selected_plot] = @as(u64, @intCast(seconds)) * std.time.ns_per_s;
        config.setPlotWindow(self.selected_plot, self.plot_windows_ns[self.selected_plot]);
        self.window_seconds = @intCast(seconds);
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
        for (0..self.plot_count) |plot_index| config.setPlotWindow(plot_index, self.plot_windows_ns[plot_index]);
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
    if (state.layout_edit_active) {
        try writer.print("Layout columns (0=Auto): {s}_  Enter apply  Esc cancel\n", .{state.layout_input[0..state.layout_input_len]});
    } else if (state.window_edit_active) {
        try writer.print("Plot {d} window (ms): {s}_  Enter apply  Esc cancel\n", .{
            state.selected_plot + 1,
            state.window_input[0..state.window_input_len],
        });
    } else {
        var layout_buffer: [16]u8 = undefined;
        const layout_label = if (state.columns_override) |columns|
            std.fmt.bufPrint(&layout_buffer, "{d} cols", .{columns}) catch unreachable
        else
            "Auto";
        try writer.print("Plot {s}  {d} plots  {d}/{d} signals  layout {s}  active P{d}: {d:.3}ms  inspect {s}  i toggle/click\n", .{
            if (state.running) "RUNNING" else "STOPPED",
            state.plot_count,
            state.target_count,
            engine_plot.max_signals,
            layout_label,
            state.selected_plot + 1,
            @as(f64, @floatFromInt(state.plot_windows_ns[state.selected_plot])) / std.time.ns_per_ms,
            if (state.inspect_enabled) "on" else "off",
        });
    }
    if (database.compiled.messages.len != 0) {
        const message = database.compiled.messages[state.selected_message];
        try writer.print("Select: {s} 0x{X:0>3}  ", .{ message.name, message.id });
        if (state.selected_signal < message.signals.len) try writer.print("{s}\n", .{message.signals[state.selected_signal].name}) else try writer.writeAll("no signals\n");
    }
    if (state.notice.len != 0) try writer.print("{s}\n", .{state.notice});
    if (state.plot_count == 0) {
        try writer.writeAll("No plots assigned. Press p to select signals.\n");
        return;
    }

    const available_height = gridHeight(height, database, state, snapshot);
    const layout = gridLayoutWithColumns(state.plot_count, width, available_height, state.columns_override);
    var cells: [engine_plot.max_signals][]u8 = undefined;
    for (0..state.plot_count) |plot_index| {
        cells[plot_index] = try renderChartCell(allocator, layout.cell_width, layout.cell_height, plot_index, state.plot_windows_ns[plot_index], database, snapshot);
    }
    defer for (0..state.plot_count) |plot_index| allocator.free(cells[plot_index]);

    var offsets: [engine_plot.max_signals]usize = @splat(0);
    for (0..layout.rows) |row_index| {
        for (0..layout.cell_height) |_| {
            for (0..layout.columns) |column_index| {
                const cell_index = row_index * layout.columns + column_index;
                if (cell_index < state.plot_count) {
                    const line = nextCellLine(cells[cell_index], &offsets[cell_index]);
                    try writer.writeAll(line);
                    for (visibleTextWidth(line)..layout.cell_width) |_| try writer.writeByte(' ');
                } else {
                    for (0..layout.cell_width) |_| try writer.writeByte(' ');
                }
                if (column_index + 1 < layout.columns) {
                    try writer.writeAll("  ");
                }
            }
            try writer.writeByte('\n');
        }
    }
    if (state.inspection) |cursor| {
        try renderInspection(allocator, writer, database, snapshot, cursor);
    }
    try writer.print("Dropped plot samples: {d}\n", .{snapshot.dropped});
}

pub fn headingRowCount(database: *const Database, state: *const State) u16 {
    return 1 + @as(u16, @intFromBool(database.compiled.messages.len != 0)) + @as(u16, @intFromBool(state.notice.len != 0));
}

pub fn inspectionRowCount(state: *const State, snapshot: *const engine_plot.Snapshot) usize {
    const cursor = state.inspection orelse return 0;
    var count: usize = 1;
    for (snapshot.series[0..snapshot.series_count]) |series| {
        if (series.target.plot_index == cursor.plot_index) count += 1;
    }
    return count;
}

pub fn gridHeight(height: u16, database: *const Database, state: *const State, snapshot: *const engine_plot.Snapshot) u16 {
    return @intCast(@max(@as(usize, height) -| headingRowCount(database, state) -| inspectionRowCount(state, snapshot) -| 1, 1));
}

fn countPlotSeries(state: *const State, plot_index: usize) usize {
    var count: usize = 0;
    for (state.targets[0..state.target_count]) |target| {
        if (target.?.plot_index == plot_index) count += 1;
    }
    return count;
}

fn renderInspection(allocator: std.mem.Allocator, writer: *std.Io.Writer, database: *const Database, snapshot: *const engine_plot.Snapshot, cursor: InspectionCursor) !void {
    try writer.print("At {d:.6}s  Plot {d}\n", .{ @as(f64, @floatFromInt(cursor.timestamp_ns)) / std.time.ns_per_s, cursor.plot_index + 1 });
    for (snapshot.series[0..snapshot.series_count], 0..) |series, index| {
        if (series.target.plot_index != cursor.plot_index) continue;
        const target = series.target;
        const message = database.compiled.messages[target.message_handle];
        const signal = message.signals[target.signal_index];
        const point = nearestPoint(series, cursor.timestamp_ns) orelse {
            try writer.print("{s}.{s}.{s}: no sample\n", .{ message.bus, message.name, signal.name });
            continue;
        };
        const unit = database.doc.messages.items[target.message_handle].signals.items[target.signal_index].unit orelse "";
        const raw = database.compiled.encodeSignalPhysical(target.message_handle, target.signal_index, point.y, codec.RoundingPolicy.nearest_ties_even) catch null;
        const choice = if (raw) |raw_value|
            try database.compiled.choiceLabel(target.message_handle, target.signal_index, raw_value)
        else
            null;
        const line = if (choice) |label|
            try std.fmt.allocPrint(allocator, "{s}.{s}.{s}: {d:.4} {s} ({s})", .{ message.bus, message.name, signal.name, point.y, unit, label })
        else
            try std.fmt.allocPrint(allocator, "{s}.{s}.{s}: {d:.4} {s}", .{ message.bus, message.name, signal.name, point.y, unit });
        defer allocator.free(line);
        try writePickerStyled(allocator, writer, line, (zz.Style{}).fg(series_colors[index % series_colors.len]).inline_style(true));
        try writer.writeByte('\n');
    }
}

fn nearestPoint(series: engine_plot.Series, timestamp_ns: u64) ?engine_plot.Point {
    if (series.point_count == 0) return null;
    var nearest = series.points[0];
    var nearest_delta = if (nearest.timestamp_ns > timestamp_ns) nearest.timestamp_ns - timestamp_ns else timestamp_ns - nearest.timestamp_ns;
    for (series.points[1..series.point_count]) |point| {
        const delta = if (point.timestamp_ns > timestamp_ns) point.timestamp_ns - timestamp_ns else timestamp_ns - point.timestamp_ns;
        if (delta < nearest_delta) {
            nearest = point;
            nearest_delta = delta;
        }
    }
    return nearest;
}

pub const GridLayout = struct {
    columns: usize,
    rows: usize,
    cell_width: usize,
    cell_height: usize,
};

pub fn gridLayout(plot_count: usize, width: u16, height: u16) GridLayout {
    return gridLayoutWithColumns(plot_count, width, height, null);
}

pub fn gridLayoutWithColumns(plot_count: usize, width: u16, height: u16, columns_override: ?u8) GridLayout {
    const count = @max(plot_count, 1);
    if (columns_override) |requested| {
        const columns = @min(@as(usize, requested), count);
        const rows = (count + columns - 1) / columns;
        const horizontal_gaps = (columns - 1) * 2;
        const cell_width = (@as(usize, width) -| horizontal_gaps) / columns;
        return .{ .columns = columns, .rows = rows, .cell_width = cell_width, .cell_height = @max(@as(usize, height) / rows, 1) };
    }
    if (@as(usize, width) >= @as(usize, height) * 3 and @as(usize, height) / count >= 12) {
        return .{ .columns = 1, .rows = count, .cell_width = width, .cell_height = @as(usize, height) / count };
    }
    var best = GridLayout{ .columns = 1, .rows = count, .cell_width = width, .cell_height = @max(@as(usize, height) / count, 1) };
    var best_area: usize = 0;
    const max_columns = @min(count, @as(usize, @max(width / 2, 1)));
    for (1..max_columns + 1) |columns| {
        const rows = (count + columns - 1) / columns;
        const horizontal_gaps = (columns - 1) * 2;
        if (@as(usize, width) <= horizontal_gaps) continue;
        const cell_width = (@as(usize, width) - horizontal_gaps) / columns;
        const cell_height = @max(@as(usize, height) / rows, 1);
        if (cell_width < 38 or cell_height < 4) continue;
        const chart_width = cell_width -| 12;
        const chart_height = cell_height -| 5;
        const area = chart_width * chart_height;
        if (area > best_area) {
            best_area = area;
            best = .{ .columns = columns, .rows = rows, .cell_width = cell_width, .cell_height = cell_height };
        }
    }
    return best;
}

fn renderChartCell(allocator: std.mem.Allocator, width: usize, height: usize, plot_index: usize, window_ns: u64, database: *const Database, snapshot: *const engine_plot.Snapshot) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.print("Plot {d}  {d:.3} ms\n", .{ plot_index + 1, @as(f64, @floatFromInt(window_ns)) / std.time.ns_per_ms });

    var plot_series: usize = 0;
    for (snapshot.series[0..snapshot.series_count]) |series| {
        if (series.target.plot_index == plot_index) plot_series += 1;
    }
    if (plot_series == 0) {
        try output.writer.writeAll("No signals assigned\n");
        return try allocator.dupe(u8, output.written());
    }

    for (snapshot.series[0..snapshot.series_count], 0..) |series, index| {
        if (series.target.plot_index != plot_index) continue;
        const target = series.target;
        const message = database.compiled.messages[target.message_handle];
        const signal = message.signals[target.signal_index];
        const label = try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ message.bus, message.name, signal.name });
        defer allocator.free(label);
        try writePickerText(allocator, &output.writer, label, @intCast(width), (zz.Style{}).fg(series_colors[index % series_colors.len]).inline_style(true));
        try output.writer.writeByte('\n');
    }

    var chart = zz.Chart.init(allocator);
    defer chart.deinit();
    chart.setSize(@intCast(@max(width -| 2, 20)), @intCast(@max(height -| plot_series -| 1, 1)));
    chart.setMarker(.braille);
    chart.x_axis = .{ .title = "Time (s)", .tick_count = 4, .show_grid = true };
    chart.y_axis = .{ .title = "Physical", .tick_count = 4, .show_grid = true };
    chart.legend_position = .hidden;

    for (snapshot.series[0..snapshot.series_count], 0..) |series, index| {
        if (series.target.plot_index != plot_index) continue;
        const target = series.target;
        const message = database.compiled.messages[target.message_handle];
        const signal = message.signals[target.signal_index];
        const label = try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ message.bus, message.name, signal.name });
        defer allocator.free(label);
        var dataset = try zz.ChartDataset.init(allocator, label);
        dataset.setStyle((zz.Style{}).fg(series_colors[index % series_colors.len]));
        var points: [engine_plot.max_decimated_points]zz.components.charting.Point = undefined;
        for (series.points[0..series.point_count], 0..) |point, point_index| {
            points[point_index] = .{ .x = point.x, .y = point.y };
        }
        try dataset.setPoints(points[0..series.point_count]);
        try chart.addDataset(dataset);
    }
    const graph = try chart.view(allocator);
    defer allocator.free(graph);
    try output.writer.writeAll(graph);
    return try allocator.dupe(u8, output.written());
}

fn nextCellLine(text: []const u8, offset: *usize) []const u8 {
    if (offset.* >= text.len) return "";
    const remainder = text[offset.*..];
    const length = std.mem.indexOfScalar(u8, remainder, '\n') orelse remainder.len;
    const line = remainder[0..length];
    offset.* += length + @intFromBool(length < remainder.len);
    return line;
}

fn visibleTextWidth(text: []const u8) usize {
    var width: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == 0x1b and index + 1 < text.len and text[index + 1] == '[') {
            index += 2;
            while (index < text.len and !(text[index] >= 0x40 and text[index] <= 0x7e)) : (index += 1) {}
            if (index < text.len) index += 1;
            continue;
        }
        if (text[index] & 0xc0 != 0x80) width += 1;
        index += 1;
    }
    return width;
}

pub fn renderPicker(allocator: std.mem.Allocator, writer: *std.Io.Writer, width: u16, height: u16, database: *const Database, state: *const State, mode: PickerMode, pins: ?*const ui_config.PinSet) !void {
    if (mode == .plot and state.assignment_signal != null) {
        const selection = state.assignment_signal.?;
        const message = database.compiled.messages[selection.message];
        const signal = message.signals[selection.signal];
        try writer.print("Assign {s}.{s}.{s} to Plot {d}{s}  Left/Right choose  Enter assign  Esc cancel\n", .{
            message.bus,
            message.name,
            signal.name,
            state.assignment_plot + 1,
            if (state.assignment_plot == state.plot_count) " (new)" else "",
        });
    } else if (mode == .plot) {
        try writer.print("Select plot signals  {d}/{d} plotted  Up/Down move  Left/Right fold  Tab toggle  Enter close\n", .{ state.target_count, engine_plot.max_signals });
    } else {
        try writer.print("Select pins  {d}/{d} pinned  Up/Down move  Left/Right fold  Tab toggle  Enter close\n", .{ pins.?.len, ui_config.max_pins });
    }
    try writePickerText(allocator, writer, "BUS / MESSAGE / SIGNAL", width, (zz.Style{}).fg(zz.Color.brightYellow).bold(true).inline_style(true));
    try writer.writeByte('\n');

    const row_count = pickerRowCount(state, database);
    const cursor = @min(state.picker_cursor, row_count -| 1);
    const visible_rows = @max(@as(usize, height) -| 2, 1);
    const first_row = if (cursor + 1 > visible_rows) cursor + 1 - visible_rows else 0;
    const end_row = first_row + visible_rows;
    var row_index: usize = 0;
    for (database.doc.buses.items, 0..) |bus, bus_index| {
        var message_count: usize = 0;
        for (database.compiled.messages) |message| {
            if (std.mem.eql(u8, message.bus, bus.name)) message_count += 1;
        }
        var line: [512]u8 = undefined;
        const text = std.fmt.bufPrint(&line, "{s} {s} ({d} messages)", .{
            if (state.picker_expanded_buses[bus_index]) "v" else ">",
            bus.name,
            message_count,
        }) catch line[0..0];
        const bus_mark = pickerBusMark(state, database, pins, mode, bus_index, bus.name);
        try writePickerRow(allocator, writer, text, "", row_index, first_row, end_row, width, cursor, bus_mark, mode);
        row_index += 1;
        if (!state.picker_expanded_buses[bus_index]) continue;

        for (database.compiled.messages, 0..) |message, message_index| {
            if (!std.mem.eql(u8, message.bus, bus.name)) continue;
            const message_text = std.fmt.bufPrint(&line, "  {s} {s} 0x{X:0>3} ({d} signals)", .{
                if (state.picker_expanded_messages[message_index]) "v" else ">",
                message.name,
                message.id,
                message.signals.len,
            }) catch line[0..0];
            const message_mark = pickerMessageMark(state, pins, mode, message_index);
            try writePickerRow(allocator, writer, message_text, "", row_index, first_row, end_row, width, cursor, message_mark, mode);
            row_index += 1;
            if (!state.picker_expanded_messages[message_index]) continue;

            for (message.signals, 0..) |signal, signal_index| {
                const plotted_index = pickerSignalMark(state, pins, mode, message_index, signal_index);
                var status_buffer: [32]u8 = undefined;
                const status = if (plotted_index) |item_index| blk: {
                    const item = if (mode == .plot)
                        std.fmt.bufPrint(&status_buffer, "[x] PLOT {d}", .{state.targets[item_index].?.plot_index + 1}) catch "[x]"
                    else
                        std.fmt.bufPrint(&status_buffer, "[x] PIN {d}", .{item_index + 1}) catch "[x]";
                    break :blk item;
                } else "[ ]";
                const signal_text = std.fmt.bufPrint(&line, "    {s} ({d} bit, {s})", .{
                    signal.name,
                    signal.bit_length,
                    @tagName(signal.signal_type),
                }) catch line[0..0];
                try writePickerRow(allocator, writer, signal_text, status, row_index, first_row, end_row, width, cursor, plotted_index, mode);
                row_index += 1;
            }
        }
    }
}

fn writePickerRow(allocator: std.mem.Allocator, writer: *std.Io.Writer, text: []const u8, status: []const u8, row_index: usize, first_row: usize, end_row: usize, width: u16, cursor: usize, mark_index: ?usize, mode: PickerMode) !void {
    if (row_index < first_row or row_index >= end_row) return;
    const selected = row_index == cursor;
    const color = pickerMarkColor(mode, mark_index);
    const label_style = if (selected)
        (zz.Style{}).fg(zz.Color.brightWhite).bg(zz.Color.color256(24)).bold(true).inline_style(true)
    else
        (zz.Style{}).fg(color).bold(mark_index != null).inline_style(true);
    const status_style = (zz.Style{}).fg(color).bg(if (selected) zz.Color.color256(24) else .none).bold(mark_index != null).inline_style(true);
    const status_width = @min(status.len, width);
    const text_width = @min(text.len, width - status_width);
    try writePickerStyled(allocator, writer, text[0..text_width], label_style);
    for (text_width..width - status_width) |_| try writer.writeByte(' ');
    try writePickerStyled(allocator, writer, status[0..status_width], status_style);
    for (text_width + status_width..width) |_| try writer.writeByte(' ');
    try writer.writeByte('\n');
}

fn writePickerStyled(allocator: std.mem.Allocator, writer: *std.Io.Writer, text: []const u8, style: zz.Style) !void {
    const rendered = try style.render(allocator, text);
    defer allocator.free(rendered);
    try writer.writeAll(rendered);
}

fn writePickerText(allocator: std.mem.Allocator, writer: *std.Io.Writer, text: []const u8, width: u16, style: zz.Style) !void {
    const visible = text[0..@min(text.len, width)];
    const rendered = try style.render(allocator, visible);
    defer allocator.free(rendered);
    try writer.writeAll(rendered);
    for (visible.len..width) |_| try writer.writeByte(' ');
}

fn pickerRowCount(state: *const State, database: *const Database) usize {
    var count: usize = 0;
    for (database.doc.buses.items, 0..) |bus, bus_index| {
        count += 1;
        if (bus_index >= state.picker_expanded_buses.len or !state.picker_expanded_buses[bus_index]) continue;
        for (database.compiled.messages, 0..) |message, message_index| {
            if (!std.mem.eql(u8, message.bus, bus.name)) continue;
            count += 1;
            if (message_index < state.picker_expanded_messages.len and state.picker_expanded_messages[message_index]) count += message.signals.len;
        }
    }
    return count;
}

fn pickerRowAt(state: *const State, database: *const Database, target_row: usize) ?PickerRow {
    var row: usize = 0;
    for (database.doc.buses.items, 0..) |bus, bus_index| {
        if (row == target_row) return .{ .bus = bus_index };
        row += 1;
        if (bus_index >= state.picker_expanded_buses.len or !state.picker_expanded_buses[bus_index]) continue;
        for (database.compiled.messages, 0..) |message, message_index| {
            if (!std.mem.eql(u8, message.bus, bus.name)) continue;
            if (row == target_row) return .{ .message = message_index };
            row += 1;
            if (message_index >= state.picker_expanded_messages.len or !state.picker_expanded_messages[message_index]) continue;
            for (message.signals, 0..) |_, signal_index| {
                if (row == target_row) return .{ .signal = .{ .message = message_index, .signal = signal_index } };
                row += 1;
            }
        }
    }
    return null;
}

fn pickerBusRowIndex(state: *const State, database: *const Database, target_bus: usize) ?usize {
    var row: usize = 0;
    for (database.doc.buses.items, 0..) |bus, bus_index| {
        if (bus_index == target_bus) return row;
        row += 1;
        if (bus_index >= state.picker_expanded_buses.len or !state.picker_expanded_buses[bus_index]) continue;
        for (database.compiled.messages, 0..) |message, message_index| {
            if (!std.mem.eql(u8, message.bus, bus.name)) continue;
            row += 1;
            if (message_index < state.picker_expanded_messages.len and state.picker_expanded_messages[message_index]) row += message.signals.len;
        }
    }
    return null;
}

fn pickerMessageRowIndex(state: *const State, database: *const Database, target_message: usize) ?usize {
    if (target_message >= database.compiled.messages.len) return null;
    const target = database.compiled.messages[target_message];
    const bus_index = findBusIndex(database, target.bus) orelse return null;
    var row = pickerBusRowIndex(state, database, bus_index) orelse return null;
    if (!state.picker_expanded_buses[bus_index]) return null;
    row += 1;
    for (database.compiled.messages, 0..) |message, message_index| {
        if (!std.mem.eql(u8, message.bus, target.bus)) continue;
        if (message_index == target_message) return row;
        row += 1;
        if (message_index < state.picker_expanded_messages.len and state.picker_expanded_messages[message_index]) row += message.signals.len;
    }
    return null;
}

fn plottedSignalIndex(state: *const State, message_index: usize, signal_index: usize) ?usize {
    for (state.targets[0..state.target_count], 0..) |target, index| {
        if (target.?.message_handle == message_index and target.?.signal_index == signal_index) return index;
    }
    return null;
}

fn plottedMessageIndex(state: *const State, message_index: usize) ?usize {
    for (state.targets[0..state.target_count], 0..) |target, index| {
        if (target.?.message_handle == message_index) return index;
    }
    return null;
}

fn plottedBusSignalIndex(state: *const State, bus_index: usize) ?usize {
    for (state.targets[0..state.target_count], 0..) |target, index| {
        if (@as(usize, target.?.bus_index) == bus_index) return index;
    }
    return null;
}

fn pickerMarkColor(mode: PickerMode, mark_index: ?usize) zz.Color {
    if (mode == .pins) return if (mark_index != null) zz.Color.brightYellow else zz.Color.gray(15);
    return if (mark_index) |index| series_colors[index % series_colors.len] else zz.Color.gray(15);
}

fn pickerSignalMark(state: *const State, pins: ?*const ui_config.PinSet, mode: PickerMode, message_index: usize, signal_index: usize) ?usize {
    return if (mode == .plot)
        plottedSignalIndex(state, message_index, signal_index)
    else
        pinSignalIndex(pins.?, message_index, signal_index);
}

fn pickerMessageMark(state: *const State, pins: ?*const ui_config.PinSet, mode: PickerMode, message_index: usize) ?usize {
    if (mode == .plot) return plottedMessageIndex(state, message_index);
    for (pins.?.items[0..pins.?.len], 0..) |maybe_pin, pin_index| {
        if (maybe_pin.?.message == message_index) return pin_index;
    }
    return null;
}

fn pickerBusMark(state: *const State, database: *const Database, pins: ?*const ui_config.PinSet, mode: PickerMode, bus_index: usize, bus_name: []const u8) ?usize {
    if (mode == .plot) return plottedBusSignalIndex(state, bus_index);
    for (pins.?.items[0..pins.?.len], 0..) |maybe_pin, pin_index| {
        const message_index = maybe_pin.?.message;
        if (message_index >= database.compiled.messages.len) continue;
        if (std.mem.eql(u8, database.compiled.messages[message_index].bus, bus_name)) return pin_index;
    }
    return null;
}

fn pinSignalIndex(pins: *const ui_config.PinSet, message_index: usize, signal_index: usize) ?usize {
    for (pins.items[0..pins.len], 0..) |maybe_pin, pin_index| {
        const pin = maybe_pin.?;
        if (pin.message == message_index and pin.signal == signal_index) return pin_index;
    }
    return null;
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
        \\ SG_ Temp : 16|8@1+ (1,-40) [-40|215] "degC" Vector__XXX
        \\
    ;
    var diagnostics: Diagnostics = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    var database = try Database.init(std.testing.allocator, .dbc, source, &diagnostics);
    defer database.deinit();
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    var config: engine_plot.Config = .{};
    try state.openPicker(std.testing.allocator, &database);
    try std.testing.expectEqual(@as(usize, 1), pickerRowCount(&state, &database));
    state.expandPickerRow(&database);
    try std.testing.expectEqual(@as(usize, 2), pickerRowCount(&state, &database));
    state.movePicker(&database, 1);
    state.expandPickerRow(&database);
    try std.testing.expectEqual(@as(usize, 4), pickerRowCount(&state, &database));
    state.movePicker(&database, 1);
    state.togglePickerSignal(&database, &config);
    try std.testing.expect(state.assignment_signal != null);
    var assignment_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer assignment_output.deinit();
    try renderPicker(std.testing.allocator, &assignment_output.writer, 100, 8, &database, &state, .plot, null);
    try std.testing.expect(std.mem.indexOf(u8, assignment_output.written(), "Assign can0.EngineData.RPM to Plot 1") != null);
    state.confirmAssignment(&database, &config);
    try std.testing.expectEqual(@as(usize, 1), state.target_count);
    try std.testing.expectEqual(@as(usize, 1), state.plot_count);
    try std.testing.expectEqual(@as(u8, 1), config.read().count);
    try std.testing.expectEqual(@as(?usize, 0), plottedMessageIndex(&state, 0));
    try std.testing.expectEqual(@as(?usize, 0), plottedBusSignalIndex(&state, 0));
    var picker_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer picker_output.deinit();
    try renderPicker(std.testing.allocator, &picker_output.writer, 80, 3, &database, &state, .plot, null);
    try std.testing.expect(std.mem.indexOf(u8, picker_output.written(), "RPM") != null);
    try std.testing.expect(std.mem.indexOf(u8, picker_output.written(), "PLOT 1") != null);
    state.movePicker(&database, 1);
    state.togglePickerSignal(&database, &config);
    state.confirmAssignment(&database, &config);
    try std.testing.expectEqual(@as(usize, 2), state.target_count);
    try std.testing.expectEqual(@as(usize, 2), state.plot_count);
    try std.testing.expectEqual(@as(u8, 1), state.targets[1].?.plot_index);
    var pin_set: ui_config.PinSet = .{};
    try pin_set.toggle(.{ .message = 0, .signal = 0 });
    state.movePicker(&database, -1);
    var pin_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer pin_output.deinit();
    try renderPicker(std.testing.allocator, &pin_output.writer, 80, 3, &database, &state, .pins, &pin_set);
    try std.testing.expect(std.mem.indexOf(u8, pin_output.written(), "PIN 1") != null);
    state.movePicker(&database, 1);
    state.togglePickerSignal(&database, &config);
    try std.testing.expectEqual(@as(usize, 1), state.target_count);
    state.movePicker(&database, -1);
    state.togglePickerSignal(&database, &config);
    try std.testing.expectEqual(@as(usize, 0), state.target_count);
    try std.testing.expectEqual(@as(usize, 0), state.plot_count);
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
        \\VAL_ 192 RPM 1 "Running" 2 "Error" ;
        \\
    ;
    var diagnostics: Diagnostics = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    var database = try Database.init(std.testing.allocator, .dbc, source, &diagnostics);
    defer database.deinit();
    var state: State = .{ .plot_count = 2 };
    defer state.deinit(std.testing.allocator);
    var snapshot: engine_plot.Snapshot = .{ .series_count = 1 };
    snapshot.series[0].target = .{ .bus_index = 0, .message_handle = 0, .signal_index = 0, .id = 192, .extended = false };
    snapshot.series[0].point_count = 2;
    snapshot.series[0].points[0] = .{ .timestamp_ns = 0, .x = 0, .y = 1200 };
    snapshot.series[0].points[1] = .{ .timestamp_ns = std.time.ns_per_s, .x = 1, .y = 2500 };
    snapshot.series_count = 2;
    snapshot.series[1].target = .{ .bus_index = 0, .message_handle = 0, .signal_index = 0, .id = 192, .extended = false, .plot_index = 1 };
    snapshot.series[1].point_count = 1;
    snapshot.series[1].points[0] = .{ .timestamp_ns = std.time.ns_per_s, .x = 1, .y = 10 };

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try render(std.testing.allocator, &output.writer, 240, 45, &database, &state, &snapshot);
    try std.testing.expect(output.written().len > 100);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "No plotted samples") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "Plot 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "Plot 2") != null);

    state.plot_count = 1;
    var stopped_snapshot: engine_plot.Snapshot = .{ .series_count = 1, .window_end_ns = std.time.ns_per_s };
    stopped_snapshot.series[0].target = .{ .bus_index = 0, .message_handle = 0, .signal_index = 0, .id = 192, .extended = false };
    stopped_snapshot.series[0].point_count = 1;
    stopped_snapshot.series[0].points[0] = .{ .timestamp_ns = 500 * std.time.ns_per_ms, .x = 0.5, .y = 0.25 };
    state.plot_windows_ns[0] = std.time.ns_per_s;
    state.targets[0] = stopped_snapshot.series[0].target;
    state.target_count = 1;
    state.inspect_enabled = true;
    const grid_height = gridHeight(30, &database, &state, &stopped_snapshot);
    try std.testing.expect(state.captureClick(63, 5, 120, grid_height, &stopped_snapshot));
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), @as(f64, @floatFromInt(state.inspection.?.timestamp_ns)) / std.time.ns_per_s, 0.01);
    try std.testing.expect(!state.captureClick(63, 0, 120, grid_height, &stopped_snapshot));
    try std.testing.expect(state.captureClick(119, 5, 120, grid_height, &stopped_snapshot));
    try std.testing.expectEqual(@as(u64, std.time.ns_per_s), state.inspection.?.timestamp_ns);
    var stopped_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stopped_output.deinit();
    try render(std.testing.allocator, &stopped_output.writer, 120, 30, &database, &state, &stopped_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, stopped_output.written(), "Plot 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, stopped_output.written(), "can0.EngineData.RPM") != null);
    try std.testing.expect(std.mem.indexOf(u8, stopped_output.written(), "Running") != null);
    try std.testing.expect(std.mem.indexOf(u8, stopped_output.written(), "No samples yet") == null);
}

test "plot grid chooses columns for tall narrow windows and rows for wide short windows" {
    const wide = gridLayout(2, 200, 30);
    try std.testing.expectEqual(@as(usize, 1), wide.columns);
    try std.testing.expectEqual(@as(usize, 2), wide.rows);
    const narrow = gridLayout(2, 80, 50);
    try std.testing.expectEqual(@as(usize, 1), narrow.columns);
    try std.testing.expectEqual(@as(usize, 2), narrow.rows);
    const crowded = gridLayout(4, 200, 30);
    try std.testing.expect(crowded.rows < 4);
    const custom = gridLayoutWithColumns(9, 240, 90, 3);
    try std.testing.expectEqual(@as(usize, 3), custom.columns);
    try std.testing.expectEqual(@as(usize, 3), custom.rows);
}

test "plot window editor stores fractional milliseconds independently per chart" {
    var state: State = .{ .plot_count = 2 };
    var config: engine_plot.Config = .{};
    state.beginWindowEdit();
    for ("0.1") |character| state.appendWindowCharacter(character);
    try std.testing.expect(state.commitWindowEdit(&config));
    try std.testing.expectEqual(@as(u64, 100 * std.time.ns_per_us), state.plot_windows_ns[0]);
    try std.testing.expectEqual(state.plot_windows_ns[0], config.read().plot_windows_ns[0]);

    state.selectPlot(1);
    state.beginWindowEdit();
    for ("1000") |character| state.appendWindowCharacter(character);
    try std.testing.expect(state.commitWindowEdit(&config));
    try std.testing.expectEqual(@as(u64, std.time.ns_per_s), state.plot_windows_ns[1]);
    try std.testing.expectEqual(state.plot_windows_ns[1], config.read().plot_windows_ns[1]);
    try std.testing.expectEqual(@as(u64, 100 * std.time.ns_per_us), config.read().plot_windows_ns[0]);
}

test "plot layout editor accepts a custom column count and restores Auto" {
    var state: State = .{ .plot_count = 9 };
    state.beginLayoutEdit();
    for ("3") |character| state.appendLayoutCharacter(character);
    try std.testing.expect(state.commitLayoutEdit(state.plot_count));
    try std.testing.expectEqual(@as(?u8, 3), state.columns_override);

    state.beginLayoutEdit();
    state.backspaceLayoutInput();
    state.appendLayoutCharacter('0');
    try std.testing.expect(state.commitLayoutEdit(state.plot_count));
    try std.testing.expectEqual(@as(?u8, null), state.columns_override);
}
