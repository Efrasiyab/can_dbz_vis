const std = @import("std");
const zz = @import("zigzag");
const Database = @import("../db/database.zig").Database;
const Frame = @import("../can/frame.zig").Frame;
const store = @import("../engine/store.zig");
const config = @import("config.zig");

const Line = struct {
    bytes: [256]u8 = undefined,
    len: usize = 0,
};

pub const State = struct {
    selected_row: usize = 0,
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
        const count = visibleCount(self, snapshot, database);
        if (count == 0) {
            self.selected_row = 0;
            return;
        }
        const position: isize = @intCast(self.selected_row);
        const next = @as(i128, position) + amount;
        self.selected_row = @intCast(@min(@max(next, 0), @as(i128, @intCast(count - 1))));
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

    const body_rows: usize = if (height > 12) height - 12 else 3;
    const rows = @min(body_rows, 24);
    var detail_lines: [24]Line = @splat(.{});
    const detail_count = if (selected_frame) |frame|
        buildDetailLines(&detail_lines, frame, selectedSourceRow(snapshot, state, selected_source), database, state)
    else blk: {
        setLine(&detail_lines[0], "No frames received", .{});
        break :blk 1;
    };

    var visible_index: usize = 0;
    var source_index: usize = 0;
    while (visible_index < rows) : (source_index += 1) {
        const frame = sourceFrame(snapshot, state.trace_mode, source_index) orelse break;
        if (!isVisible(state, frame, database)) continue;

        var left = Line{};
        formatMessageRow(&left, frame, if (!state.trace_mode) snapshot.rows[source_index] else null, database, visible_index == state.selected_row);
        const right = if (visible_index < detail_count) &detail_lines[visible_index] else null;
        try writeColumns(allocator, writer, &left, right, left_width, right_width, visible_index == state.selected_row);
        visible_index += 1;
    }
    if (visible_index == 0) {
        var left = Line{};
        if (state.filter_len == 0) {
            setLine(&left, "No messages", .{});
        } else {
            setLine(&left, "No matches", .{});
        }
        for (0..@min(rows, detail_count)) |line_index| {
            try writeColumns(allocator, writer, if (line_index == 0) &left else null, &detail_lines[line_index], left_width, right_width, false);
        }
        if (detail_count == 0) try writeColumns(allocator, writer, &left, null, left_width, right_width, false);
    }
}

pub fn renderPins(allocator: std.mem.Allocator, writer: *std.Io.Writer, database: *const Database, snapshot: *const store.Snapshot, pins: *const config.PinSet, selected_pin: usize) !void {
    if (pins.len == 0) return;
    for (pins.items[0..pins.len], 0..) |maybe_pin, pin_index| {
        const pin = maybe_pin.?;
        if (pin.message >= database.compiled.messages.len) continue;
        const message = database.compiled.messages[pin.message];
        const frame = findLatest(snapshot, message.bus, message.id, message.extended, database);
        const selected = pin_index == selected_pin;
        const active_bg: zz.Color = if (selected) zz.Color.color256(24) else .none;
        try writeStyled(writer, allocator, if (selected) " > " else "   ", (zz.Style{}).fg(if (selected) zz.Color.brightWhite else zz.Color.brightCyan).bg(active_bg).bold(selected).inline_style(true));
        try writeStyled(writer, allocator, message.bus, (zz.Style{}).fg(zz.Color.gray(15)).bg(active_bg).inline_style(true));
        try writeStyled(writer, allocator, "  ", (zz.Style{}).bg(active_bg).inline_style(true));
        try writeStyled(writer, allocator, message.name, (zz.Style{}).fg(zz.Color.brightWhite).bg(active_bg).bold(true).inline_style(true));
        if (pin.signal) |signal_index| {
            if (signal_index < message.signals.len) {
                try writeStyled(writer, allocator, ".", (zz.Style{}).fg(zz.Color.gray(15)).bg(active_bg).inline_style(true));
                try writeStyled(writer, allocator, message.signals[signal_index].name, (zz.Style{}).fg(zz.Color.brightGreen).bg(active_bg).inline_style(true));
            }
        }
        if (frame) |latest| {
            if (pin.signal) |signal_index| {
                if (signal_index < message.signals.len) {
                    const value = database.compiled.decodeSignalPhysical(pin.message, signal_index, latest.data[0..latest.len]) catch null;
                    if (value) |physical| {
                        const formatted = try std.fmt.allocPrint(allocator, " = {d:.3}", .{physical});
                        defer allocator.free(formatted);
                        try writeStyled(writer, allocator, formatted, (zz.Style{}).fg(zz.Color.brightYellow).bg(active_bg).inline_style(true));
                    }
                }
            } else {
                var payload: [64 * 3]u8 = undefined;
                var payload_writer: std.Io.Writer = .fixed(&payload);
                try writeHex(&payload_writer, latest.data[0..latest.len]);
                try writeStyled(writer, allocator, payload_writer.buffered(), (zz.Style{}).fg(zz.Color.brightYellow).bg(active_bg).inline_style(true));
            }
        } else {
            try writeStyled(writer, allocator, "  waiting", (zz.Style{}).fg(zz.Color.gray(12)).italic(true).inline_style(true));
        }
        try writer.writeByte('\n');
    }
}

pub fn visibleCount(state: *const State, snapshot: *const store.Snapshot, database: *const Database) usize {
    const length = if (state.trace_mode) snapshot.trace_len else snapshot.row_count;
    var count: usize = 0;
    for (0..length) |index| {
        const frame = sourceFrame(snapshot, state.trace_mode, index).?;
        if (isVisible(state, frame, database)) count += 1;
    }
    return count;
}

pub fn selectedFrame(state: *const State, snapshot: *const store.Snapshot, database: *const Database) ?Frame {
    const index = selectedSourceIndex(state, snapshot, database) orelse return null;
    return sourceFrame(snapshot, state.trace_mode, index);
}

fn selectedSourceIndex(state: *const State, snapshot: *const store.Snapshot, database: *const Database) ?usize {
    const length = if (state.trace_mode) snapshot.trace_len else snapshot.row_count;
    var visible_index: usize = 0;
    for (0..length) |source_index| {
        const frame = sourceFrame(snapshot, state.trace_mode, source_index).?;
        if (!isVisible(state, frame, database)) continue;
        if (visible_index == state.selected_row) return source_index;
        visible_index += 1;
    }
    return null;
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

fn findLatest(snapshot: *const store.Snapshot, bus: []const u8, id: u32, extended: bool, database: *const Database) ?Frame {
    for (snapshot.rows[0..snapshot.row_count]) |row| {
        const frame = row.frame;
        if (frame.id == id and frame.flags.extended == extended and std.mem.eql(u8, busName(database, frame.bus), bus)) return frame;
    }
    return null;
}

fn formatMessageRow(line: *Line, frame: Frame, row: ?store.MessageRow, database: *const Database, selected: bool) void {
    const bus = busName(database, frame.bus);
    const handle = database.compiled.findMessage(bus, frame.id, frame.flags.extended);
    const name = if (handle) |message_handle| database.compiled.messages[message_handle].name else "?";
    var writer: std.Io.Writer = .fixed(&line.bytes);
    writer.print("{s} {s:<10} 0x{X:0>3} {s:<16} {d:>2} ", .{
        if (selected) ">" else " ",
        bus,
        frame.id,
        name,
        frame.len,
    }) catch {};
    const bytes_to_show = @min(frame.len, 3);
    for (frame.data[0..bytes_to_show]) |byte| writer.print("{X:0>2} ", .{byte}) catch {};
    if (row) |stats| writer.print(" {d} {d:.1}ms", .{ stats.count, @as(f64, @floatFromInt(stats.cycle_avg_ns)) / std.time.ns_per_ms }) catch {};
    line.len = writer.buffered().len;
}

fn buildDetailLines(lines: *[24]Line, frame: Frame, row: ?store.MessageRow, database: *const Database, state: *const State) usize {
    const bus = busName(database, frame.bus);
    const handle = database.compiled.findMessage(bus, frame.id, frame.flags.extended) orelse {
        setLine(&lines[0], "Unknown message on {s}", .{bus});
        setLine(&lines[1], "ID 0x{X:0>3} len {d}", .{ frame.id, frame.len });
        setHexLine(&lines[2], "Data: ", frame.data[0..frame.len]);
        return 3;
    };
    const message = database.compiled.messages[handle];
    setLine(&lines[0], "{s} ({s})", .{ message.name, if (frame.flags.extended) "extended" else "standard" });
    setLine(&lines[1], "Bus {s}  ID 0x{X:0>3}  len {d}{s}", .{ bus, frame.id, frame.len, if (frame.flags.fd) " FD" else "" });
    if (row) |stats| {
        setLine(&lines[2], "Count {d}  cycle min/avg/max {d:.1}/{d:.1}/{d:.1} ms", .{
            stats.count,
            @as(f64, @floatFromInt(stats.cycle_min_ns)) / std.time.ns_per_ms,
            @as(f64, @floatFromInt(stats.cycle_avg_ns)) / std.time.ns_per_ms,
            @as(f64, @floatFromInt(stats.cycle_max_ns)) / std.time.ns_per_ms,
        });
    } else {
        setLine(&lines[2], "Chronological frame", .{});
    }
    setHexLine(&lines[3], "Data: ", frame.data[0..frame.len]);

    var count: usize = 4;
    for (message.signals, 0..) |signal, signal_index| {
        if (count == lines.len) break;
        const marker = if (state.detail_focus and state.selected_signal == signal_index) "> " else "  ";
        if (database.compiled.decodeSignalPhysical(handle, signal_index, frame.data[0..frame.len])) |value| {
            setLine(&lines[count], "{s}{s:<20} {d:.4}", .{ marker, signal.name, value });
        } else |_| {
            setLine(&lines[count], "{s}{s:<20} inactive", .{ marker, signal.name });
        }
        count += 1;
    }
    return count;
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
        try writePadded(writer, line.bytes[0..line.len], right_width);
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
