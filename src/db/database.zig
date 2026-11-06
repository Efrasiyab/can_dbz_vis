const std = @import("std");
const can_dbz = @import("can_dbz");

pub const Format = enum { dbc, can_json };

pub const max_file_size = 64 * 1024 * 1024;

pub const Diagnostics = std.ArrayListUnmanaged(can_dbz.diagnostic.Diagnostic);

pub fn detectFormat(path: []const u8) ?Format {
    if (std.ascii.endsWithIgnoreCase(path, ".dbc")) return .dbc;
    if (std.ascii.endsWithIgnoreCase(path, ".json")) return .can_json;
    return null;
}

/// Parsed and compiled CAN database. `source` must outlive it: the DBC parser borrows from the input.
pub const Database = struct {
    doc: can_dbz.model.Document,
    compiled: can_dbz.compile.CompiledDatabase,
    format: Format,
    source_allocator: std.mem.Allocator,
    owned_source: ?[]u8 = null,

    pub const Error = error{ OutOfMemory, ParseFailed, CompileFailed };

    /// On `ParseFailed`, `diags` explains why; its slices may point into `source`.
    pub fn init(gpa: std.mem.Allocator, format: Format, source: []const u8, diags: *Diagnostics) Error!Database {
        var owned_source: ?[]u8 = null;
        errdefer if (owned_source) |bytes| gpa.free(bytes);
        const dbc_timing = if (format == .dbc) findDbcBusTiming(source) else null;
        const parse_source = if (dbc_timing) |timing| blk: {
            const bytes = gpa.dupe(u8, source) catch return error.OutOfMemory;
            owned_source = bytes;
            @memset(bytes[timing.line_start..timing.line_end], ' ');
            @memcpy(bytes[timing.line_start .. timing.line_start + 4], "BS_:");
            break :blk bytes;
        } else source;
        var doc = switch (format) {
            .can_json => can_dbz.formats.can_json.parseWithDiagnostics(gpa, source, diags),
            .dbc => can_dbz.formats.dbc.parse(gpa, parse_source, diags),
        } catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.ParseFailed,
        };
        errdefer doc.deinit();
        if (dbc_timing) |timing| {
            if (doc.buses.items.len > 0) doc.buses.items[0].nominal_bitrate = timing.nominal_bitrate;
        }

        const compiled = can_dbz.compile.compile(&doc, gpa) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.CompileFailed,
        };
        return .{
            .doc = doc,
            .compiled = compiled,
            .format = format,
            .source_allocator = gpa,
            .owned_source = owned_source,
        };
    }

    pub fn deinit(self: *Database) void {
        self.compiled.deinit();
        self.doc.deinit();
        if (self.owned_source) |bytes| self.source_allocator.free(bytes);
        self.* = undefined;
    }

    pub fn writeSummary(self: *const Database, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const doc = &self.doc;
        try w.print("database: {s} ({s}), {d} bus(es), {d} message(s)\n", .{
            doc.name orelse "<unnamed>",
            @tagName(self.format),
            doc.buses.items.len,
            self.compiled.messages.len,
        });
        for (doc.buses.items) |bus| {
            var count: usize = 0;
            for (self.compiled.messages) |m| {
                if (std.mem.eql(u8, m.bus, bus.name)) count += 1;
            }
            try w.print("  bus {s}: {d} message(s)", .{ bus.name, count });
            if (bus.nominal_bitrate) |rate| try w.print(", {d} bit/s", .{rate});
            if (bus.data_bitrate) |rate| try w.print(", data {d} bit/s", .{rate});
            try w.writeByte('\n');
            for (self.compiled.messages) |m| {
                if (!std.mem.eql(u8, m.bus, bus.name)) continue;
                if (m.extended) {
                    try w.print("    0x{X:0>8}", .{m.id});
                } else {
                    try w.print("    0x{X:0>3}     ", .{m.id});
                }
                try w.print(" {s} len {d}{s}, {d} signal(s)\n", .{
                    m.name,
                    m.length,
                    if (m.frame == .fd) " FD" else "",
                    m.signals.len,
                });
            }
        }
    }
};

const DbcBusTiming = struct {
    line_start: usize,
    line_end: usize,
    nominal_bitrate: u32,
};

fn findDbcBusTiming(source: []const u8) ?DbcBusTiming {
    var line_start: usize = 0;
    while (line_start < source.len) {
        const relative_end = std.mem.indexOfScalar(u8, source[line_start..], '\n') orelse source.len - line_start;
        const line_end = line_start + relative_end;
        const line = std.mem.trimStart(u8, source[line_start..line_end], " \t\r");
        if (std.mem.startsWith(u8, line, "BS_:")) {
            const raw_bitrate = std.mem.trimStart(u8, line[4..], " \t");
            const token_end = std.mem.indexOfAny(u8, raw_bitrate, " \t:;\r") orelse raw_bitrate.len;
            const bitrate = std.fmt.parseInt(u32, raw_bitrate[0..token_end], 10) catch return null;
            if (bitrate == 0) return null;
            return .{
                .line_start = line_start,
                .line_end = line_end,
                .nominal_bitrate = bitrate,
            };
        }
        if (relative_end == source.len - line_start) break;
        line_start = line_end + 1;
    }
    return null;
}

pub fn writeDiagnostics(w: *std.Io.Writer, diags: []const can_dbz.diagnostic.Diagnostic) std.Io.Writer.Error!void {
    for (diags) |d| {
        try w.print("{s}: {s} ({s})", .{ @tagName(d.severity), d.message, @tagName(d.code) });
        switch (d.source) {
            .none => {},
            .json_pointer => |p| try w.print(" at {s}", .{p}),
            .dbc => |loc| try w.print(" at line {d}, column {d}", .{ loc.line, loc.column }),
        }
        if (d.context.bus) |v| try w.print(" bus={s}", .{v});
        if (d.context.message) |v| try w.print(" message={s}", .{v});
        if (d.context.signal) |v| try w.print(" signal={s}", .{v});
        try w.writeByte('\n');
    }
}

const test_dbc =
    \\VERSION ""
    \\
    \\NS_ :
    \\
    \\BS_: 250000 : 0 : 0 : 0 : 0
    \\
    \\BU_: ECU
    \\
    \\BO_ 192 EngineData: 8 ECU
    \\ SG_ RPM : 0|16@1+ (0.25,0) [0|16383.75] "rpm" Vector__XXX
    \\ SG_ CoolantTemp : 16|8@1+ (1,-40) [-40|215] "degC" Vector__XXX
    \\
    \\BO_ 2566869221 Aftertreatment: 8 ECU
    \\ SG_ Level : 0|8@1+ (0.4,0) [0|100] "%" Vector__XXX
    \\
;

const test_json =
    \\{
    \\  "format": "can-db",
    \\  "format_version": 1,
    \\  "name": "Example",
    \\  "buses": [ { "name": "can0" } ],
    \\  "messages": []
    \\}
;

test "detectFormat" {
    try std.testing.expectEqual(Format.dbc, detectFormat("a/b/Vehicle.DBC").?);
    try std.testing.expectEqual(Format.can_json, detectFormat("vehicle.can.json").?);
    try std.testing.expectEqual(@as(?Format, null), detectFormat("vehicle.txt"));
}

test "load DBC and decode a frame" {
    const gpa = std.testing.allocator;
    var diags: Diagnostics = .empty;
    defer diags.deinit(gpa);

    var db = try Database.init(gpa, .dbc, test_dbc, &diags);
    defer db.deinit();
    try std.testing.expectEqual(@as(?u32, 250_000), db.doc.buses.items[0].nominal_bitrate);

    const handle = db.compiled.findMessage("can0", 192, false) orelse return error.TestUnexpectedResult;
    const payload = [_]u8{ 0x10, 0x27, 0x80, 0, 0, 0, 0, 0 };
    try std.testing.expectApproxEqAbs(@as(f64, 2500.0), try db.compiled.decodeSignalPhysical(handle, 0, &payload), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 88.0), try db.compiled.decodeSignalPhysical(handle, 1, &payload), 1e-9);
    try std.testing.expect(db.compiled.findMessage("can0", 0x18FF50E5, true) != null);

    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try db.writeSummary(&w);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "0x0C0") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "0x18FF50E5") != null);
}

test "load CAN JSON" {
    const gpa = std.testing.allocator;
    var diags: Diagnostics = .empty;
    defer diags.deinit(gpa);

    var db = try Database.init(gpa, .can_json, test_json, &diags);
    defer db.deinit();
    try std.testing.expectEqual(@as(usize, 1), db.doc.buses.items.len);
    try std.testing.expectEqualStrings("Example", db.doc.name.?);
}

test "invalid input reports diagnostics" {
    const gpa = std.testing.allocator;
    var diags: Diagnostics = .empty;
    defer diags.deinit(gpa);

    try std.testing.expectError(error.ParseFailed, Database.init(gpa, .can_json, "{\"format\":\"nope\"}", &diags));
    try std.testing.expect(diags.items.len > 0);
}
