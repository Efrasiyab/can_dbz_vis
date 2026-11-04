const std = @import("std");
const Index = @import("../log/index.zig").Index;

pub fn barWidth(width: u16) usize {
    if (width < 50) return if (width > 3) width - 3 else 1;
    return @min(@as(usize, width - 44), 80);
}

pub fn timestampAtX(width: u16, x: u16, duration_ns: u64) ?u64 {
    const start_x: u16 = if (width >= 50) 10 else 2;
    if (x < start_x) return null;
    const width_cells = barWidth(width);
    const column = @as(usize, x - start_x);
    if (column >= width_cells) return null;
    if (width_cells <= 1) return 0;
    return @intCast(@as(u128, duration_ns) * column / (width_cells - 1));
}

pub fn render(writer: *std.Io.Writer, width: u16, index: *const Index, position_ns: u64) !void {
    const bar_width = barWidth(width);
    const duration_ns = index.duration_ns;
    const cursor = if (duration_ns == 0)
        0
    else
        @min(@as(usize, @intCast(@as(u128, position_ns) * (bar_width - 1) / duration_ns)), bar_width - 1);

    if (width >= 50) try writer.writeAll("Timeline [") else try writer.writeAll("T[");
    var marker_index: usize = 0;
    for (0..bar_width) |column| {
        const timestamp = if (bar_width <= 1)
            0
        else
            @as(u64, @intCast(@as(u128, duration_ns) * column / (bar_width - 1)));
        while (marker_index < index.markers.items.len) {
            const marker = index.markers.items[marker_index];
            const marker_column = if (duration_ns == 0 or bar_width <= 1)
                0
            else
                @min(@as(usize, @intCast(@as(u128, marker.t_ns) * (bar_width - 1) / duration_ns)), bar_width - 1);
            if (marker_column >= column) break;
            marker_index += 1;
        }
        var marker_here = false;
        while (marker_index < index.markers.items.len) : (marker_index += 1) {
            const marker = index.markers.items[marker_index];
            const marker_column = if (duration_ns == 0 or bar_width <= 1)
                0
            else
                @min(@as(usize, @intCast(@as(u128, marker.t_ns) * (bar_width - 1) / duration_ns)), bar_width - 1);
            if (marker_column != column) break;
            marker_here = true;
        }
        const cell: u8 = if (column == cursor) '>' else if (marker_here) '|' else if (timestamp < position_ns) '=' else '-';
        try writer.writeByte(cell);
    }
    if (width >= 50) {
        try writer.writeAll("] click seek | marker | > cursor\n");
    } else {
        try writer.writeAll("]\n");
    }
}

test "timeline renderer shows cursor and marker ticks" {
    const allocator = std.testing.allocator;
    var index = Index{ .allocator = allocator, .data_offset = 0, .duration_ns = 4 * std.time.ns_per_s };
    defer index.deinit();
    var marker = @import("../log/format.zig").Marker{ .t_ns = 2 * std.time.ns_per_s };
    try marker.text.set("pit");
    try index.markers.append(allocator, .{ .t_ns = marker.t_ns, .byte_offset = 0, .text = marker.text });

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try render(&output.writer, 16, &index, 2 * std.time.ns_per_s);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), ">") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "| marker") != null);
    try std.testing.expectEqual(@as(?u64, 2 * std.time.ns_per_s), timestampAtX(16, 8, index.duration_ns));
    try std.testing.expectEqual(@as(?u64, null), timestampAtX(16, 1, index.duration_ns));
}
