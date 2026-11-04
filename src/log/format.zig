const std = @import("std");
const Frame = @import("../can/frame.zig").Frame;

pub const format_name = "can_dbz_vis/log";
pub const version = 1;
pub const max_buses = 16;
pub const max_line_bytes = 16 * 1024;

pub fn Text(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = @splat(0),
        len: u16 = 0,

        pub fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }

        pub fn set(self: *@This(), value: []const u8) error{TextTooLong}!void {
            if (value.len > capacity) return error.TextTooLong;
            @memset(&self.bytes, 0);
            @memcpy(self.bytes[0..value.len], value);
            self.len = @intCast(value.len);
        }
    };
}

pub const Direction = enum { rx, tx };
pub const TxStatus = enum { ok, queue_full, bus_off, driver_error };
pub const TimestampKind = enum { hardware, software };

pub const Bus = struct {
    index: u8,
    name: Text(64) = .{},
    backend: Text(16) = .{},
    channel: Text(32) = .{},
    bitrate: ?u32 = null,
    data_bitrate: ?u32 = null,
    fd: bool = false,
    timestamps: TimestampKind = .software,
};

pub const DatabaseRef = struct {
    file: Text(128) = .{},
    sha256: Text(64) = .{},
};

pub const Header = struct {
    created_utc: Text(40) = .{},
    tool: Text(64) = .{},
    database: ?DatabaseRef = null,
    buses: [max_buses]Bus = @splat(.{ .index = 0 }),
    bus_count: u8 = 0,
};

pub const FrameRecord = struct {
    t_ns: u64,
    bus: u8,
    direction: Direction,
    frame: Frame,
    status: ?TxStatus = null,
    echo: bool = false,
};

pub const Marker = struct {
    t_ns: u64,
    text: Text(256) = .{},
};

pub const Event = struct {
    t_ns: u64,
    bus: ?u8 = null,
    name: Text(32) = .{},
    value: Text(32) = .{},
    dropped: u64 = 0,
};

pub const Footer = struct {
    t_ns: u64,
    records: u64,
    frames: u64,
    dropped: u64,
};

pub const Record = union(enum) {
    header: Header,
    frame: FrameRecord,
    marker: Marker,
    event: Event,
    footer: Footer,
};

pub fn encode(writer: *std.Io.Writer, record: Record) !void {
    switch (record) {
        .header => |header| try writeHeader(writer, header),
        .frame => |frame| try writeFrame(writer, frame),
        .marker => |marker| {
            try writer.writeAll("{\"type\":\"marker\",\"t_ns\":");
            try writer.print("{d},\"text\":", .{marker.t_ns});
            try writeJsonString(writer, marker.text.slice());
            try writer.writeAll("}\n");
        },
        .event => |event| {
            try writer.writeAll("{\"type\":\"event\",\"t_ns\":");
            try writer.print("{d}", .{event.t_ns});
            if (event.bus) |bus| try writer.print(",\"bus\":{d}", .{bus});
            try writer.writeAll(",\"event\":");
            try writeJsonString(writer, event.name.slice());
            if (event.value.len != 0) {
                try writer.writeAll(",\"state\":");
                try writeJsonString(writer, event.value.slice());
            }
            if (event.dropped != 0) try writer.print(",\"dropped\":{d}", .{event.dropped});
            try writer.writeAll("}\n");
        },
        .footer => |footer| {
            try writer.print("{{\"type\":\"footer\",\"t_ns\":{d},\"records\":{d},\"frames\":{d},\"dropped\":{d}}}\n", .{
                footer.t_ns,
                footer.records,
                footer.frames,
                footer.dropped,
            });
        },
    }
}

fn writeHeader(writer: *std.Io.Writer, header: Header) !void {
    try writer.writeAll("{\"type\":\"header\",\"format\":\"can_dbz_vis/log\",\"version\":1,\"created_utc\":");
    try writeJsonString(writer, header.created_utc.slice());
    try writer.writeAll(",\"tool\":");
    try writeJsonString(writer, header.tool.slice());
    try writer.writeAll(",\"database\":");
    if (header.database) |database| {
        try writer.writeAll("{\"file\":");
        try writeJsonString(writer, database.file.slice());
        try writer.writeAll(",\"sha256\":");
        try writeJsonString(writer, database.sha256.slice());
        try writer.writeByte('}');
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"buses\":[");
    for (header.buses[0..header.bus_count], 0..) |bus, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("{{\"index\":{d},\"name\":", .{bus.index});
        try writeJsonString(writer, bus.name.slice());
        try writer.writeAll(",\"backend\":");
        try writeJsonString(writer, bus.backend.slice());
        try writer.writeAll(",\"channel\":");
        try writeJsonString(writer, bus.channel.slice());
        if (bus.bitrate) |bitrate| try writer.print(",\"bitrate\":{d}", .{bitrate});
        if (bus.data_bitrate) |data_bitrate| try writer.print(",\"data_bitrate\":{d}", .{data_bitrate});
        try writer.print(",\"fd\":{s},\"timestamps\":\"{s}\"}}", .{
            if (bus.fd) "true" else "false",
            @tagName(bus.timestamps),
        });
    }
    try writer.writeAll("]}\n");
}

fn writeFrame(writer: *std.Io.Writer, record: FrameRecord) !void {
    const frame = record.frame;
    if (frame.flags.err) {
        try writer.print("{{\"type\":\"error_frame\",\"t_ns\":{d},\"bus\":{d},\"class\":\"bus_error\",\"data\":\"", .{ record.t_ns, record.bus });
        for (frame.data[0..frame.len]) |byte| try writer.print("{X:0>2}", .{byte});
        try writer.writeAll("\"}\n");
        return;
    }
    try writer.print("{{\"type\":\"frame\",\"t_ns\":{d},\"bus\":{d},\"dir\":\"{s}\",\"id\":\"{X}\"", .{
        record.t_ns,
        record.bus,
        @tagName(record.direction),
        frame.id,
    });
    if (frame.flags.extended) try writer.writeAll(",\"ext\":true");
    if (frame.flags.fd) try writer.writeAll(",\"fd\":true");
    if (frame.flags.brs) try writer.writeAll(",\"brs\":true");
    if (frame.flags.esi) try writer.writeAll(",\"esi\":true");
    if (frame.flags.rtr) try writer.writeAll(",\"rtr\":true");
    if (frame.flags.tx_echo or record.echo) try writer.writeAll(",\"echo\":true");
    try writer.print(",\"len\":{d},\"data\":\"", .{if (frame.flags.rtr) 0 else frame.len});
    if (!frame.flags.rtr) {
        for (frame.data[0..frame.len]) |byte| try writer.print("{X:0>2}", .{byte});
    }
    try writer.writeByte('"');
    if (record.status) |status| {
        try writer.writeAll(",\"status\":");
        try writeJsonString(writer, switch (status) {
            .driver_error => "error",
            else => @tagName(status),
        });
    }
    try writer.writeAll("}\n");
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0...8, 11, 12, 14...0x1f => try writer.print("\\u00{x:0>2}", .{byte}),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

pub fn decodeLine(line: []const u8) !?Record {
    if (line.len == 0 or line.len > max_line_bytes) return error.InvalidLine;
    var scratch: [max_line_bytes * 4]u8 = undefined;
    var fixed_allocator = std.heap.FixedBufferAllocator.init(&scratch);
    const parsed = std.json.parseFromSlice(std.json.Value, fixed_allocator.allocator(), line, .{ .allocate = .alloc_always }) catch return error.InvalidJson;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidRecord,
    };
    const type_value = stringField(object, "type") orelse return error.MissingType;

    if (std.mem.eql(u8, type_value, "header")) return .{ .header = try decodeHeader(object) };
    if (std.mem.eql(u8, type_value, "frame")) return .{ .frame = try decodeFrame(object) };
    if (std.mem.eql(u8, type_value, "error_frame")) return .{ .frame = try decodeErrorFrame(object) };
    if (std.mem.eql(u8, type_value, "marker")) return .{ .marker = try decodeMarker(object) };
    if (std.mem.eql(u8, type_value, "event")) return .{ .event = try decodeEvent(object) };
    if (std.mem.eql(u8, type_value, "footer")) return .{ .footer = .{
        .t_ns = uintField(object, "t_ns") orelse return error.InvalidRecord,
        .records = uintField(object, "records") orelse return error.InvalidRecord,
        .frames = uintField(object, "frames") orelse return error.InvalidRecord,
        .dropped = uintField(object, "dropped") orelse return error.InvalidRecord,
    } };
    return null;
}

fn decodeHeader(object: std.json.ObjectMap) !Header {
    if (!std.mem.eql(u8, stringField(object, "format") orelse return error.InvalidRecord, format_name)) return error.InvalidRecord;
    if ((uintField(object, "version") orelse return error.InvalidRecord) != version) return error.UnsupportedVersion;
    var result = Header{};
    try result.created_utc.set(stringField(object, "created_utc") orelse return error.InvalidRecord);
    try result.tool.set(stringField(object, "tool") orelse return error.InvalidRecord);

    if (object.get("database")) |database_value| switch (database_value) {
        .null => {},
        .object => |database_object| {
            var database: DatabaseRef = .{};
            try database.file.set(stringField(database_object, "file") orelse "");
            try database.sha256.set(stringField(database_object, "sha256") orelse "");
            result.database = database;
        },
        else => return error.InvalidRecord,
    };

    const buses_value = object.get("buses") orelse return error.InvalidRecord;
    const buses = switch (buses_value) {
        .array => |value| value.items,
        else => return error.InvalidRecord,
    };
    if (buses.len > max_buses) return error.TooManyBuses;
    for (buses, 0..) |bus_value, index| {
        const bus_object = switch (bus_value) {
            .object => |value| value,
            else => return error.InvalidRecord,
        };
        var bus = Bus{ .index = @intCast(uintField(bus_object, "index") orelse index) };
        try bus.name.set(stringField(bus_object, "name") orelse return error.InvalidRecord);
        try bus.backend.set(stringField(bus_object, "backend") orelse "");
        try bus.channel.set(stringField(bus_object, "channel") orelse "");
        bus.bitrate = if (uintField(bus_object, "bitrate")) |value| std.math.cast(u32, value) else null;
        bus.data_bitrate = if (uintField(bus_object, "data_bitrate")) |value| std.math.cast(u32, value) else null;
        bus.fd = boolField(bus_object, "fd") orelse false;
        bus.timestamps = if (std.mem.eql(u8, stringField(bus_object, "timestamps") orelse "software", "hardware")) .hardware else .software;
        result.buses[index] = bus;
    }
    result.bus_count = @intCast(buses.len);
    return result;
}

fn decodeFrame(object: std.json.ObjectMap) !FrameRecord {
    const data_hex = stringField(object, "data") orelse return error.InvalidRecord;
    const length = uintField(object, "len") orelse return error.InvalidRecord;
    if (length > 64 or data_hex.len != length * 2) return error.InvalidFrameData;
    const id_text = stringField(object, "id") orelse return error.InvalidRecord;
    var frame = Frame{
        .timestamp_ns = uintField(object, "t_ns") orelse return error.InvalidRecord,
        .id = std.fmt.parseInt(u32, id_text, 16) catch return error.InvalidRecord,
        .bus = @intCast(uintField(object, "bus") orelse return error.InvalidRecord),
        .len = @intCast(length),
        .flags = .{
            .extended = boolField(object, "ext") orelse false,
            .fd = boolField(object, "fd") orelse false,
            .brs = boolField(object, "brs") orelse false,
            .esi = boolField(object, "esi") orelse false,
            .rtr = boolField(object, "rtr") orelse false,
            .tx_echo = boolField(object, "echo") orelse false,
        },
        ._pad = 0,
        .data = @splat(0),
    };
    for (0..length) |index| frame.data[index] = std.fmt.parseInt(u8, data_hex[index * 2 .. index * 2 + 2], 16) catch return error.InvalidFrameData;
    const direction = stringField(object, "dir") orelse return error.InvalidRecord;
    const decoded_direction = if (std.mem.eql(u8, direction, "rx")) Direction.rx else if (std.mem.eql(u8, direction, "tx")) Direction.tx else return error.InvalidRecord;
    const status = if (stringField(object, "status")) |name| try parseStatus(name) else null;
    return .{
        .t_ns = frame.timestamp_ns,
        .bus = frame.bus,
        .direction = decoded_direction,
        .frame = frame,
        .status = status,
        .echo = frame.flags.tx_echo,
    };
}

fn decodeErrorFrame(object: std.json.ObjectMap) !FrameRecord {
    const data_hex = stringField(object, "data") orelse return error.InvalidRecord;
    if (data_hex.len % 2 != 0 or data_hex.len > 128) return error.InvalidFrameData;
    var frame = Frame{
        .timestamp_ns = uintField(object, "t_ns") orelse return error.InvalidRecord,
        .id = 0,
        .bus = @intCast(uintField(object, "bus") orelse return error.InvalidRecord),
        .len = @intCast(data_hex.len / 2),
        .flags = .{ .err = true },
        ._pad = 0,
        .data = @splat(0),
    };
    for (0..frame.len) |index| frame.data[index] = std.fmt.parseInt(u8, data_hex[index * 2 .. index * 2 + 2], 16) catch return error.InvalidFrameData;
    return .{ .t_ns = frame.timestamp_ns, .bus = frame.bus, .direction = .rx, .frame = frame };
}

fn decodeMarker(object: std.json.ObjectMap) !Marker {
    var marker = Marker{ .t_ns = uintField(object, "t_ns") orelse return error.InvalidRecord };
    try marker.text.set(stringField(object, "text") orelse return error.InvalidRecord);
    return marker;
}

fn decodeEvent(object: std.json.ObjectMap) !Event {
    var event = Event{ .t_ns = uintField(object, "t_ns") orelse return error.InvalidRecord };
    if (uintField(object, "bus")) |bus| event.bus = @intCast(bus);
    try event.name.set(stringField(object, "event") orelse return error.InvalidRecord);
    try event.value.set(stringField(object, "state") orelse "");
    event.dropped = uintField(object, "dropped") orelse 0;
    return event;
}

fn parseStatus(value: []const u8) error{InvalidRecord}!TxStatus {
    if (std.mem.eql(u8, value, "ok")) return .ok;
    if (std.mem.eql(u8, value, "queue_full")) return .queue_full;
    if (std.mem.eql(u8, value, "bus_off")) return .bus_off;
    if (std.mem.eql(u8, value, "error") or std.mem.eql(u8, value, "driver_error")) return .driver_error;
    return error.InvalidRecord;
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn uintField(object: std.json.ObjectMap, name: []const u8) ?u64 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        else => null,
    };
}

fn boolField(object: std.json.ObjectMap, name: []const u8) ?bool {
    const value = object.get(name) orelse return null;
    return if (value == .bool) value.bool else null;
}

test "frame JSONL encoding and decoding round-trip CAN FD data" {
    const frame = Frame{
        .timestamp_ns = 0,
        .id = 0x18ff50e5,
        .bus = 1,
        .len = 12,
        .flags = .{ .extended = true, .fd = true, .brs = true },
        ._pad = 0,
        .data = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 } ++ @as([52]u8, @splat(0)),
    };
    const record = Record{ .frame = .{ .t_ns = 1234, .bus = 1, .direction = .tx, .frame = frame, .status = .ok } };
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try encode(&writer, record);
    const decoded = (try decodeLine(writer.buffered())) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Record.frame, std.meta.activeTag(decoded));
    try std.testing.expectEqual(@as(u64, 1234), decoded.frame.t_ns);
    try std.testing.expectEqual(frame.id, decoded.frame.frame.id);
    try std.testing.expect(decoded.frame.frame.flags.fd and decoded.frame.frame.flags.brs);
    try std.testing.expectEqualSlices(u8, frame.data[0..12], decoded.frame.frame.data[0..12]);
}

test "decoder ignores unknown fields and unknown record types" {
    const line = "{\"type\":\"frame\",\"t_ns\":1,\"bus\":0,\"dir\":\"rx\",\"id\":\"123\",\"len\":1,\"data\":\"AA\",\"future\":true}";
    const decoded = (try decodeLine(line)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 0x123), decoded.frame.frame.id);
    try std.testing.expect((try decodeLine("{\"type\":\"future_record\",\"value\":1}")) == null);
}
