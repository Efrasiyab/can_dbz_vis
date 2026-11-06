const std = @import("std");
const can_dbz = @import("can_dbz");
const codec = can_dbz.codec;
const model = can_dbz.model;
const Frame = @import("can/frame.zig").Frame;
const Database = @import("db/database.zig").Database;
const rx = @import("engine/rx.zig");
const clock = @import("sync/clock.zig");

pub const target_sweep_interval_ns = 100 * std.time.ns_per_ms;

pub fn frameIntervalNs(message_count: usize) u64 {
    if (message_count == 0) return target_sweep_interval_ns;
    return @max(1, target_sweep_interval_ns / message_count);
}

pub const Source = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    database: *const Database,
    queue: *rx.FrameQueue,
    inputs: []?codec.RawValue,
    input_states: []u8,
    scratch: []u8,
    stop_requested: std.atomic.Value(bool) = .init(true),
    sequence: u64 = 0,
    thread: ?std.Thread = null,

    pub const StartError = std.Thread.SpawnError || error{AlreadyStarted};

    pub fn create(allocator: std.mem.Allocator, io: std.Io, database: *const Database, queue: *rx.FrameQueue) std.mem.Allocator.Error!*Source {
        var max_signals: usize = 0;
        for (database.compiled.messages) |message| max_signals = @max(max_signals, message.signals.len);
        const inputs = try allocator.alloc(?codec.RawValue, max_signals);
        errdefer allocator.free(inputs);
        const input_states = try allocator.alloc(u8, max_signals);
        errdefer allocator.free(input_states);
        const scratch = try allocator.alloc(u8, 64 + max_signals);
        errdefer allocator.free(scratch);
        const source = try allocator.create(Source);
        errdefer allocator.destroy(source);
        source.* = .{
            .allocator = allocator,
            .io = io,
            .database = database,
            .queue = queue,
            .inputs = inputs,
            .input_states = input_states,
            .scratch = scratch,
        };
        return source;
    }

    pub fn start(self: *Source) StartError!void {
        if (self.thread != null) return error.AlreadyStarted;
        self.stop_requested.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn stopAndDeinit(self: *Source) void {
        self.stop();
        self.allocator.free(self.inputs);
        self.allocator.free(self.input_states);
        self.allocator.free(self.scratch);
        self.allocator.destroy(self);
    }

    pub fn stop(self: *Source) void {
        self.stop_requested.store(true, .release);
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    pub fn nextFrame(self: *Source, timestamp_ns: u64) ?Frame {
        if (self.database.compiled.messages.len == 0) return null;
        const message_index = self.sequence % self.database.compiled.messages.len;
        const message = self.database.compiled.messages[message_index];
        const bus_index = busIndex(self.database, message.bus) orelse return null;
        var frame = Frame{
            .timestamp_ns = timestamp_ns,
            .id = message.id,
            .bus = bus_index,
            .len = @intCast(message.length),
            .flags = .{
                .extended = message.extended,
                .fd = message.frame == .fd,
                .brs = message.frame == .fd,
            },
            ._pad = 0,
            .data = @splat(0),
        };
        fillPayload(self.database, message_index, &frame, self.sequence, self.inputs, self.input_states, self.scratch);
        self.sequence +%= 1;
        return frame;
    }

    fn run(self: *Source) void {
        const interval_ns = frameIntervalNs(self.database.compiled.messages.len);
        while (!self.stop_requested.load(.acquire)) {
            const frame_start_ns = clock.nowNs(self.io);
            if (self.nextFrame(frame_start_ns)) |frame| {
                _ = self.queue.push(frame);
                const elapsed_ns = clock.nowNs(self.io) -| frame_start_ns;
                if (elapsed_ns < interval_ns) {
                    std.Io.sleep(self.io, .{ .nanoseconds = interval_ns - elapsed_ns }, .awake) catch {};
                }
            } else {
                std.Io.sleep(self.io, .{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch {};
            }
        }
    }
};

fn busIndex(database: *const Database, name: []const u8) ?u8 {
    for (database.doc.buses.items, 0..) |bus, index| {
        if (std.mem.eql(u8, bus.name, name)) return @intCast(index);
    }
    return null;
}

fn fillPayload(database: *const Database, handle: usize, frame: *Frame, sequence: u64, inputs: []?codec.RawValue, input_states: []u8, scratch: []u8) void {
    const message = database.compiled.messages[handle];
    const message_inputs = inputs[0..message.signals.len];
    const message_states = input_states[0..message.signals.len];
    @memset(message_inputs, null);
    @memset(message_states, 0);
    @memset(frame.data[0..frame.len], 0);
    var state = sequence ^ (@as(u64, frame.id) << 32) ^ 0x9e3779b97f4a7c15;
    for (message.signals, 0..) |_, signal_index| {
        _ = generateSignalInput(message.signals, message_inputs, message_states, signal_index, null, &state, 0);
    }
    _ = database.compiled.encodeRaw(handle, message_inputs, frame.data[0..frame.len], scratch[0 .. frame.len + message.signals.len]) catch return;
}

fn generateSignalInput(
    signals: []const can_dbz.compile.SignalPlan,
    inputs: []?codec.RawValue,
    states: []u8,
    signal_index: usize,
    required_ranges: ?[]const model.RawRange,
    random_state: *u64,
    depth: usize,
) bool {
    if (depth > signals.len or states[signal_index] == 1 or states[signal_index] == 3) return false;
    if (states[signal_index] == 2) return if (required_ranges) |ranges| rawMatchesRanges(inputs[signal_index].?, ranges) else true;

    states[signal_index] = 1;
    const signal = signals[signal_index];
    for (signal.when) |condition| {
        const selector_index = findSignalIndex(signals, condition.selector) orelse {
            states[signal_index] = 3;
            return false;
        };
        if (!generateSignalInput(signals, inputs, states, selector_index, condition.ranges.items, random_state, depth + 1)) {
            states[signal_index] = 3;
            return false;
        }
        if (!rawMatchesRanges(inputs[selector_index].?, condition.ranges.items)) {
            states[signal_index] = 3;
            return false;
        }
    }

    var raw = if (required_ranges) |ranges|
        chooseSignalRaw(signal, ranges, random_state)
    else
        null;
    if (raw == null and required_ranges == null) {
        for (signals) |candidate| {
            for (candidate.when) |condition| {
                if (!std.mem.eql(u8, condition.selector, signal.name)) continue;
                raw = chooseSignalRaw(signal, condition.ranges.items, random_state);
                if (raw != null) break;
            }
            if (raw != null) break;
        }
    }
    if (raw == null and required_ranges == null) raw = chooseSignalRaw(signal, null, random_state);
    if (raw) |value| {
        inputs[signal_index] = value;
        states[signal_index] = 2;
        return true;
    }
    states[signal_index] = 3;
    return false;
}

fn chooseSignalRaw(signal: can_dbz.compile.SignalPlan, ranges: ?[]const model.RawRange, random_state: *u64) ?codec.RawValue {
    if (signal.choices.len != 0) {
        const start = nextRandom(random_state) % signal.choices.len;
        for (0..signal.choices.len) |offset| {
            const choice = signal.choices[(start + offset) % signal.choices.len];
            const raw_integer = std.fmt.parseInt(i128, choice.raw, 10) catch continue;
            const raw: codec.RawValue = switch (signal.signal_type) {
                .unsigned => if (raw_integer >= 0) .{ .unsigned = @intCast(raw_integer) } else continue,
                .signed => .{ .signed = @intCast(raw_integer) },
                else => continue,
            };
            if (ranges) |required| if (!rawMatchesRanges(raw, required)) continue;
            if (rawIsValid(signal, raw)) return raw;
        }
        return null;
    }

    switch (signal.signal_type) {
        .unsigned, .signed => {
            const type_min: i128 = if (signal.signal_type == .signed)
                -(@as(i128, 1) << @intCast(signal.bit_length - 1))
            else
                0;
            const type_max: i128 = if (signal.signal_type == .signed)
                (@as(i128, 1) << @intCast(signal.bit_length - 1)) - 1
            else
                (@as(i128, 1) << @intCast(signal.bit_length)) - 1;
            var domain_min = type_min;
            var domain_max = type_max;
            if (ranges == null and signal.minimum == null and signal.maximum == null) {
                domain_min = @max(domain_min, -1000);
                domain_max = @min(domain_max, 1000);
            }
            const factor = parseFloatOr(signal.factor, 1);
            const offset = parseFloatOr(signal.offset, 0);
            if (factor == 0) {
                if (!physicalWithinBounds(signal, offset)) return null;
            } else {
                if (signal.minimum) |text| {
                    const bound = (parseFloatOr(text, -std.math.inf(f64)) - offset) / factor;
                    if (std.math.isFinite(bound)) {
                        if (factor > 0) domain_min = @max(domain_min, clampIntegerBound(@ceil(bound), domain_min, domain_max)) else domain_max = @min(domain_max, clampIntegerBound(@floor(bound), domain_min, domain_max));
                    }
                }
                if (signal.maximum) |text| {
                    const bound = (parseFloatOr(text, std.math.inf(f64)) - offset) / factor;
                    if (std.math.isFinite(bound)) {
                        if (factor > 0) domain_max = @min(domain_max, clampIntegerBound(@floor(bound), domain_min, domain_max)) else domain_min = @max(domain_min, clampIntegerBound(@ceil(bound), domain_min, domain_max));
                    }
                }
            }
            if (domain_min > domain_max) return null;
            if (ranges) |required| {
                if (required.len == 0) return null;
                const start = nextRandom(random_state) % required.len;
                for (0..required.len) |offset_index| {
                    const range = required[(start + offset_index) % required.len];
                    const range_min = std.fmt.parseInt(i128, range.minimum, 10) catch continue;
                    const range_max = std.fmt.parseInt(i128, range.maximum, 10) catch continue;
                    const low = @max(domain_min, range_min);
                    const high = @min(domain_max, range_max);
                    if (low > high) continue;
                    const integer = randomInteger(low, high, random_state);
                    const raw: codec.RawValue = if (signal.signal_type == .signed)
                        .{ .signed = @intCast(integer) }
                    else
                        .{ .unsigned = @intCast(integer) };
                    if (rawIsValid(signal, raw)) return raw;
                }
                return null;
            }
            const integer = randomInteger(domain_min, domain_max, random_state);
            const raw: codec.RawValue = if (signal.signal_type == .signed)
                .{ .signed = @intCast(integer) }
            else
                .{ .unsigned = @intCast(integer) };
            return if (rawIsValid(signal, raw)) raw else null;
        },
        .float32 => {
            if (ranges != null) return null;
            for (0..32) |_| {
                const sample: f32 = @as(f32, @floatFromInt(@as(i16, @intCast(@as(i32, @intCast(nextRandom(random_state) % 201)) - 100))));
                const raw: codec.RawValue = .{ .float32 = sample };
                if (rawIsValid(signal, raw)) return raw;
            }
            return null;
        },
        .float64 => {
            if (ranges != null) return null;
            for (0..32) |_| {
                const sample: f64 = @floatFromInt(@as(i16, @intCast(@as(i32, @intCast(nextRandom(random_state) % 201)) - 100)));
                const raw: codec.RawValue = .{ .float64 = sample };
                if (rawIsValid(signal, raw)) return raw;
            }
            return null;
        },
    }
}

fn rawIsValid(signal: can_dbz.compile.SignalPlan, raw: codec.RawValue) bool {
    const model_signal = modelSignal(signal);
    _ = codec.decodePhysical(&model_signal, raw) catch return false;
    return true;
}

fn modelSignal(signal: can_dbz.compile.SignalPlan) model.Signal {
    return .{
        .name = signal.name,
        .start_bit = signal.start_bit,
        .bit_length = signal.bit_length,
        .byte_order = signal.byte_order,
        .signal_type = signal.signal_type,
        .factor = signal.factor,
        .offset = signal.offset,
        .minimum = signal.minimum,
        .maximum = signal.maximum,
    };
}

fn rawMatchesRanges(raw: codec.RawValue, ranges: []const model.RawRange) bool {
    const value: i128 = switch (raw) {
        .unsigned => |number| @intCast(number),
        .signed => |number| number,
        else => return false,
    };
    for (ranges) |range| {
        const minimum = std.fmt.parseInt(i128, range.minimum, 10) catch continue;
        const maximum = std.fmt.parseInt(i128, range.maximum, 10) catch continue;
        if (value >= minimum and value <= maximum) return true;
    }
    return false;
}

fn findSignalIndex(signals: []const can_dbz.compile.SignalPlan, name: []const u8) ?usize {
    for (signals, 0..) |signal, index| if (std.mem.eql(u8, signal.name, name)) return index;
    return null;
}

fn physicalWithinBounds(signal: can_dbz.compile.SignalPlan, value: f64) bool {
    if (signal.minimum) |text| if (value < parseFloatOr(text, -std.math.inf(f64))) return false;
    if (signal.maximum) |text| if (value > parseFloatOr(text, std.math.inf(f64))) return false;
    return true;
}

fn parseFloatOr(text: []const u8, fallback: f64) f64 {
    return std.fmt.parseFloat(f64, text) catch fallback;
}

fn clampIntegerBound(value: f64, minimum: i128, maximum: i128) i128 {
    if (value <= @as(f64, @floatFromInt(minimum))) return minimum;
    if (value >= @as(f64, @floatFromInt(maximum))) return maximum;
    return @intFromFloat(value);
}

fn randomInteger(minimum: i128, maximum: i128, random_state: *u64) i128 {
    const low = @max(minimum, -1_000_000);
    const high = @min(maximum, 1_000_000);
    if (low > high) return if (minimum > 0) minimum else maximum;
    const span: u64 = @intCast(high - low + 1);
    return low + @as(i128, @intCast(nextRandom(random_state) % span));
}

fn nextRandom(state: *u64) u64 {
    state.* ^= state.* << 13;
    state.* ^= state.* >> 7;
    state.* ^= state.* << 17;
    return state.*;
}

test "demo source emits database-shaped classic and FD frames" {
    const allocator = std.testing.allocator;
    const Diagnostics = @import("db/database.zig").Diagnostics;
    const source_text =
        \\VERSION ""
        \\
        \\NS_ :
        \\
        \\BS_:
        \\
        \\BU_: ECU
        \\
        \\BO_ 192 Classic: 8 ECU
        \\ SG_ Value : 0|8@1+ (1,0) [0|255] "" Vector__XXX
        \\ SG_ SoC : 8|16@1+ (0.1,0) [0|100] "%" Vector__XXX
        \\ SG_ Current : 24|16@1- (0.1,0) [-10|10] "A" Vector__XXX
        \\
    ;
    var diagnostics: Diagnostics = .empty;
    defer diagnostics.deinit(allocator);
    var database = try Database.init(allocator, .dbc, source_text, &diagnostics);
    defer database.deinit();

    var queue: rx.FrameQueue = .{};
    const source = try Source.create(allocator, std.testing.io, &database, &queue);
    defer source.stopAndDeinit();
    try std.testing.expectEqual(target_sweep_interval_ns, frameIntervalNs(1));
    try std.testing.expectEqual(@as(u64, 100_000), frameIntervalNs(1000));
    try std.testing.expect(frameIntervalNs(417) * 417 <= target_sweep_interval_ns);
    const frame = source.nextFrame(1234).?;
    try std.testing.expectEqual(@as(u32, 192), frame.id);
    try std.testing.expectEqual(@as(u8, 8), frame.len);
    try std.testing.expect(!frame.flags.fd);
    try std.testing.expectEqual(@as(u64, 1234), frame.timestamp_ns);
    const handle = database.compiled.findMessage("can0", 192, false).?;
    for (0..100) |index| {
        const sample = source.nextFrame(index).?;
        const soc = try database.compiled.decodeSignalPhysical(handle, 1, sample.data[0..sample.len]);
        const current = try database.compiled.decodeSignalPhysical(handle, 2, sample.data[0..sample.len]);
        try std.testing.expect(soc >= 0 and soc <= 100);
        try std.testing.expect(current >= -10 and current <= 10);
        const soc_raw = try database.compiled.decodeSignalRaw(handle, 1, sample.data[0..sample.len]);
        try std.testing.expect(soc_raw == .unsigned and soc_raw.unsigned <= 1000);
    }
}

test "demo source generates bounded values for active multiplexed signals" {
    const allocator = std.testing.allocator;
    const Diagnostics = @import("db/database.zig").Diagnostics;
    const source_text =
        \\{
        \\  "format": "can-db",
        \\  "format_version": 1,
        \\  "buses": [{ "name": "can0" }],
        \\  "messages": [{
        \\    "name": "MuxDemo",
        \\    "bus": "can0",
        \\    "id": "0x123",
        \\    "extended": false,
        \\    "frame": "classic",
        \\    "length": 3,
        \\    "signals": [
        \\      { "name": "Cmd", "start_bit": 0, "bit_length": 2, "byte_order": "little_endian", "type": "unsigned", "minimum": "1", "maximum": "2", "is_multiplexer": true },
        \\      { "name": "Page", "start_bit": 2, "bit_length": 2, "byte_order": "little_endian", "type": "unsigned", "minimum": "0", "maximum": "1", "is_multiplexer": true, "when": [{ "selector": "Cmd", "ranges": [["1", "1"]] }] },
        \\      { "name": "ValueA", "start_bit": 8, "bit_length": 8, "byte_order": "little_endian", "type": "unsigned", "factor": "0.5", "minimum": "0", "maximum": "127.5", "when": [{ "selector": "Cmd", "ranges": [["1", "1"]] }, { "selector": "Page", "ranges": [["0", "0"]] }] },
        \\      { "name": "ValueB", "start_bit": 8, "bit_length": 8, "byte_order": "little_endian", "type": "signed", "factor": "0.1", "minimum": "-12.8", "maximum": "12.7", "when": [{ "selector": "Cmd", "ranges": [["2", "2"]] }] }
        \\    ]
        \\  }]
        \\}
    ;
    var diagnostics: Diagnostics = .empty;
    defer diagnostics.deinit(allocator);
    var database = try Database.init(allocator, .can_json, source_text, &diagnostics);
    defer database.deinit();
    var queue: rx.FrameQueue = .{};
    const source = try Source.create(allocator, std.testing.io, &database, &queue);
    defer source.stopAndDeinit();

    for (0..32) |index| {
        const frame = source.nextFrame(index).?;
        var values: [4]codec.RawValue = undefined;
        var active: [4]bool = undefined;
        var decode_scratch: [4]u8 = undefined;
        try database.compiled.decodeRaw(0, frame.data[0..frame.len], &values, &active, &decode_scratch);
        try std.testing.expectEqualSlices(bool, &.{ true, true, true, false }, &active);
        const value = try database.compiled.decodeSignalPhysical(0, 2, frame.data[0..frame.len]);
        try std.testing.expect(value >= 0 and value <= 127.5);
    }
}
