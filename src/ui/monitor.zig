const std = @import("std");
const zz = @import("zigzag");
const Database = @import("../db/database.zig").Database;
const Frame = @import("../can/frame.zig").Frame;
const store = @import("../engine/store.zig");
const config = @import("config.zig");

const Line = struct {
    bytes: [256]u8 = undefined,
    len: usize = 0,
    highlight: bool = false,
};

pub const State = struct {
    selected_row: usize = 0,
    collapsed_buses: [256]bool = @splat(false),
    selected_bus_header: ?u8 = null,
    folded_message_id: u32 = 0,
    folded_message_extended: bool = false,
    trace_mode: bool = false,
    database_only: bool = false,
    detail_focus: bool = false,
    selected_signal: usize = 0,
    filter_active: bool = false,
    filter: [64]u8 = @splat(0),
    filter_len: usize = 0,

    pub fn move(self: *State, amount: isize, snapshot: *const store.Snapshot, database: *const Database) void {
        if (self.detail_focus) {
            const frame = selectedFrame(self, snapshot, database) orelse return;
            const handle = database.compiled.findMessage(busName(database, frame.bus), frame.id, frame.flags.extended) orelse return;
            const signal_count = database.compiled.messages[handle].signals.len;
            if (signal_count == 0) return;
            const next_signal = @as(i128, @intCast(self.selected_signal)) + amount;
            self.selected_signal = @intCast(@min(@max(next_signal, 0), @as(i128, @intCast(signal_count - 1))));
            return;
        }
        const count = displayLineCount(self, snapshot, database);
        if (count == 0) {
            self.selected_row = 0;
            self.selected_bus_header = null;
            return;
        }
        const position: isize = @intCast(selectedDisplayLine(self, snapshot, database) orelse 0);
        const next = @as(i128, position) + amount;
        setSelectionAtDisplayLine(self, snapshot, database, @intCast(@min(@max(next, 0), @as(i128, @intCast(count - 1)))));
    }

    pub fn appendFilter(self: *State, character: u8) void {
        if (self.filter_len == self.filter.len) return;
        self.filter[self.filter_len] = character;
        self.filter_len += 1;
    }

    pub fn backspaceFilter(self: *State) void {
        if (self.filter_len == 0) return;
        self.filter_len -= 1;
        self.filter[self.filter_len] = 0;
    }

    pub fn clearFilter(self: *State) void {
        self.filter_len = 0;
        self.filter = @splat(0);
        self.selected_row = 0;
        self.selected_bus_header = null;
    }

    pub fn toggleSelectedBus(self: *State, snapshot: *const store.Snapshot, database: *const Database) void {
        if (self.selected_bus_header) |bus| {
            self.collapsed_buses[bus] = !self.collapsed_buses[bus];
            return;
        }
        const frame = selectedFrame(self, snapshot, database) orelse return;
        const bus = frame.bus;
        var preceding: usize = 0;
        for (0..bus) |bus_index| {
            if (self.collapsed_buses[bus_index]) continue;
            preceding += countVisibleOnBus(self, snapshot, database, @intCast(bus_index));
        }
        self.collapsed_buses[bus] = true;
        self.selected_bus_header = bus;
        self.folded_message_id = frame.id;
        self.folded_message_extended = frame.flags.extended;
        self.selected_row = preceding;
    }

    pub fn toggleDetailFocus(self: *State, snapshot: *const store.Snapshot, database: *const Database) void {
        if (self.detail_focus) {
            self.detail_focus = false;
            return;
        }
        const frame = selectedFrame(self, snapshot, database) orelse return;
        const handle = database.compiled.findMessage(busName(database, frame.bus), frame.id, frame.flags.extended) orelse return;
        if (database.compiled.messages[handle].signals.len == 0) return;
        self.detail_focus = true;
        self.selected_signal = 0;
    }
};

pub fn render(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    width: u16,
    height: u16,
    database: *const Database,
    snapshot: *const store.Snapshot,
    state: *const State,
    pins: *const config.PinSet,
) !void {
    const filter = state.filter[0..state.filter_len];
    const selected_source = selectedSourceIndex(state, snapshot, database);
    const selected_frame = if (selected_source) |index| sourceFrame(snapshot, state.trace_mode, index) else null;

    try writer.print("{s} | {d} frames | {d} drops | {s}\n", .{
        if (state.trace_mode) "TRACE" else "MONITOR",
        snapshot.frames_total,
        snapshot.dropped,
        if (state.filter_len == 0) "filter: none" else filter,
    });
    const total_width: usize = @max(32, width);
    const left_width = @max(16, total_width * 52 / 100);
    const right_width = total_width -| left_width -| 3;
    var left_header = Line{};
    setLine(&left_header, "Messages {s}", .{if (state.database_only) "[database only]" else "[all IDs]"});
    var right_header = Line{};
    setLine(&right_header, "Selected detail", .{});
    const header_style = (zz.Style{}).fg(zz.Color.brightCyan).bold(true).inline_style(true);
    try writePaddedStyled(writer, allocator, left_header.bytes[0..left_header.len], left_width, header_style);
    try writeStyled(writer, allocator, " | ", (zz.Style{}).fg(zz.Color.color256(60)).inline_style(true));
    try writePaddedStyled(writer, allocator, right_header.bytes[0..right_header.len], right_width, header_style);
    try writer.writeByte('\n');

    var left_columns = Line{};
    const data_bytes = (left_width -| 38) / 3;
    setLine(&left_columns, "  {s:<3} {s:<3} {s:<10} {s:<13} {s:>2} DATA ({d}B)", .{
        "TYPE", "FMT", "ID", "MESSAGE", "LEN", data_bytes,
    });
    var right_columns = Line{};
    setLine(&right_columns, "Message details / signal values", .{});
    const column_style = (zz.Style{}).fg(zz.Color.brightYellow).bold(true).inline_style(true);
    try writePaddedStyled(writer, allocator, left_columns.bytes[0..left_columns.len], left_width, column_style);
    try writeStyled(writer, allocator, " | ", (zz.Style{}).fg(zz.Color.color256(60)).inline_style(true));
    try writePaddedStyled(writer, allocator, right_columns.bytes[0..right_columns.len], right_width, column_style);
    try writer.writeByte('\n');

    const rows = @as(usize, height) -| 3;
    const total_display_lines = displayLineCount(state, snapshot, database);
    const selected_display_line = selectedDisplayLine(state, snapshot, database) orelse 0;
    const first_display_line = if (selected_display_line + 1 > rows) selected_display_line + 1 - rows else 0;
    var detail_capacity: usize = 9;
    if (selected_frame) |frame| {
        if (database.compiled.findMessage(busName(database, frame.bus), frame.id, frame.flags.extended)) |handle| {
            detail_capacity += database.compiled.messages[handle].signals.len;
        }
    }
    const detail_lines = try allocator.alloc(Line, detail_capacity);
    defer allocator.free(detail_lines);
    @memset(detail_lines, .{});
    const detail_count = if (selected_frame) |frame|
        buildDetailLines(detail_lines, frame, selectedSourceRow(snapshot, state, selected_source), database, state, pins)
    else blk: {
        setLine(&detail_lines[0], "No frames received", .{});
        break :blk 1;
    };
    const selected_signal_line = state.selected_signal + 9;
    const detail_first_line = if (state.detail_focus and selected_signal_line + 1 > rows)
        @min(selected_signal_line + 1 - rows, detail_count -| rows)
    else
        0;

    if (total_display_lines == 0) {
        var left = Line{};
        setLine(&left, "{s}", .{if (state.filter_len == 0) "No messages" else "No matches"});
        try writeColumns(allocator, writer, &left, if (detail_count > 0) &detail_lines[0] else null, left_width, right_width, false);
        return;
    }

    var display_line: usize = 0;
    var visible_message_index: usize = 0;
    for (0..256) |bus_index| {
        const bus = @as(u8, @intCast(bus_index));
        const group_count = countVisibleOnBus(state, snapshot, database, bus);
        if (group_count == 0) continue;

        if (display_line >= first_display_line and display_line < first_display_line + rows) {
            var left = Line{};
            setLine(&left, "{s} {s} ({d})", .{
                if (state.collapsed_buses[bus_index]) ">" else "v",
                busName(database, bus),
                group_count,
            });
            const selected_header = state.selected_bus_header != null and state.selected_bus_header.? == bus;
            const right_index = detail_first_line + display_line - first_display_line;
            try writeColumns(allocator, writer, &left, if (right_index < detail_count) &detail_lines[right_index] else null, left_width, right_width, selected_header);
        }
        display_line += 1;
        if (state.collapsed_buses[bus_index]) continue;

        const length = if (state.trace_mode) snapshot.trace_len else snapshot.row_count;
        for (0..length) |source_index| {
            const frame = sourceFrame(snapshot, state.trace_mode, source_index).?;
            if (frame.bus != bus or !isVisible(state, frame, database)) continue;
            if (display_line >= first_display_line and display_line < first_display_line + rows) {
                var left = Line{};
                const selected_message = state.selected_bus_header == null and visible_message_index == state.selected_row;
                formatMessageRow(&left, frame, database, selected_message, data_bytes);
                const right_index = detail_first_line + display_line - first_display_line;
                try writeColumns(allocator, writer, &left, if (right_index < detail_count) &detail_lines[right_index] else null, left_width, right_width, selected_message);
            }
            visible_message_index += 1;
            display_line += 1;
        }
    }
    const list_rows = @min(rows, total_display_lines -| first_display_line);
    for (list_rows..rows) |row_index| {
        const detail_index = detail_first_line + row_index;
        try writeColumns(allocator, writer, null, if (detail_index < detail_count) &detail_lines[detail_index] else null, left_width, right_width, false);
    }
}

pub fn renderPins(allocator: std.mem.Allocator, writer: *std.Io.Writer, width: u16, database: *const Database, snapshot: *const store.Snapshot, pins: *const config.PinSet, selected_pin: usize, first_pin: usize, visible_rows: usize, horizontal_scroll: usize) !void {
    if (pins.len == 0) return;
    var value_column_width: usize = 14;
    for (pins.items[0..pins.len]) |maybe_pin| {
        const pin = maybe_pin.?;
        if (pin.signal != null or pin.message >= database.compiled.messages.len) continue;
        const message = database.compiled.messages[pin.message];
        const latest = findLatestRow(snapshot, message.bus, message.id, message.extended, database);
        const payload_length = if (latest) |row| row.frame.len else message.length;
        value_column_width = @max(value_column_width, @as(usize, payload_length) * 3);
    }
    const value_width = @as(usize, width) -| 62;
    try writeStyled(writer, allocator, "   ", (zz.Style{}).fg(zz.Color.brightYellow).bold(true).inline_style(true));
    try writePaddedStyled(writer, allocator, "BUS", 20, (zz.Style{}).fg(zz.Color.brightYellow).bold(true).inline_style(true));
    try writer.writeByte(' ');
    try writePaddedStyled(writer, allocator, "MESSAGE / SIGNAL", 36, (zz.Style{}).fg(zz.Color.brightYellow).bold(true).inline_style(true));
    try writer.writeByte(' ');
    var value_header = Line{};
    var header_writer: std.Io.Writer = .fixed(&value_header.bytes);
    header_writer.writeAll("VALUE/DATA") catch {};
    for ("VALUE/DATA".len..value_column_width) |_| header_writer.writeByte(' ') catch {};
    header_writer.print(" {s:>8} {s:>11} {s:>11} {s:>24}", .{ "COUNT", "RX(s)", "DELTA(ms)", "CYCLE min/avg/max(ms)" }) catch {};
    value_header.len = header_writer.buffered().len;
    const header_start = @min(horizontal_scroll, value_header.len);
    const header_end = @min(value_header.len, header_start +| value_width);
    try writePaddedStyled(writer, allocator, value_header.bytes[header_start..header_end], value_width, (zz.Style{}).fg(zz.Color.brightYellow).bold(true).inline_style(true));
    try writer.writeByte('\n');
    const max_first_pin = pins.len -| @max(visible_rows, 1);
    var viewport_start = @min(first_pin, max_first_pin);
    if (selected_pin < viewport_start) {
        viewport_start = selected_pin;
    } else if (selected_pin >= viewport_start + @max(visible_rows, 1)) {
        viewport_start = @min(selected_pin + 1 - @max(visible_rows, 1), max_first_pin);
    }
    const viewport_end = @min(pins.len, viewport_start + @max(visible_rows, 1));
    for (pins.items[viewport_start..viewport_end], viewport_start..) |maybe_pin, pin_index| {
        const pin = maybe_pin.?;
        if (pin.message >= database.compiled.messages.len) continue;
        const message = database.compiled.messages[pin.message];
        const row = findLatestRow(snapshot, message.bus, message.id, message.extended, database);
        const frame = if (row) |latest| latest.frame else null;
        const selected = pin_index == selected_pin;
        const active_bg: zz.Color = if (selected) zz.Color.color256(24) else .none;
        try writeStyled(writer, allocator, if (selected) " > " else "   ", (zz.Style{}).fg(if (selected) zz.Color.brightWhite else zz.Color.brightCyan).bg(active_bg).bold(selected).inline_style(true));
        try writePaddedStyled(writer, allocator, message.bus, 20, (zz.Style{}).fg(zz.Color.gray(15)).bg(active_bg).inline_style(true));
        try writer.writeByte(' ');
        var title = Line{};
        if (pin.signal) |signal_index| {
            if (signal_index < message.signals.len) {
                setLine(&title, "{s}.{s}", .{ message.name, message.signals[signal_index].name });
            } else {
                setLine(&title, "{s}", .{message.name});
            }
        } else {
            setLine(&title, "{s}", .{message.name});
        }
        try writePaddedStyled(writer, allocator, title.bytes[0..title.len], 36, (zz.Style{}).fg(zz.Color.brightWhite).bg(active_bg).bold(true).inline_style(true));
        try writer.writeByte(' ');
        var value_data = Line{};
        var count_text: [24]u8 = undefined;
        var rx_text: [24]u8 = undefined;
        var delta_text: [24]u8 = undefined;
        var cycle_text: [40]u8 = undefined;
        var count_len: usize = 0;
        var rx_len: usize = 0;
        var delta_len: usize = 0;
        var cycle_len: usize = 0;
        if (row) |latest_row| {
            const latest = latest_row.frame;
            var value_writer: std.Io.Writer = .fixed(&value_data.bytes);
            if (pin.signal) |signal_index| {
                if (signal_index < message.signals.len) {
                    const physical_value = database.compiled.decodeSignalPhysical(pin.message, signal_index, latest.data[0..latest.len]) catch null;
                    const unit = database.doc.messages.items[pin.message].signals.items[signal_index].unit orelse "";
                    if (physical_value) |physical| {
                        value_writer.print("{d:.2} {s}", .{ physical, unit }) catch {};
                    } else {
                        value_writer.writeAll("inactive") catch {};
                    }
                }
            } else {
                writeHex(&value_writer, latest.data[0..latest.len]) catch {};
            }
            value_data.len = value_writer.buffered().len;
            count_len = (std.fmt.bufPrint(&count_text, "{d}", .{latest_row.count}) catch unreachable).len;
            rx_len = (std.fmt.bufPrint(&rx_text, "{d:.3}", .{@as(f64, @floatFromInt(latest.timestamp_ns)) / std.time.ns_per_s}) catch unreachable).len;
            if (latest_row.count > 1) {
                delta_len = (std.fmt.bufPrint(&delta_text, "{d:.3}", .{@as(f64, @floatFromInt(latest_row.last_delta_ns)) / std.time.ns_per_ms}) catch unreachable).len;
            } else {
                delta_len = (std.fmt.bufPrint(&delta_text, "n/a", .{}) catch unreachable).len;
            }
            if (latest_row.cycle_samples != 0) {
                cycle_len = (std.fmt.bufPrint(&cycle_text, "{d:.1}/{d:.1}/{d:.1}", .{
                    @as(f64, @floatFromInt(latest_row.cycle_min_ns)) / std.time.ns_per_ms,
                    @as(f64, @floatFromInt(latest_row.cycle_avg_ns)) / std.time.ns_per_ms,
                    @as(f64, @floatFromInt(latest_row.cycle_max_ns)) / std.time.ns_per_ms,
                }) catch unreachable).len;
            } else {
                cycle_len = (std.fmt.bufPrint(&cycle_text, "n/a", .{}) catch unreachable).len;
            }
        } else {
            setLine(&value_data, "waiting", .{});
            count_len = (std.fmt.bufPrint(&count_text, "-", .{}) catch unreachable).len;
            rx_len = (std.fmt.bufPrint(&rx_text, "-", .{}) catch unreachable).len;
            delta_len = (std.fmt.bufPrint(&delta_text, "-", .{}) catch unreachable).len;
            cycle_len = (std.fmt.bufPrint(&cycle_text, "-", .{}) catch unreachable).len;
        }
        var value = Line{};
        var value_line_writer: std.Io.Writer = .fixed(&value.bytes);
        const value_text = value_data.bytes[0..@min(value_data.len, value_column_width)];
        value_line_writer.writeAll(value_text) catch {};
        for (value_text.len..value_column_width) |_| value_line_writer.writeByte(' ') catch {};
        value_line_writer.print(" {s:>8} {s:>11} {s:>11} {s:>24}", .{
            count_text[0..count_len],
            rx_text[0..rx_len],
            delta_text[0..delta_len],
            cycle_text[0..cycle_len],
        }) catch {};
        value.len = value_line_writer.buffered().len;
        const value_start = @min(horizontal_scroll, value.len);
        const value_end = @min(value.len, value_start +| value_width);
        try writePaddedStyled(writer, allocator, value.bytes[value_start..value_end], value_width, (zz.Style{}).fg(if (frame != null) zz.Color.brightYellow else zz.Color.gray(12)).bg(active_bg).inline_style(true));
        try writer.writeByte('\n');
    }
}

pub fn visibleCount(state: *const State, snapshot: *const store.Snapshot, database: *const Database) usize {
    var count: usize = 0;
    for (0..256) |bus_index| {
        if (state.collapsed_buses[bus_index]) continue;
        count += countVisibleOnBus(state, snapshot, database, @intCast(bus_index));
    }
    return count;
}

pub fn selectedFrame(state: *const State, snapshot: *const store.Snapshot, database: *const Database) ?Frame {
    const index = selectedSourceIndex(state, snapshot, database) orelse return null;
    return sourceFrame(snapshot, state.trace_mode, index);
}

fn selectedSourceIndex(state: *const State, snapshot: *const store.Snapshot, database: *const Database) ?usize {
    const length = if (state.trace_mode) snapshot.trace_len else snapshot.row_count;
    if (state.selected_bus_header) |bus| {
        for (0..length) |source_index| {
            const frame = sourceFrame(snapshot, state.trace_mode, source_index).?;
            if (frame.bus == bus and frame.id == state.folded_message_id and frame.flags.extended == state.folded_message_extended and isVisible(state, frame, database)) return source_index;
        }
        for (0..length) |source_index| {
            const frame = sourceFrame(snapshot, state.trace_mode, source_index).?;
            if (frame.bus == bus and isVisible(state, frame, database)) return source_index;
        }
        return null;
    }
    var visible_index: usize = 0;
    for (0..256) |bus_index| {
        if (state.collapsed_buses[bus_index]) continue;
        for (0..length) |source_index| {
            const frame = sourceFrame(snapshot, state.trace_mode, source_index).?;
            if (frame.bus != bus_index or !isVisible(state, frame, database)) continue;
            if (visible_index == state.selected_row) return source_index;
            visible_index += 1;
        }
    }
    return null;
}

fn countVisibleOnBus(state: *const State, snapshot: *const store.Snapshot, database: *const Database, bus: u8) usize {
    const length = if (state.trace_mode) snapshot.trace_len else snapshot.row_count;
    var count: usize = 0;
    for (0..length) |source_index| {
        const frame = sourceFrame(snapshot, state.trace_mode, source_index).?;
        if (frame.bus == bus and isVisible(state, frame, database)) count += 1;
    }
    return count;
}

fn firstVisibleOnBus(state: *const State, snapshot: *const store.Snapshot, database: *const Database, bus: u8) ?Frame {
    const length = if (state.trace_mode) snapshot.trace_len else snapshot.row_count;
    for (0..length) |source_index| {
        const frame = sourceFrame(snapshot, state.trace_mode, source_index).?;
        if (frame.bus == bus and isVisible(state, frame, database)) return frame;
    }
    return null;
}

fn displayLineCount(state: *const State, snapshot: *const store.Snapshot, database: *const Database) usize {
    var count: usize = 0;
    for (0..256) |bus_index| {
        const message_count = countVisibleOnBus(state, snapshot, database, @intCast(bus_index));
        if (message_count == 0) continue;
        count += 1;
        if (!state.collapsed_buses[bus_index]) count += message_count;
    }
    return count;
}

fn selectedDisplayLine(state: *const State, snapshot: *const store.Snapshot, database: *const Database) ?usize {
    var display_line: usize = 0;
    var visible_message_index: usize = 0;
    for (0..256) |bus_index| {
        const bus = @as(u8, @intCast(bus_index));
        const message_count = countVisibleOnBus(state, snapshot, database, bus);
        if (message_count == 0) continue;
        if (state.selected_bus_header != null and state.selected_bus_header.? == bus) return display_line;
        display_line += 1;
        if (state.collapsed_buses[bus_index]) continue;
        if (state.selected_row >= visible_message_index and state.selected_row < visible_message_index + message_count) {
            return display_line + (state.selected_row - visible_message_index);
        }
        visible_message_index += message_count;
        display_line += message_count;
    }
    return null;
}

fn setSelectionAtDisplayLine(state: *State, snapshot: *const store.Snapshot, database: *const Database, selected_line: usize) void {
    var display_line: usize = 0;
    var visible_message_index: usize = 0;
    for (0..256) |bus_index| {
        const bus = @as(u8, @intCast(bus_index));
        const message_count = countVisibleOnBus(state, snapshot, database, bus);
        if (message_count == 0) continue;
        if (selected_line == display_line) {
            state.selected_bus_header = bus;
            state.selected_row = visible_message_index;
            if (firstVisibleOnBus(state, snapshot, database, bus)) |frame| {
                state.folded_message_id = frame.id;
                state.folded_message_extended = frame.flags.extended;
            }
            return;
        }
        display_line += 1;
        if (state.collapsed_buses[bus_index]) continue;
        if (selected_line < display_line + message_count) {
            state.selected_bus_header = null;
            state.selected_row = visible_message_index + selected_line - display_line;
            return;
        }
        visible_message_index += message_count;
        display_line += message_count;
    }
}

fn selectedSourceRow(snapshot: *const store.Snapshot, state: *const State, source_index: ?usize) ?store.MessageRow {
    if (state.trace_mode) return null;
    const index = source_index orelse return null;
    return snapshot.rows[index];
}

fn sourceFrame(snapshot: *const store.Snapshot, trace_mode: bool, index: usize) ?Frame {
    if (trace_mode) {
        if (index >= snapshot.trace_len) return null;
        return snapshot.trace[index];
    }
    if (index >= snapshot.row_count) return null;
    return snapshot.rows[index].frame;
}

fn isVisible(state: *const State, frame: Frame, database: *const Database) bool {
    const bus = busName(database, frame.bus);
    const handle = database.compiled.findMessage(bus, frame.id, frame.flags.extended);
    if (state.database_only and handle == null) return false;
    if (state.filter_len == 0) return true;
    if (containsIgnoreCase(bus, state.filter[0..state.filter_len])) return true;
    if (formatIdContains(frame.id, state.filter[0..state.filter_len])) return true;
    if (handle) |message_handle| {
        if (containsIgnoreCase(database.compiled.messages[message_handle].name, state.filter[0..state.filter_len])) return true;
    }
    return false;
}

fn busName(database: *const Database, index: u8) []const u8 {
    if (index >= database.doc.buses.items.len) return "unknown";
    return database.doc.buses.items[index].name;
}

fn findLatestRow(snapshot: *const store.Snapshot, bus: []const u8, id: u32, extended: bool, database: *const Database) ?store.MessageRow {
    for (snapshot.rows[0..snapshot.row_count]) |row| {
        const frame = row.frame;
        if (frame.id == id and frame.flags.extended == extended and std.mem.eql(u8, busName(database, frame.bus), bus)) return row;
    }
    return null;
}

fn formatMessageRow(line: *Line, frame: Frame, database: *const Database, selected: bool, data_bytes: usize) void {
    const bus = busName(database, frame.bus);
    const handle = database.compiled.findMessage(bus, frame.id, frame.flags.extended);
    const name = if (handle) |message_handle| database.compiled.messages[message_handle].name else "?";
    var writer: std.Io.Writer = .fixed(&line.bytes);
    const visible_name = name[0..@min(name.len, 13)];
    writer.print("{s}{s:<3} {s:<3} 0x{X:0>8} {s:<13} {d:>2} ", .{
        if (selected) "> " else "  ",
        if (frame.flags.extended) "EXT" else "STD",
        if (frame.flags.fd) "FD" else "CAN",
        frame.id,
        visible_name,
        frame.len,
    }) catch {};
    const bytes_to_show = @min(frame.len, data_bytes);
    for (frame.data[0..bytes_to_show]) |byte| writer.print("{X:0>2} ", .{byte}) catch {};
    line.len = writer.buffered().len;
}

fn buildDetailLines(lines: []Line, frame: Frame, row: ?store.MessageRow, database: *const Database, state: *const State, pins: *const config.PinSet) usize {
    const bus = busName(database, frame.bus);
    const handle = database.compiled.findMessage(bus, frame.id, frame.flags.extended) orelse {
        setLine(&lines[0], "Unknown {s} message on {s}", .{ frameKindLabel(frame), bus });
        setLine(&lines[1], "{s}  ID 0x{X:0>3} len {d}", .{ idFormatLabel(frame), frame.id, frame.len });
        setHexLine(&lines[2], "Data: ", frame.data[0..frame.len]);
        return 3;
    };
    const message = database.compiled.messages[handle];
    setLine(&lines[0], "{s} ({s}, {s})", .{ message.name, frameKindLabel(frame), idFormatLabel(frame) });
    setLine(&lines[1], "Bus {s}  ID 0x{X:0>3}  len {d}", .{ bus, frame.id, frame.len });
    if (row) |stats| {
        setLine(&lines[2], "{s:<12} {d:>12}", .{ "Count", stats.count });
        setLine(&lines[3], "{s:<12} {d:>10.3} ms", .{ "Cycle min", @as(f64, @floatFromInt(stats.cycle_min_ns)) / std.time.ns_per_ms });
        setLine(&lines[4], "{s:<12} {d:>10.3} ms", .{ "Cycle avg", @as(f64, @floatFromInt(stats.cycle_avg_ns)) / std.time.ns_per_ms });
        setLine(&lines[5], "{s:<12} {d:>10.3} ms", .{ "Cycle max", @as(f64, @floatFromInt(stats.cycle_max_ns)) / std.time.ns_per_ms });
    } else {
        setLine(&lines[2], "{s:<12} {s:>12}", .{ "Count", "trace" });
        setLine(&lines[3], "{s:<12} {s:>10}", .{ "Cycle min", "n/a" });
        setLine(&lines[4], "{s:<12} {s:>10}", .{ "Cycle avg", "n/a" });
        setLine(&lines[5], "{s:<12} {s:>10}", .{ "Cycle max", "n/a" });
    }
    setHexLine(&lines[6], "Data: ", frame.data[0..frame.len]);
    setLine(&lines[7], "{s:<12} {d:>10.3} s", .{ "Last RX", @as(f64, @floatFromInt(frame.timestamp_ns)) / std.time.ns_per_s });
    if (row) |stats| {
        if (stats.count > 1) {
            setLine(&lines[8], "{s:<12} {d:>10.3} ms", .{ "Last delta", @as(f64, @floatFromInt(stats.last_delta_ns)) / std.time.ns_per_ms });
        } else {
            setLine(&lines[8], "{s:<12} {s:>10}", .{ "Last delta", "n/a" });
        }
    } else {
        setLine(&lines[8], "{s:<12} {s:>10}", .{ "Last delta", "n/a" });
    }

    var count: usize = 9;
    for (message.signals, 0..) |signal, signal_index| {
        const marker = if (state.detail_focus and state.selected_signal == signal_index) "> " else "  ";
        lines[count].highlight = pins.contains(.{ .message = handle, .signal = signal_index });
        if (database.compiled.decodeSignalPhysical(handle, signal_index, frame.data[0..frame.len])) |value| {
            const unit = database.doc.messages.items[handle].signals.items[signal_index].unit orelse "";
            if (unit.len == 0) {
                setLine(&lines[count], "{s}{s:<20} {d:.4}", .{ marker, signal.name, value });
            } else {
                setLine(&lines[count], "{s}{s:<20} {d:.4} {s}", .{ marker, signal.name, value, unit });
            }
        } else |_| {
            setLine(&lines[count], "{s}{s:<20} inactive", .{ marker, signal.name });
        }
        count += 1;
    }
    return count;
}

fn frameKindLabel(frame: Frame) []const u8 {
    return if (frame.flags.fd) "CAN FD" else "Classic CAN";
}

fn idFormatLabel(frame: Frame) []const u8 {
    return if (frame.flags.extended) "Extended ID (29-bit)" else "Standard ID (11-bit)";
}

fn writeHex(writer: *std.Io.Writer, bytes: []const u8) !void {
    for (bytes) |byte| try writer.print("{X:0>2} ", .{byte});
}

fn writeStyled(writer: *std.Io.Writer, allocator: std.mem.Allocator, text: []const u8, style: zz.Style) !void {
    const rendered = try style.render(allocator, text);
    defer allocator.free(rendered);
    try writer.writeAll(rendered);
}

fn setHexLine(line: *Line, prefix: []const u8, bytes: []const u8) void {
    var writer: std.Io.Writer = .fixed(&line.bytes);
    writer.writeAll(prefix) catch {};
    for (bytes) |byte| writer.print("{X:0>2} ", .{byte}) catch break;
    line.len = writer.buffered().len;
}

fn setLine(line: *Line, comptime format: []const u8, args: anytype) void {
    var writer: std.Io.Writer = .fixed(&line.bytes);
    writer.print(format, args) catch {};
    line.len = writer.buffered().len;
}

fn writeColumns(allocator: std.mem.Allocator, writer: *std.Io.Writer, left: ?*const Line, right: ?*const Line, left_width: usize, right_width: usize, selected: bool) !void {
    const left_style = if (selected)
        (zz.Style{}).fg(zz.Color.brightWhite).bg(zz.Color.color256(24)).bold(true).inline_style(true)
    else
        zz.Style{};
    if (left) |line| {
        try writePaddedStyled(writer, allocator, line.bytes[0..line.len], left_width, left_style);
    } else {
        try writePaddedStyled(writer, allocator, "", left_width, left_style);
    }
    try writeStyled(writer, allocator, " | ", (zz.Style{}).fg(zz.Color.color256(60)).inline_style(true));
    if (right) |line| {
        if (line.highlight) {
            try writePaddedStyled(writer, allocator, line.bytes[0..line.len], right_width, (zz.Style{}).fg(zz.Color.brightYellow).bold(true).inline_style(true));
        } else {
            try writePadded(writer, line.bytes[0..line.len], right_width);
        }
    } else {
        try writePadded(writer, "", right_width);
    }
    try writer.writeByte('\n');
}

fn writePaddedStyled(writer: *std.Io.Writer, allocator: std.mem.Allocator, text: []const u8, width: usize, style: zz.Style) !void {
    const count = @min(text.len, width);
    const styled = try style.render(allocator, text[0..count]);
    defer allocator.free(styled);
    try writer.writeAll(styled);
    for (count..width) |_| try writer.writeByte(' ');
}

fn writePadded(writer: *std.Io.Writer, text: []const u8, width: usize) !void {
    const count = @min(text.len, width);
    try writer.writeAll(text[0..count]);
    for (count..width) |_| try writer.writeByte(' ');
}

fn formatIdContains(id: u32, filter: []const u8) bool {
    var buffer: [8]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{X}", .{id}) catch return false;
    return containsIgnoreCase(text, filter);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |start| {
        if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) return true;
    }
    return false;
}

test "monitor labels CAN frame format separately from identifier format" {
    const classic_standard = Frame{
        .timestamp_ns = 0,
        .id = 0x123,
        .bus = 0,
        .len = 0,
        .flags = .{},
        ._pad = 0,
        .data = @splat(0),
    };
    const fd_extended = Frame{
        .timestamp_ns = 0,
        .id = 0x800,
        .bus = 0,
        .len = 0,
        .flags = .{ .fd = true, .extended = true },
        ._pad = 0,
        .data = @splat(0),
    };

    try std.testing.expectEqualStrings("Classic CAN", frameKindLabel(classic_standard));
    try std.testing.expectEqualStrings("Standard ID (11-bit)", idFormatLabel(classic_standard));
    try std.testing.expectEqualStrings("CAN FD", frameKindLabel(fd_extended));
    try std.testing.expectEqualStrings("Extended ID (29-bit)", idFormatLabel(fd_extended));
}

test "monitor scrolls selected message and signal into view and folds its bus" {
    const source =
        \\VERSION ""
        \\
        \\NS_ :
        \\
        \\BS_:
        \\
        \\BU_: ECU
        \\
        \\BO_ 192 First: 8 ECU
        \\ SG_ Value : 0|8@1+ (1,0) [0|255] "" Vector__XXX
        \\
        \\BO_ 193 Second: 8 ECU
        \\ SG_ Value : 0|8@1+ (1,0) [0|255] "" Vector__XXX
        \\
        \\BO_ 194 Third: 8 ECU
        \\ SG_ Value : 0|8@1+ (1,0) [0|255] "" Vector__XXX
        \\
        \\BO_ 195 ManySignals: 8 ECU
        \\ SG_ S0 : 0|8@1+ (1,0) [0|255] "" Vector__XXX
        \\ SG_ S1 : 8|8@1+ (1,0) [0|255] "" Vector__XXX
        \\ SG_ S2 : 16|8@1+ (1,0) [0|255] "" Vector__XXX
        \\ SG_ S3 : 24|8@1+ (1,0) [0|255] "" Vector__XXX
        \\ SG_ S4 : 32|8@1+ (1,0) [0|255] "" Vector__XXX
        \\ SG_ S5 : 40|8@1+ (1,0) [0|255] "V" Vector__XXX
        \\
    ;
    var diagnostics: @import("../db/database.zig").Diagnostics = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    var database = try Database.init(std.testing.allocator, .dbc, source, &diagnostics);
    defer database.deinit();

    var snapshot: store.Snapshot = .{};
    snapshot.row_count = 5;
    for (0..snapshot.row_count) |index| {
        snapshot.rows[index].frame = .{
            .timestamp_ns = if (index == 3) 12 * std.time.ns_per_s + 345 * std.time.ns_per_ms else index,
            .id = @as(u32, 192) + @as(u32, @intCast(index)),
            .bus = if (index == 4) 1 else 0,
            .len = 8,
            .flags = .{},
            ._pad = 0,
            .data = @splat(0),
        };
    }
    @memcpy(snapshot.rows[3].frame.data[0..8], &[_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 });
    snapshot.rows[3].count = 48;
    snapshot.rows[3].cycle_min_ns = 8_486_000;
    snapshot.rows[3].cycle_avg_ns = 8_534_800;
    snapshot.rows[3].cycle_max_ns = 8_660_400;
    snapshot.rows[3].last_delta_ns = 8_800_000;
    snapshot.rows[3].cycle_samples = 2;
    var pins: config.PinSet = .{};
    try pins.toggle(.{ .message = 3, .signal = 5 });
    try pins.toggle(.{ .message = 0, .signal = 0 });
    try pins.toggle(.{ .message = 3, .signal = null });
    var state: State = .{ .selected_row = 3, .detail_focus = true, .selected_signal = 5 };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try render(std.testing.allocator, &output.writer, 120, 4, &database, &snapshot, &state, &pins);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "TYPE FMT") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "0x000000C3") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "11 22 33 44 55 66 77 88") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "S5") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "102.0000 V") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "S0") == null);

    var stats_state: State = .{ .selected_row = 3 };
    var stats_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stats_output.deinit();
    try render(std.testing.allocator, &stats_output.writer, 120, 12, &database, &snapshot, &stats_state, &pins);
    try std.testing.expect(std.mem.indexOf(u8, stats_output.written(), "Count") != null);
    try std.testing.expect(std.mem.indexOf(u8, stats_output.written(), "Cycle min") != null);
    try std.testing.expect(std.mem.indexOf(u8, stats_output.written(), "8.486 ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, stats_output.written(), "Cycle avg") != null);
    try std.testing.expect(std.mem.indexOf(u8, stats_output.written(), "8.535 ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, stats_output.written(), "Cycle max") != null);
    try std.testing.expect(std.mem.indexOf(u8, stats_output.written(), "8.660 ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, stats_output.written(), "Last RX") != null);
    try std.testing.expect(std.mem.indexOf(u8, stats_output.written(), "12.345 s") != null);
    try std.testing.expect(std.mem.indexOf(u8, stats_output.written(), "Last delta") != null);
    try std.testing.expect(std.mem.indexOf(u8, stats_output.written(), "8.800 ms") != null);

    var pins_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer pins_output.deinit();
    try renderPins(std.testing.allocator, &pins_output.writer, 160, &database, &snapshot, &pins, 0, 0, 2, 0);
    try std.testing.expect(std.mem.indexOf(u8, pins_output.written(), "BUS") != null);
    try std.testing.expect(std.mem.indexOf(u8, pins_output.written(), "MESSAGE / SIGNAL") != null);
    try std.testing.expect(std.mem.indexOf(u8, pins_output.written(), "ManySignals.S5") != null);
    try std.testing.expect(std.mem.indexOf(u8, pins_output.written(), "102.00") != null);
    try std.testing.expect(std.mem.indexOf(u8, pins_output.written(), "48") != null);
    try std.testing.expect(std.mem.indexOf(u8, pins_output.written(), "12.345") != null);
    try std.testing.expect(std.mem.indexOf(u8, pins_output.written(), "8.800") != null);
    try std.testing.expect(std.mem.indexOf(u8, pins_output.written(), "8.5/8.5/8.7") != null);

    var horizontal_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer horizontal_output.deinit();
    try renderPins(std.testing.allocator, &horizontal_output.writer, 140, &database, &snapshot, &pins, 0, 0, 1, 25);
    try std.testing.expect(std.mem.indexOf(u8, horizontal_output.written(), "48") != null);
    try std.testing.expect(std.mem.indexOf(u8, horizontal_output.written(), "102.00") == null);

    var message_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer message_output.deinit();
    try renderPins(std.testing.allocator, &message_output.writer, 140, &database, &snapshot, &pins, 2, 2, 1, 0);
    try std.testing.expect(std.mem.indexOf(u8, message_output.written(), "11 22 33 44 55 66 77 88") != null);

    var vertical_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer vertical_output.deinit();
    try renderPins(std.testing.allocator, &vertical_output.writer, 140, &database, &snapshot, &pins, 1, 1, 1, 0);
    try std.testing.expect(std.mem.indexOf(u8, vertical_output.written(), "First.Value") != null);
    try std.testing.expect(std.mem.indexOf(u8, vertical_output.written(), "ManySignals.S5") == null);

    state.toggleSelectedBus(&snapshot, &database);
    try std.testing.expectEqual(@as(?u8, 0), state.selected_bus_header);
    try std.testing.expectEqual(@as(usize, 1), visibleCount(&state, &snapshot, &database));
    try std.testing.expectEqual(@as(u32, 195), selectedFrame(&state, &snapshot, &database).?.id);
    state.detail_focus = false;
    state.move(1, &snapshot, &database);
    try std.testing.expectEqual(@as(?u8, 1), state.selected_bus_header);
    state.toggleSelectedBus(&snapshot, &database);
    try std.testing.expect(state.collapsed_buses[1]);
    try std.testing.expectEqual(@as(usize, 0), visibleCount(&state, &snapshot, &database));
    state.move(-1, &snapshot, &database);
    try std.testing.expectEqual(@as(?u8, 0), state.selected_bus_header);
    state.toggleSelectedBus(&snapshot, &database);
    try std.testing.expect(!state.collapsed_buses[0]);
    try std.testing.expectEqual(@as(?u8, 0), state.selected_bus_header);
    try std.testing.expectEqual(@as(usize, 4), visibleCount(&state, &snapshot, &database));
}
