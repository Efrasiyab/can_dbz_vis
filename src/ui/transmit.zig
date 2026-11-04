const std = @import("std");
const can_dbz = @import("can_dbz");
const Database = @import("../db/database.zig").Database;
const Frame = @import("../can/frame.zig").Frame;
const adapter = @import("../can/adapter.zig");
const max_payload_len = @import("../can/frame.zig").max_payload_len;
const tx = @import("../engine/tx.zig");

pub const max_signals = 64;

pub const State = struct {
    selected_message: usize = 0,
    selected_signal: usize = 0,
    values: [max_signals]f64 = @splat(0),
    initialized_message: ?usize = null,
    periodic_mode: bool = false,
    periodic_started: bool = false,
    auto_counter: bool = true,
    period_ms: u32 = 100,
    notice: []const u8 = "",

    pub fn ensureMessage(self: *State, database: *const Database) void {
        if (database.compiled.messages.len == 0) {
            self.initialized_message = null;
            return;
        }
        if (self.selected_message >= database.compiled.messages.len) self.selected_message = 0;
        if (self.initialized_message == self.selected_message) return;
        self.values = @splat(0);
        self.selected_signal = 0;
        const message = database.compiled.messages[self.selected_message];
        for (message.signals, 0..) |signal, index| self.values[index] = defaultPhysical(signal);
        self.initialized_message = self.selected_message;
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
        self.ensureMessage(database);
    }

    pub fn moveSignal(self: *State, database: *const Database, delta: isize) void {
        self.ensureMessage(database);
        if (database.compiled.messages.len == 0) return;
        const count = database.compiled.messages[self.selected_message].signals.len;
        if (count == 0) return;
        if (delta < 0) {
            self.selected_signal = if (self.selected_signal == 0) count - 1 else self.selected_signal - 1;
        } else {
            self.selected_signal = if (self.selected_signal + 1 >= count) 0 else self.selected_signal + 1;
        }
    }

    pub fn adjustSignal(self: *State, database: *const Database, delta: f64) void {
        self.ensureMessage(database);
        if (database.compiled.messages.len == 0) return;
        const message = database.compiled.messages[self.selected_message];
        if (self.selected_signal >= message.signals.len) return;
        self.values[self.selected_signal] = clampPhysical(message.signals[self.selected_signal], self.values[self.selected_signal] + delta);
    }

    pub fn cycleChoice(self: *State, database: *const Database, delta: isize) bool {
        self.ensureMessage(database);
        if (database.compiled.messages.len == 0) return false;
        const message = database.compiled.messages[self.selected_message];
        if (self.selected_signal >= message.signals.len) return false;
        const signal = message.signals[self.selected_signal];
        if (signal.choices.len == 0) return false;

        const current_raw = database.compiled.encodeSignalPhysical(self.selected_message, self.selected_signal, self.values[self.selected_signal], .nearest_ties_even) catch null;
        const current_value = if (current_raw) |raw| rawInteger(raw) else null;
        var current_index: ?usize = null;
        if (current_value) |value| {
            for (signal.choices, 0..) |choice, index| {
                const choice_value = std.fmt.parseInt(i128, choice.raw, 10) catch continue;
                if (choice_value == value) current_index = index;
            }
        }
        const index = current_index orelse 0;
        const next_index = if (delta < 0)
            if (index == 0) signal.choices.len - 1 else index - 1
        else if (index + 1 == signal.choices.len)
            0
        else
            index + 1;
        const raw_value = std.fmt.parseInt(i128, signal.choices[next_index].raw, 10) catch return false;
        const factor = std.fmt.parseFloat(f64, signal.factor) catch 1;
        const offset = std.fmt.parseFloat(f64, signal.offset) catch 0;
        self.values[self.selected_signal] = clampPhysical(signal, @as(f64, @floatFromInt(raw_value)) * factor + offset);
        return true;
    }

    pub fn advanceCounter(self: *State, database: *const Database) void {
        self.ensureMessage(database);
        if (database.compiled.messages.len == 0) return;
        const message = database.compiled.messages[self.selected_message];
        for (message.signals, 0..) |signal, index| {
            if (signal.signal_type != .unsigned or signal.bit_length == 0 or signal.bit_length > 64 or !isCounterName(signal.name)) continue;
            const raw = database.compiled.encodeSignalPhysical(self.selected_message, index, self.values[index], .nearest_ties_even) catch continue;
            const integer = switch (raw) {
                .unsigned => |value| value,
                else => continue,
            };
            const next = if (signal.bit_length == 64)
                integer +% 1
            else
                (integer +% 1) & ((@as(u64, 1) << @intCast(signal.bit_length)) - 1);
            const factor = std.fmt.parseFloat(f64, signal.factor) catch 1;
            const offset = std.fmt.parseFloat(f64, signal.offset) catch 0;
            self.values[index] = clampPhysical(signal, @as(f64, @floatFromInt(next)) * factor + offset);
        }
    }
};

pub fn buildFrame(database: *const Database, bus_index: u8, state: *const State) !Frame {
    if (database.compiled.messages.len == 0) return error.NoMessages;
    const handle = state.selected_message;
    const message = database.compiled.messages[handle];
    if (message.signals.len > max_signals or message.length > max_payload_len) return error.UnsupportedMessage;

    var inputs: [max_signals]?can_dbz.codec.RawValue = @splat(null);
    for (message.signals, 0..) |_, index| {
        inputs[index] = try database.compiled.encodeSignalPhysical(handle, index, state.values[index], .nearest_ties_even);
    }
    for (message.signals, 0..) |signal, index| {
        if (!isSignalActive(message, signal.when, &inputs)) inputs[index] = null;
    }

    var frame = Frame{
        .timestamp_ns = 0,
        .id = message.id,
        .bus = bus_index,
        .len = @intCast(message.length),
        .flags = .{ .extended = message.extended, .fd = message.frame == .fd },
        ._pad = 0,
        .data = @splat(0),
    };
    var scratch: [max_signals + max_payload_len]u8 = undefined;
    const length = try database.compiled.encodeRaw(handle, inputs[0..message.signals.len], &frame.data, &scratch);
    frame.len = @intCast(length);
    return frame;
}

pub fn counterSpec(database: *const Database, state: *const State) ?tx.CounterSpec {
    if (!state.auto_counter or database.compiled.messages.len == 0) return null;
    const message = database.compiled.messages[state.selected_message];
    for (message.signals, 0..) |signal, index| {
        if (signal.signal_type != .unsigned or signal.bit_length == 0 or signal.bit_length > 64 or !isCounterName(signal.name)) continue;
        const encoded = database.compiled.encodeSignalPhysical(state.selected_message, index, state.values[index], .nearest_ties_even) catch continue;
        const raw = switch (encoded) {
            .unsigned => |value| value,
            else => continue,
        };
        var result = tx.CounterSpec{
            .bit_length = @intCast(signal.bit_length),
            .little_endian = signal.byte_order == .little_endian,
            .initial = raw,
        };
        @memcpy(result.bit_positions[0..signal.bit_positions.len], signal.bit_positions);
        return result;
    }
    return null;
}

pub fn render(writer: *std.Io.Writer, database: *const Database, state: *const State, connected: bool, active_jobs: u32) !void {
    try writer.writeAll("Database messages\n");
    if (database.compiled.messages.len == 0) {
        try writer.writeAll("No messages in database\n");
        return;
    }

    const message = database.compiled.messages[state.selected_message];
    try writer.print("<{d}/{d}> {s}  0x{X:0>3} -> {s}  len {d}{s}\n", .{
        state.selected_message + 1,
        database.compiled.messages.len,
        message.name,
        message.id,
        message.bus,
        message.length,
        if (message.frame == .fd) " FD" else "",
    });
    for (message.signals, 0..) |signal, index| {
        const raw = database.compiled.encodeSignalPhysical(state.selected_message, index, state.values[index], .nearest_ties_even) catch null;
        const choice = if (raw) |raw_value| database.compiled.choiceLabel(state.selected_message, index, raw_value) catch null else null;
        const unit = signalUnit(database, message.bus, message.name, signal.name);
        const minimum = signal.minimum orelse "-inf";
        const maximum = signal.maximum orelse "+inf";
        try writer.print(" {s}{s:<20} {d:>11.4} {s:<8} [{s}..{s}]", .{
            if (index == state.selected_signal) ">" else " ",
            signal.name,
            state.values[index],
            unit,
            minimum,
            maximum,
        });
        if (choice) |label| try writer.print("  {s}", .{label});
        if (signal.is_multiplexer) try writer.writeAll("  mux");
        try writer.writeByte('\n');
    }

    const bus_index = findBusIndex(database, message.bus) orelse {
        try writer.writeAll("Bus is not present in the database\n");
        return;
    };
    const frame = buildFrame(database, bus_index, state) catch |err| {
        try writer.print("Invalid payload: {s}\n", .{@errorName(err)});
        return;
    };
    try writer.writeAll("Payload ");
    for (frame.data[0..frame.len]) |byte| try writer.print("{X:0>2} ", .{byte});
    try writer.writeByte('\n');
    try writer.print("{s}  {s}  {d} ms  active jobs {d}\n", .{
        if (!connected) "Disconnected" else if (state.periodic_mode) "Periodic" else "One-shot",
        if (state.periodic_started) "[stop with x]" else "[Enter send / s start]",
        state.period_ms,
        active_jobs,
    });
    if (counterSpec(database, state) != null) try writer.print("Counter {s}\n", .{if (state.auto_counter) "auto +1 (k toggles)" else "manual"});
    if (state.notice.len != 0) try writer.print("{s}\n", .{state.notice});
}

pub fn findBusIndex(database: *const Database, bus_name: []const u8) ?u8 {
    for (database.doc.buses.items, 0..) |bus, index| {
        if (std.mem.eql(u8, bus.name, bus_name)) return @intCast(index);
    }
    return null;
}

fn signalUnit(database: *const Database, bus_name: []const u8, message_name: []const u8, signal_name: []const u8) []const u8 {
    for (database.doc.messages.items) |message| {
        if (!std.mem.eql(u8, message.bus, bus_name) or !std.mem.eql(u8, message.name, message_name)) continue;
        for (message.signals.items) |signal| {
            if (std.mem.eql(u8, signal.name, signal_name)) return signal.unit orelse "";
        }
    }
    return "";
}

fn defaultPhysical(signal: can_dbz.compile.SignalPlan) f64 {
    const factor = std.fmt.parseFloat(f64, signal.factor) catch 1;
    const offset = std.fmt.parseFloat(f64, signal.offset) catch 0;
    var raw: f64 = 0;
    if (signal.choices.len != 0) raw = std.fmt.parseFloat(f64, signal.choices[0].raw) catch 0;
    return clampPhysical(signal, raw * factor + offset);
}

fn clampPhysical(signal: can_dbz.compile.SignalPlan, value: f64) f64 {
    var result = value;
    if (signal.minimum) |minimum_text| {
        const minimum = std.fmt.parseFloat(f64, minimum_text) catch result;
        result = @max(result, minimum);
    }
    if (signal.maximum) |maximum_text| {
        const maximum = std.fmt.parseFloat(f64, maximum_text) catch result;
        result = @min(result, maximum);
    }
    return result;
}

fn isSignalActive(message: can_dbz.compile.MessagePlan, conditions: []const can_dbz.model.MuxCondition, inputs: *const [max_signals]?can_dbz.codec.RawValue) bool {
    for (conditions) |condition| {
        const selector_index = message.signal_index.get(condition.selector) orelse return false;
        const raw = inputs[selector_index] orelse return false;
        const value = rawInteger(raw) orelse return false;
        var matches = false;
        for (condition.ranges.items) |range| {
            const minimum = std.fmt.parseInt(i128, range.minimum, 10) catch continue;
            const maximum = std.fmt.parseInt(i128, range.maximum, 10) catch continue;
            if (value >= minimum and value <= maximum) matches = true;
        }
        if (!matches) return false;
    }
    return true;
}

fn rawInteger(raw: can_dbz.codec.RawValue) ?i128 {
    return switch (raw) {
        .unsigned => |value| std.math.cast(i128, value),
        .signed => |value| value,
        else => null,
    };
}

fn isCounterName(name: []const u8) bool {
    if (name.len == 3 and std.ascii.eqlIgnoreCase(name, "cnt")) return true;
    if (name.len < 7) return false;
    for (0..name.len - 6) |start| {
        if (std.ascii.eqlIgnoreCase(name[start .. start + 7], "counter")) return true;
    }
    return false;
}

test "transmit form builds payload through compiled signal encoder" {
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
        \\ SG_ CoolantTemp : 16|8@1+ (1,-40) [-40|215] "degC" Vector__XXX
        \\ SG_ Counter : 24|4@1+ (1,0) [0|15] "" Vector__XXX
        \\
    ;
    var diagnostics: Diagnostics = .empty;
    defer diagnostics.deinit(allocator);
    var database = try Database.init(allocator, .dbc, source, &diagnostics);
    defer database.deinit();

    var state: State = .{};
    state.ensureMessage(&database);
    state.values[0] = 2500;
    state.values[1] = 88;
    const frame = try buildFrame(&database, 0, &state);
    try std.testing.expectEqual(@as(u32, 192), frame.id);
    try std.testing.expectEqual(@as(u8, 8), frame.len);
    const handle = database.compiled.findMessage("can0", 192, false).?;
    try std.testing.expectApproxEqAbs(@as(f64, 2500), try database.compiled.decodeSignalPhysical(handle, 0, frame.data[0..frame.len]), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 88), try database.compiled.decodeSignalPhysical(handle, 1, frame.data[0..frame.len]), 1e-9);
    const counter = counterSpec(&database, &state).?;
    try std.testing.expectEqual(@as(u8, 4), counter.bit_length);
    try std.testing.expectEqual(@as(u64, 0), counter.initial);
    state.advanceCounter(&database);
    const next_counter = try database.compiled.encodeSignalPhysical(handle, 2, state.values[2], .nearest_ties_even);
    try std.testing.expectEqual(@as(u64, 1), next_counter.unsigned);
}
