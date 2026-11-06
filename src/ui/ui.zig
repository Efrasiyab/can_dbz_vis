const std = @import("std");
const zz = @import("zigzag");
const adapter = @import("../can/adapter.zig");
const registry = @import("../can/registry.zig");
const Database = @import("../db/database.zig").Database;
const Engine = @import("../engine/engine.zig").Engine;
const store = @import("../engine/store.zig");
const config = @import("config.zig");
const connect = @import("connect.zig");
const keymap = @import("../keymap.zig");
const monitor = @import("monitor.zig");
const transmit = @import("transmit.zig");
const tx = @import("../engine/tx.zig");
const plot_ui = @import("plot.zig");
const timeline = @import("timeline.zig");
const engine_plot = @import("../engine/plot.zig");
const log_format = @import("../log/format.zig");
const clock = @import("../sync/clock.zig");
const ReplaySource = @import("../log/replay.zig").ReplaySource;
const DemoSource = @import("../demo.zig").Source;

pub const Tab = enum(u8) { monitor, transmit, sent, plot, pinned };
const Overlay = enum { none, help, connect };

pub const App = struct {
    database: *Database,
    engine: *Engine,
    allocator: std.mem.Allocator,
    io: std.Io,
    config_directory: []const u8,
    database_file: []const u8,
    log_path: ?[]const u8 = null,
    default_log_path: ?[]u8 = null,
    replay_source: ?*ReplaySource = null,
    demo_source: ?*DemoSource = null,
    database_hash: [64]u8,
    settings: config.Settings = .{},
    program_options: ?*zz.Options = null,
    pins: config.PinSet = .{},
    monitor: monitor.State = .{},
    pinned_selected: usize = 0,
    pinned_scroll: usize = 0,
    pinned_horizontal_scroll: usize = 0,
    transmit: transmit.State = .{},
    plot: plot_ui.State = .{},
    pin_picker: plot_ui.State = .{},
    plot_config: engine_plot.Config = .{},
    plot_samples: engine_plot.SampleQueue = .{},
    plot_worker: ?*engine_plot.Worker = null,
    frozen_plot_snapshot: engine_plot.Snapshot = .{},
    connect: connect.Dialog = .{},
    active_tab: Tab = .monitor,
    overlay: Overlay = .none,
    paused: bool = false,
    frozen_snapshot: store.Snapshot = .{},
    pins_loaded: bool = false,
    pins_dirty: bool = false,
    last_pin_change_ns: u64 = 0,
    plots_loaded: bool = false,
    plots_dirty: bool = false,
    last_plot_change_ns: u64 = 0,
    settings_dirty: bool = false,
    last_settings_change_ns: u64 = 0,
    notice: []const u8 = "",

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
        mouse: zz.MouseEvent,
        tick: struct { timestamp: u64, delta: u64 },
    };

    const Cmd = zz.Cmd(Msg);

    pub fn init(self: *App, _: *zz.Context) !Cmd {
        self.transmit.ensureMessage(self.database);
        self.plot.window_seconds = self.settings.plot_window_seconds;
        const default_window_ns = @as(u64, self.plot.window_seconds) * std.time.ns_per_s;
        self.plot.plot_windows_ns = @splat(default_window_ns);
        self.plot_config.setWindow(default_window_ns);
        self.plot.running = false;
        self.plot_config.setSamplingEnabled(false);
        self.engine.attachPlot(&self.plot_config, &self.plot_samples, &self.database.compiled);
        self.plot_worker = try engine_plot.Worker.create(self.allocator, self.io, &self.plot_config, &self.plot_samples);
        self.plot_worker.?.start() catch |err| {
            self.plot_worker.?.stopAndDeinit();
            self.plot_worker = null;
            return err;
        };
        if (self.replay_source) |replay| replay.attachPlotWorker(self.plot_worker.?);
        self.pins = config.loadPins(self.allocator, self.io, self.config_directory, &self.database_hash, self.database) catch |err| {
            self.notice = @errorName(err);
            return Cmd.everyMs(33);
        };
        self.pins_loaded = true;
        const saved_plots = config.loadPlots(self.allocator, self.io, self.config_directory, &self.database_hash, self.database) catch |err| {
            self.notice = @errorName(err);
            return Cmd.everyMs(33);
        };
        self.plot.plot_count = saved_plots.plot_count;
        self.plot.plot_windows_ns = saved_plots.plot_windows_ns;
        self.plot.columns_override = saved_plots.columns_override;
        for (0..saved_plots.plot_count) |plot_index| self.plot_config.setPlotWindow(plot_index, saved_plots.plot_windows_ns[plot_index]);
        for (saved_plots.items[0..saved_plots.len]) |maybe_plot| {
            const saved = maybe_plot.?;
            self.plot.selected_message = saved.message;
            self.plot.selected_signal = saved.signal;
            self.plot.addSelectedToPlot(self.database, &self.plot_config, saved.plot_index);
        }
        self.plot.notice = "";
        self.plot.publishConfig(&self.plot_config);
        self.plots_loaded = true;
        if (self.log_path) |path| self.startRecording(path);
        if (self.replay_source) |replay| replay.play();
        return Cmd.everyMs(33);
    }

    pub fn update(self: *App, message: Msg, ctx: *zz.Context) Cmd {
        switch (message) {
            .tick => {
                if (self.pins_dirty and ctx.elapsed -| self.last_pin_change_ns >= std.time.ns_per_s) self.persistPins();
                if (self.plots_dirty and ctx.elapsed -| self.last_plot_change_ns >= std.time.ns_per_s) self.persistPlots();
                if (self.settings_dirty and ctx.elapsed -| self.last_settings_change_ns >= std.time.ns_per_s) self.persistSettings();
                self.plot_config.setChartWidth(ctx.width -| 20);
            },
            .key => |event| {
                if (self.handleKey(event, ctx)) return .quit;
            },
            .mouse => |event| self.handleMouse(event, ctx),
        }
        return .none;
    }

    pub fn view(self: *const App, ctx: *const zz.Context) ![]const u8 {
        var output: std.Io.Writer.Allocating = .init(ctx.allocator);
        const writer = &output.writer;
        const database_name = self.database.doc.name orelse "CAN database";
        try writeStyled(writer, ctx.allocator, "can_dbz_vis", (zz.Style{}).fg(zz.Color.brightCyan).bold(true).inline_style(true));
        try writeStyled(writer, ctx.allocator, "  ", (zz.Style{}).inline_style(true));
        try writeStyled(writer, ctx.allocator, self.database_file, (zz.Style{}).fg(zz.Color.brightWhite).bold(true).inline_style(true));
        if (!std.mem.eql(u8, self.database_file, database_name)) {
            try writeStyled(writer, ctx.allocator, "  |  ", (zz.Style{}).fg(zz.Color.gray(13)).inline_style(true));
            try writeStyled(writer, ctx.allocator, database_name, (zz.Style{}).fg(zz.Color.gray(15)).inline_style(true));
        }
        try writer.writeByte('\n');
        try self.renderTabBar(writer, ctx.allocator, ctx.width);
        try self.renderTabDescription(writer, ctx.allocator);
        if (self.replay_source) |replay| {
            if (replay.indexData()) |index| {
                try timeline.render(writer, ctx.width, index, replay.position_ns.load(.acquire));
            } else {
                try writer.writeAll("Timeline [indexing... click to seek when ready]\n");
            }
        }
        if (self.notice.len != 0) {
            try writeStyled(writer, ctx.allocator, self.notice, (zz.Style{}).fg(zz.Color.brightYellow).inline_style(true));
            try writer.writeByte('\n');
        }
        if (self.replay_source) |replay| {
            const progress = replay.indexProgress();
            if (replay.indexData()) |index| {
                try writer.print("Replay {d:.2}x  t={d}/{d} ns  frames={d}  markers={d}  bad lines={d}{s}\n", .{
                    @as(f64, @floatFromInt(replay.speedMilli())) / 1000,
                    replay.position_ns.load(.acquire),
                    index.duration_ns,
                    replay.frames_played.load(.monotonic),
                    index.markers.items.len,
                    index.malformed_lines,
                    if (replay.eof.load(.acquire)) " EOF" else "",
                });
            } else if (progress.failed) {
                try writer.writeAll("Replay index failed; forward playback remains available\n");
            } else if (progress.total != 0) {
                try writer.print("Indexing replay {d:.0}%\n", .{@as(f64, @floatFromInt(progress.scanned)) * 100 / @as(f64, @floatFromInt(progress.total))});
            } else {
                try writer.writeAll("Indexing replay...\n");
            }
        }
        if (self.replay_source == null and self.demo_source == null) {
            for (self.database.doc.buses.items, 0..) |bus, index| {
                const status = self.engine.channelStatus(@intCast(index)) orelse continue;
                switch (status) {
                    .bus_off => try writer.print("Recovery: {s} is bus-off; recover the controller, then press c to reconnect\n", .{bus.name}),
                    .disconnected => try writer.print("Recovery: {s} is disconnected; check the channel, then press c to reconnect\n", .{bus.name}),
                    else => {},
                }
            }
        }
        const view_start = writer.buffered().len;
        const prefix_rows = countLines(writer.buffered());
        const view_height = @max(@as(usize, 1), @as(usize, ctx.height) -| prefix_rows -| 3);
        const live_snapshot = self.engine.readSnapshot();
        const snapshot = if (self.paused) &self.frozen_snapshot else &live_snapshot;
        const live_plot_snapshot = self.plot_worker.?.readSnapshot();
        const plot_snapshot = if (self.paused) &self.frozen_plot_snapshot else &live_plot_snapshot;
        switch (self.overlay) {
            .help => try self.renderHelp(writer),
            .connect => try self.renderConnect(writer),
            .none => switch (self.active_tab) {
                .monitor => try monitor.render(ctx.allocator, writer, ctx.width, @intCast(view_height), self.database, snapshot, &self.monitor, &self.pins),
                .transmit => if (self.replay_source != null or self.demo_source != null)
                    try writer.writeAll(if (self.replay_source != null) "Transmit is disabled in replay mode\n" else "Transmit is disabled in demo mode\n")
                else
                    try transmit.render(writer, self.database, &self.transmit, self.engine.started, self.engine.activeTxJobs()),
                .sent => try self.renderSent(ctx.allocator, writer, snapshot),
                .plot => if (self.plot.window_edit_active)
                    try plot_ui.render(ctx.allocator, writer, ctx.width, @intCast(view_height), self.database, &self.plot, plot_snapshot)
                else if (self.plot.picker_open)
                    try plot_ui.renderPicker(ctx.allocator, writer, ctx.width, @intCast(view_height), self.database, &self.plot, .plot, null)
                else
                    try plot_ui.render(ctx.allocator, writer, ctx.width, @intCast(view_height), self.database, &self.plot, plot_snapshot),
                .pinned => if (self.pin_picker.picker_open) {
                    try plot_ui.renderPicker(ctx.allocator, writer, ctx.width, @intCast(view_height), self.database, &self.pin_picker, .pins, &self.pins);
                } else {
                    try writeStyled(writer, ctx.allocator, "Pinned messages and signals", (zz.Style{}).fg(zz.Color.brightGreen).bold(true).inline_style(true));
                    try writeStyled(writer, ctx.allocator, "  ↑/↓ select  PgUp/PgDn scroll  ←/→ value  p signals  x unpin", (zz.Style{}).fg(zz.Color.gray(14)).inline_style(true));
                    try writer.writeByte('\n');
                    if (self.pins.len == 0) {
                        try writeStyled(writer, ctx.allocator, "No pinned signals yet. Press p on a selected message or signal.", (zz.Style{}).fg(zz.Color.gray(15)).inline_style(true));
                        try writer.writeByte('\n');
                    } else {
                        try monitor.renderPins(ctx.allocator, writer, ctx.width, self.database, snapshot, &self.pins, self.pinned_selected, self.pinned_scroll, view_height -| 3, self.pinned_horizontal_scroll);
                    }
                },
            },
        }
        const view_rows = countLines(writer.buffered()[view_start..]);
        if (view_rows < view_height) {
            for (view_rows..view_height) |_| try writer.writeByte('\n');
        }
        try self.renderFooter(writer, ctx.allocator);
        return writer.buffered();
    }

    fn renderTabBar(self: *const App, writer: *std.Io.Writer, allocator: std.mem.Allocator, width: u16) !void {
        const compact = width < 60;
        const tabs = [_]struct { tab: Tab, label: []const u8, compact_label: []const u8 }{
            .{ .tab = .monitor, .label = "1 Monitor", .compact_label = "1 Mon" },
            .{ .tab = .transmit, .label = "2 TX", .compact_label = "2 TX" },
            .{ .tab = .sent, .label = "3 Sent", .compact_label = "3 Sent" },
            .{ .tab = .plot, .label = "4 Plot", .compact_label = "4 Plot" },
            .{ .tab = .pinned, .label = "5 Pins", .compact_label = "5 Pins" },
        };
        for (tabs, 0..) |item, index| {
            const active = item.tab == self.active_tab;
            const style = if (active)
                (zz.Style{}).fg(zz.Color.brightWhite).bg(zz.Color.color256(24)).bold(true).inline_style(true)
            else
                (zz.Style{}).fg(zz.Color.gray(15)).inline_style(true);
            try writeStyled(writer, allocator, if (compact) item.compact_label else item.label, style);
            if (index + 1 != tabs.len) {
                try writeStyled(writer, allocator, "  |  ", (zz.Style{}).fg(zz.Color.color256(60)).inline_style(true));
            }
        }
        try writer.writeByte('\n');
    }

    fn renderTabDescription(self: *const App, writer: *std.Io.Writer, allocator: std.mem.Allocator) !void {
        const description = switch (self.active_tab) {
            .monitor => "Monitor: traffic by bus and signal detail",
            .transmit => "Transmit: one-shot and periodic sends",
            .sent => "Sent: driver-accepted transmissions",
            .plot => "Plot: selected signal histories",
            .pinned => "Pins: saved messages and signals",
        };
        try writeStyled(writer, allocator, description, (zz.Style{}).fg(zz.Color.gray(15)).inline_style(true));
        try writer.writeByte('\n');
        try writeStyled(writer, allocator, "--------------------------------------------------------------------------", (zz.Style{}).fg(zz.Color.color256(238)).inline_style(true));
        try writer.writeByte('\n');
    }

    fn renderFooter(self: *const App, writer: *std.Io.Writer, allocator: std.mem.Allocator) !void {
        const mode = if (self.replay_source != null) "REPLAY" else if (self.demo_source != null) "DEMO" else if (self.engine.started) "CONNECTED" else "DISCONNECTED";
        const mode_color = if (self.replay_source != null or self.demo_source != null) zz.Color.brightCyan else if (self.engine.started) zz.Color.brightGreen else zz.Color.gray(13);
        try writer.writeByte('\n');
        try writeStyled(writer, allocator, mode, (zz.Style{}).fg(mode_color).bold(true).inline_style(true));
        try writer.print("  |  FPS {d}  |  RX {d}  |  drops {d}{s}\n", .{
            self.settings.fps,
            self.engine.framesRead(),
            self.engine.droppedCount(),
            if (self.engine.isLogging()) "  |  REC" else "",
        });
        const hints = switch (self.active_tab) {
            .monitor => "↑↓ move | → signals | b bus | p pin | / filter | c connect | L log | m mark",
            .transmit => "Arrows select | +/- value | Enter send | m periodic | s start | x stop",
            .sent => "Driver accepted does not mean bus ACK; inspect a bus capture",
            .plot => if (self.plot.layout_edit_active) "Type columns (0=Auto) | Enter apply | Esc cancel" else if (self.plot.window_edit_active) "Type milliseconds | Enter apply | Esc cancel" else if (self.plot.assignment_signal != null) "←/→ choose plot | Enter assign | Esc cancel" else if (self.plot.picker_open) "↑↓ move | ←→ fold | Tab choose plot | Enter close" else "l layout | [/] chart | w window | i inspect/click | s start/stop | p signals | x remove",
            .pinned => if (self.pin_picker.picker_open) "↑↓ move | ←→ fold | Tab pin/unpin | Enter close" else "↑↓ select | PgUp/PgDn scroll | ←→ value | p signals | x unpin",
        };
        try writeStyled(writer, allocator, hints, (zz.Style{}).fg(zz.Color.color256(110)).inline_style(true));
        try writer.writeByte('\n');
    }

    fn countLines(text: []const u8) usize {
        var count: usize = 0;
        for (text) |character| {
            if (character == '\n') count += 1;
        }
        if (text.len != 0 and text[text.len - 1] != '\n') count += 1;
        return count;
    }

    pub fn deinit(self: *App) void {
        if (self.replay_source) |replay| replay.stop();
        if (self.demo_source) |demo| demo.stop();
        self.engine.stop();
        self.engine.stopLogging();
        if (self.plot_worker) |worker| {
            worker.stopAndDeinit();
            self.plot_worker = null;
        }
        if (self.pins_loaded or self.pins_dirty) self.persistPins();
        if (self.plots_loaded or self.plots_dirty) self.persistPlots();
        if (self.settings_dirty) self.persistSettings();
        if (self.default_log_path) |path| self.allocator.free(path);
        self.plot.deinit(self.allocator);
        self.pin_picker.deinit(self.allocator);
    }

    fn handleKey(self: *App, event: zz.KeyEvent, ctx: *zz.Context) bool {
        if (self.overlay == .help) {
            self.overlay = .none;
            return false;
        }
        if (self.overlay == .connect) {
            self.handleConnectKey(event, ctx);
            return false;
        }
        if (self.monitor.filter_active) {
            self.handleFilterKey(event);
            return false;
        }
        if (self.demo_source != null and keymap.resolve(event) == .connect) {
            self.notice = "Connect is disabled in demo mode";
            return false;
        }
        if (self.active_tab == .pinned) return self.handlePinnedKey(event, ctx);
        if (self.replay_source) |replay| {
            switch (keymap.resolve(event)) {
                .pause => {
                    if (replay.playing.load(.acquire)) replay.pause() else replay.play();
                    return false;
                },
                .fps_up => {
                    replay.setSpeed(replay.speedMilli() +| 250);
                    return false;
                },
                .fps_down => {
                    replay.setSpeed(replay.speedMilli() -| 250);
                    return false;
                },
                .connect, .logging, .marker => {
                    self.notice = "Live adapters, TX, and recording are disabled during replay";
                    return false;
                },
                else => {},
            }
            if (event.key == .left) {
                replay.seekBy(-@as(i64, std.time.ns_per_s));
                return false;
            }
            if (event.key == .char and (event.key.char == 'n' or event.key.char == 'N')) {
                if (!(if (event.key.char == 'n') replay.jumpToNextMarker() else replay.jumpToPreviousMarker())) {
                    self.notice = "No more markers in that direction";
                }
                return false;
            }
            if (event.key == .char and (event.key.char == '[' or event.key.char == ']')) {
                replay.seekBy(if (event.key.char == '[') -@as(i64, std.time.ns_per_s) else @as(i64, std.time.ns_per_s));
                return false;
            }
            if (event.key == .right or (event.key == .char and event.key.char == '.')) {
                replay.stepForward();
                return false;
            }
            if (event.key == .char and event.key.char == ',') {
                replay.stepBackward();
                return false;
            }
        }
        switch (keymap.resolve(event)) {
            .logging => {
                self.toggleRecording();
                return false;
            },
            .marker => {
                if (self.engine.enqueueLogMarker("marker")) self.notice = "Marker added";
                return false;
            },
            else => {},
        }
        if (self.active_tab == .transmit) return self.handleTransmitKey(event, ctx);
        if (self.active_tab == .plot) return self.handlePlotKey(event, ctx);

        switch (keymap.resolve(event)) {
            .quit => return true,
            .help => self.overlay = .help,
            .connect => {
                self.connect.open(ctx.allocator, self.database.doc.buses.items, self.database.doc.messages.items);
                self.overlay = .connect;
            },
            .pause => {
                if (self.paused) {
                    self.paused = false;
                } else {
                    self.frozen_snapshot = self.engine.readSnapshot();
                    self.frozen_plot_snapshot = self.plot_worker.?.readSnapshot();
                    self.paused = true;
                }
            },
            .filter => self.monitor.filter_active = true,
            .pin => self.toggleSelectedPin(ctx.elapsed),
            .trace => {
                self.monitor.trace_mode = !self.monitor.trace_mode;
                self.monitor.selected_row = 0;
            },
            .database_only => self.monitor.database_only = !self.monitor.database_only,
            .toggle_bus => self.toggleMonitorBus(),
            .next_tab => self.active_tab = @fromBackingInt(@intCast((@backingInt(self.active_tab) + 1) % 5)),
            .tab_monitor => self.active_tab = .monitor,
            .tab_transmit => self.active_tab = .transmit,
            .tab_sent => self.active_tab = .sent,
            .tab_plot => self.active_tab = .plot,
            .tab_pinned => self.active_tab = .pinned,
            .fps_up => self.adjustFps(5, ctx.elapsed),
            .fps_down => self.adjustFps(-5, ctx.elapsed),
            .up => self.moveMonitor(-1),
            .down => self.moveMonitor(1),
            .left => self.monitor.detail_focus = false,
            .right => self.focusMonitorDetail(),
            else => {},
        }
        return false;
    }

    fn handleMouse(self: *App, event: zz.MouseEvent, ctx: *zz.Context) void {
        if (self.overlay == .none and self.active_tab == .plot and !self.plot.picker_open and !self.plot.window_edit_active and self.plot.inspect_enabled and event.event_type == .press and event.button == .left) {
            const prefix_rows = self.viewPrefixRows();
            const view_height = @max(@as(usize, ctx.height) -| prefix_rows -| 3, 1);
            const heading_rows = plot_ui.headingRowCount(self.database, &self.plot);
            const live_snapshot = self.plot_worker.?.readSnapshot();
            const snapshot = if (self.paused) &self.frozen_plot_snapshot else &live_snapshot;
            const grid_top = prefix_rows + heading_rows;
            if (@as(usize, event.y) >= grid_top) {
                const grid_y = @as(usize, event.y) - grid_top;
                const grid_height = plot_ui.gridHeight(@intCast(view_height), self.database, &self.plot, snapshot);
                if (self.plot.captureClick(event.x, @intCast(grid_y), ctx.width, grid_height, snapshot)) return;
            }
        }
        const replay = self.replay_source orelse return;
        if (self.overlay != .none) return;
        if (event.event_type != .press or event.button != .left or event.y != 4) return;
        if (replay.indexData() == null) return;
        if (timeline.timestampAtX(ctx.width, event.x, replay.durationNs())) |timestamp| {
            replay.seekTo(timestamp);
        }
    }

    fn viewPrefixRows(self: *const App) usize {
        var rows: usize = 4;
        if (self.replay_source != null) rows += 1;
        if (self.notice.len != 0) rows += 1;
        if (self.replay_source != null) rows += 1;
        if (self.replay_source == null and self.demo_source == null) {
            for (self.database.doc.buses.items, 0..) |_, index| {
                const status = self.engine.channelStatus(@intCast(index)) orelse continue;
                switch (status) {
                    .bus_off, .disconnected => rows += 1,
                    else => {},
                }
            }
        }
        return rows;
    }

    fn handlePlotKey(self: *App, event: zz.KeyEvent, ctx: *zz.Context) bool {
        if (self.plot.picker_open) {
            if (self.plot.assignment_signal != null) {
                switch (event.key) {
                    .left => self.plot.moveAssignment(-1),
                    .right => self.plot.moveAssignment(1),
                    .enter, .tab => {
                        const previous_count = self.plot.target_count;
                        self.plot.confirmAssignment(self.database, &self.plot_config);
                        if (self.plot.target_count != previous_count) {
                            self.plots_dirty = true;
                            self.last_plot_change_ns = ctx.elapsed;
                        }
                    },
                    .escape => self.plot.assignment_signal = null,
                    else => {},
                }
                return false;
            }
            switch (event.key) {
                .up => self.plot.movePicker(self.database, -1),
                .down => self.plot.movePicker(self.database, 1),
                .left => self.plot.collapsePickerRow(self.database),
                .right => self.plot.expandPickerRow(self.database),
                .tab => {
                    const previous_count = self.plot.target_count;
                    self.plot.togglePickerSignal(self.database, &self.plot_config);
                    if (self.plot.target_count != previous_count) {
                        self.plots_dirty = true;
                        self.last_plot_change_ns = ctx.elapsed;
                    }
                },
                .enter, .escape => self.plot.picker_open = false,
                .char => |character| switch (character) {
                    'q' => return true,
                    '1' => self.active_tab = .monitor,
                    '2' => self.active_tab = .transmit,
                    '3' => self.active_tab = .sent,
                    '5' => self.active_tab = .pinned,
                    else => {},
                },
                else => {},
            }
            return false;
        }
        if (self.plot.layout_edit_active) {
            switch (event.key) {
                .char => |character| if (character <= 0x7f and std.ascii.isDigit(@intCast(character))) self.plot.appendLayoutCharacter(@intCast(character)),
                .backspace => self.plot.backspaceLayoutInput(),
                .enter => {
                    if (self.plot.commitLayoutEdit(self.plot.plot_count)) {
                        self.plots_dirty = true;
                        self.last_plot_change_ns = ctx.elapsed;
                    } else {
                        self.plot.notice = "Columns must be 0 (Auto) or between 1 and the plot count";
                    }
                },
                .escape => self.plot.layout_edit_active = false,
                else => {},
            }
            return false;
        }
        if (self.plot.window_edit_active) {
            switch (event.key) {
                .char => |character| {
                    if ((character >= '0' and character <= '9') or character == '.') self.plot.appendWindowCharacter(@intCast(character));
                },
                .backspace => self.plot.backspaceWindowInput(),
                .enter => {
                    if (self.plot.commitWindowEdit(&self.plot_config)) {
                        self.plots_dirty = true;
                        self.last_plot_change_ns = ctx.elapsed;
                    } else {
                        self.plot.notice = "Enter a window from 0.1 to 600000 ms";
                    }
                },
                .escape => self.plot.window_edit_active = false,
                else => {},
            }
            return false;
        }
        switch (keymap.resolve(event)) {
            .quit => return true,
            .help => self.overlay = .help,
            .connect => {
                self.connect.open(ctx.allocator, self.database.doc.buses.items, self.database.doc.messages.items);
                self.overlay = .connect;
            },
            .tab_monitor => self.active_tab = .monitor,
            .tab_transmit => self.active_tab = .transmit,
            .tab_sent => self.active_tab = .sent,
            .tab_pinned => self.active_tab = .pinned,
            .next_tab => self.active_tab = .pinned,
            .fps_up => self.adjustFps(5, ctx.elapsed),
            .fps_down => self.adjustFps(-5, ctx.elapsed),
            .pause => {
                if (self.paused) {
                    self.paused = false;
                } else {
                    self.frozen_snapshot = self.engine.readSnapshot();
                    self.frozen_plot_snapshot = self.plot_worker.?.readSnapshot();
                    self.paused = true;
                }
            },
            .pin => self.plot.openPicker(self.allocator, self.database) catch {
                self.plot.notice = "Unable to open signal picker";
            },
            .up => self.plot.moveSignal(self.database, -1),
            .down => self.plot.moveSignal(self.database, 1),
            .left => self.plot.moveMessage(self.database, -1),
            .right => self.plot.moveMessage(self.database, 1),
            else => switch (event.key) {
                .page_up => self.plot.adjustScroll(&self.plot_config, 5),
                .page_down => self.plot.adjustScroll(&self.plot_config, -5),
                .char => |character| switch (character) {
                    'l' => self.plot.beginLayoutEdit(),
                    'i' => self.plot.toggleInspect(),
                    'w' => self.plot.beginWindowEdit(),
                    '[' => self.plot.selectPlot(-1),
                    ']' => self.plot.selectPlot(1),
                    's' => {
                        self.plot.running = !self.plot.running;
                        self.plot_config.setSamplingEnabled(self.plot.running);
                    },
                    '<' => {
                        self.plot.addSelected(self.database, &self.plot_config);
                        self.plots_dirty = true;
                        self.last_plot_change_ns = ctx.elapsed;
                    },
                    'x' => {
                        self.plot.removeSelected(&self.plot_config);
                        self.plots_dirty = true;
                        self.last_plot_change_ns = ctx.elapsed;
                    },
                    '+', '=' => self.adjustPlotWindow(5, ctx.elapsed),
                    '-' => self.adjustPlotWindow(-5, ctx.elapsed),
                    else => {},
                },
                else => {},
            },
        }
        return false;
    }

    fn adjustPlotWindow(self: *App, delta_seconds: i32, now_ns: u64) void {
        self.plot.adjustWindow(&self.plot_config, delta_seconds);
        self.settings.plot_window_seconds = self.plot.window_seconds;
        self.settings_dirty = true;
        self.plots_dirty = true;
        self.last_plot_change_ns = now_ns;
        self.last_settings_change_ns = now_ns;
    }

    fn handlePinnedKey(self: *App, event: zz.KeyEvent, ctx: *zz.Context) bool {
        if (self.pin_picker.picker_open) {
            switch (event.key) {
                .up => self.pin_picker.movePicker(self.database, -1),
                .down => self.pin_picker.movePicker(self.database, 1),
                .left => self.pin_picker.collapsePickerRow(self.database),
                .right => self.pin_picker.expandPickerRow(self.database),
                .tab => self.togglePickerPin(ctx.elapsed),
                .enter, .escape => self.pin_picker.picker_open = false,
                .char => |character| switch (character) {
                    'q' => return true,
                    '1' => self.active_tab = .monitor,
                    '2' => self.active_tab = .transmit,
                    '3' => self.active_tab = .sent,
                    '4' => self.active_tab = .plot,
                    else => {},
                },
                else => {},
            }
            return false;
        }
        switch (keymap.resolve(event)) {
            .quit => return true,
            .help => self.overlay = .help,
            .tab_monitor => self.active_tab = .monitor,
            .tab_transmit => self.active_tab = .transmit,
            .tab_sent => self.active_tab = .sent,
            .tab_plot => self.active_tab = .plot,
            .next_tab => self.active_tab = .monitor,
            .up => {
                if (self.pinned_selected > 0) self.pinned_selected -= 1;
            },
            .down => {
                if (self.pinned_selected + 1 < self.pins.len) self.pinned_selected += 1;
            },
            .pin => self.pin_picker.openPicker(self.allocator, self.database) catch {
                self.notice = "Unable to open signal picker";
            },
            .connect => {
                if (self.demo_source != null) {
                    self.notice = "Connect is disabled in demo mode";
                } else {
                    self.connect.open(ctx.allocator, self.database.doc.buses.items, self.database.doc.messages.items);
                    self.overlay = .connect;
                }
            },
            else => switch (event.key) {
                .page_up => self.scrollPinnedPins(ctx.height, -1),
                .page_down => self.scrollPinnedPins(ctx.height, 1),
                .left => self.pinned_horizontal_scroll -|= 8,
                .right => self.pinned_horizontal_scroll +|= 8,
                .char => |character| if (character == 'x') self.unpinSelected(),
                else => {},
            },
        }
        return false;
    }

    fn unpinSelected(self: *App) void {
        if (self.pinned_selected >= self.pins.len) return;
        const pin = self.pins.items[self.pinned_selected].?;
        self.pins.toggle(pin) catch return;
        if (self.pinned_selected >= self.pins.len and self.pins.len > 0) self.pinned_selected = self.pins.len - 1;
        self.pins_dirty = true;
        self.last_pin_change_ns = clock.nowNs(self.io);
        self.notice = "Pin removed";
    }

    fn scrollPinnedPins(self: *App, height: u16, direction: isize) void {
        if (self.pins.len == 0) return;
        const page_size = @max(@as(usize, height) -| 10, 1);
        const position: isize = @intCast(self.pinned_selected);
        const next = @as(i128, position) + @as(i128, direction) * @as(i128, @intCast(page_size));
        self.pinned_selected = @intCast(@min(@max(next, 0), @as(i128, @intCast(self.pins.len - 1))));
        self.pinned_scroll = self.pinned_selected;
    }

    fn togglePickerPin(self: *App, now_ns: u64) void {
        const selection = self.pin_picker.pickerSignal(self.database) orelse return;
        self.pins.toggle(.{ .message = selection.message, .signal = selection.signal }) catch {
            self.notice = "Pin limit reached";
            return;
        };
        self.pins_dirty = true;
        self.last_pin_change_ns = now_ns;
        self.notice = if (self.pins.contains(.{ .message = selection.message, .signal = selection.signal }))
            "Signal pinned"
        else
            "Pin removed";
    }

    fn handleFilterKey(self: *App, event: zz.KeyEvent) void {
        switch (keymap.resolve(event)) {
            .escape, .enter => self.monitor.filter_active = false,
            .backspace => self.monitor.backspaceFilter(),
            else => switch (event.key) {
                .char => |character| if (character >= 0x20 and character <= 0x7e) self.monitor.appendFilter(@intCast(character)),
                .space => self.monitor.appendFilter(' '),
                else => {},
            },
        }
    }

    fn handleTransmitKey(self: *App, event: zz.KeyEvent, ctx: *zz.Context) bool {
        self.transmit.ensureMessage(self.database);
        switch (keymap.resolve(event)) {
            .quit => return true,
            .help => {
                self.overlay = .help;
                return false;
            },
            .connect => {
                self.connect.open(ctx.allocator, self.database.doc.buses.items, self.database.doc.messages.items);
                self.overlay = .connect;
                return false;
            },
            .tab_monitor => {
                self.active_tab = .monitor;
                return false;
            },
            .tab_sent => {
                self.active_tab = .sent;
                return false;
            },
            .tab_plot => {
                self.active_tab = .plot;
                return false;
            },
            .tab_pinned => {
                self.active_tab = .pinned;
                return false;
            },
            .next_tab => {
                self.active_tab = .sent;
                return false;
            },
            .fps_up => {
                self.adjustFps(5, ctx.elapsed);
                return false;
            },
            .fps_down => {
                self.adjustFps(-5, ctx.elapsed);
                return false;
            },
            else => {},
        }
        switch (event.key) {
            .escape => self.active_tab = .monitor,
            .up => self.transmit.moveSignal(self.database, -1),
            .down => self.transmit.moveSignal(self.database, 1),
            .left => self.transmit.moveMessage(self.database, -1),
            .right => self.transmit.moveMessage(self.database, 1),
            .enter => self.sendTransmit(),
            .char => |character| switch (character) {
                'q' => return true,
                's' => self.sendTransmit(),
                'm' => {
                    if (self.transmit.periodic_started) {
                        self.stopPeriodic();
                    } else {
                        self.transmit.periodic_mode = !self.transmit.periodic_mode;
                    }
                },
                'x' => self.stopPeriodic(),
                'k' => self.transmit.auto_counter = !self.transmit.auto_counter,
                'c' => {
                    if (self.transmit.cycleChoice(self.database, 1)) {
                        if (self.transmit.periodic_started) self.sendTransmit();
                    } else {
                        self.transmit.notice = "Selected signal has no choices";
                    }
                },
                '+', '=' => self.adjustTransmitSignal(1, ctx.elapsed),
                '-' => self.adjustTransmitSignal(-1, ctx.elapsed),
                ']' => {
                    self.transmit.period_ms = @min(self.transmit.period_ms +| 10, 60_000);
                    if (self.transmit.periodic_started) self.sendTransmit();
                },
                '[' => {
                    self.transmit.period_ms = @max(self.transmit.period_ms -| 10, 1);
                    if (self.transmit.periodic_started) self.sendTransmit();
                },
                '?' => self.overlay = .help,
                else => {},
            },
            else => {},
        }
        return false;
    }
    fn adjustTransmitSignal(self: *App, direction: f64, now_ns: u64) void {
        self.transmit.adjustSignal(self.database, direction);
        if (self.transmit.periodic_started) self.sendTransmit();
        _ = now_ns;
    }

    fn sendTransmit(self: *App) void {
        if (self.demo_source != null) {
            self.transmit.notice = "Transmit is disabled in demo mode";
            return;
        }
        self.transmit.ensureMessage(self.database);
        if (self.database.compiled.messages.len == 0) {
            self.transmit.notice = "No messages to transmit";
            return;
        }
        const message = self.database.compiled.messages[self.transmit.selected_message];
        const bus_index = transmit.findBusIndex(self.database, message.bus) orelse {
            self.transmit.notice = "Message bus is not configured";
            return;
        };
        if (!self.engine.isBusConnected(bus_index)) {
            self.transmit.notice = "Connect this message bus first";
            return;
        }
        const frame = transmit.buildFrame(self.database, bus_index, &self.transmit) catch |err| {
            self.transmit.notice = @errorName(err);
            return;
        };
        const job = tx.Job{
            .id = 1,
            .bus_index = bus_index,
            .frame = frame,
            .period_ns = @as(u64, self.transmit.period_ms) * std.time.ns_per_ms,
            .counter = transmit.counterSpec(self.database, &self.transmit),
        };
        const queued = if (self.transmit.periodic_started)
            self.engine.updatePeriodic(job)
        else if (self.transmit.periodic_mode)
            self.engine.startPeriodic(job)
        else
            self.engine.sendOnce(job);
        if (!queued) {
            self.transmit.notice = "TX command queue is full or engine is stopped";
            return;
        }
        if (self.transmit.periodic_mode) self.transmit.periodic_started = true;
        self.transmit.notice = if (self.transmit.periodic_mode) "Periodic job queued" else "One-shot queued";
        if (!self.transmit.periodic_mode) self.transmit.advanceCounter(self.database);
    }

    fn stopPeriodic(self: *App) void {
        if (self.engine.stopPeriodic(1)) {
            self.transmit.periodic_started = false;
            self.transmit.notice = "Periodic job stopped";
        }
    }

    fn handleConnectKey(self: *App, event: zz.KeyEvent, ctx: *zz.Context) void {
        switch (event.key) {
            .escape => self.overlay = .none,
            .up => self.connect.moveChannel(-1),
            .down => self.connect.moveChannel(1),
            .left => self.connect.moveBus(-1, self.database.doc.buses.items.len),
            .right => self.connect.moveBus(1, self.database.doc.buses.items.len),
            .enter => self.applyConnections(ctx),
            .char => |character| switch (character) {
                'm' => self.connect.toggleMapping(),
                'n' => self.connect.cycleNominalBitrate(),
                'd' => self.connect.cycleDataBitrate(),
                'f' => self.connect.toggleFd(),
                else => {},
            },
            else => {},
        }
    }

    fn applyConnections(self: *App, ctx: *zz.Context) void {
        if (self.connect.mappedCount(self.database.doc.buses.items.len) == 0) {
            self.notice = "Map at least one channel with m";
            return;
        }

        self.engine.clearAdapters();
        for (self.connect.mappings[0..@min(self.database.doc.buses.items.len, self.connect.mappings.len)], 0..) |mapping, bus_index| {
            const choice_index = mapping orelse continue;
            const choice = self.connect.choices[choice_index].?;
            const settings = self.connect.bus_settings[bus_index];
            if (settings.use_fd and !choice.channel.capabilities.fd) {
                self.engine.clearAdapters();
                self.notice = "CAN FD selected for a channel that does not support it";
                return;
            }
            var device = choice.backend.open(self.allocator, .{
                .channel = choice.channel.nameSlice(),
                .nominal_bitrate = settings.nominal_bitrate,
                .data_bitrate = if (settings.use_fd) settings.data_bitrate else null,
            }) catch |err| {
                self.engine.clearAdapters();
                self.notice = @errorName(err);
                return;
            };
            self.engine.addAdapterWithInfo(device, @intCast(bus_index), choice.channel) catch |err| {
                device.deinit();
                self.engine.clearAdapters();
                self.notice = @errorName(err);
                return;
            };
        }
        self.engine.start() catch |err| {
            self.engine.clearAdapters();
            self.notice = @errorName(err);
            return;
        };
        self.overlay = .none;
        self.notice = "Connected";
        self.paused = false;
        _ = ctx;
    }

    fn moveMonitor(self: *App, amount: isize) void {
        const live_snapshot = self.engine.readSnapshot();
        const snapshot = if (self.paused) &self.frozen_snapshot else &live_snapshot;
        self.monitor.move(amount, snapshot, self.database);
    }

    fn focusMonitorDetail(self: *App) void {
        const live_snapshot = self.engine.readSnapshot();
        const snapshot = if (self.paused) &self.frozen_snapshot else &live_snapshot;
        self.monitor.toggleDetailFocus(snapshot, self.database);
    }

    fn toggleMonitorBus(self: *App) void {
        const live_snapshot = self.engine.readSnapshot();
        const snapshot = if (self.paused) &self.frozen_snapshot else &live_snapshot;
        self.monitor.toggleSelectedBus(snapshot, self.database);
        self.monitor.detail_focus = false;
    }

    fn toggleSelectedPin(self: *App, now_ns: u64) void {
        const live_snapshot = self.engine.readSnapshot();
        const snapshot = if (self.paused) &self.frozen_snapshot else &live_snapshot;
        const frame = monitor.selectedFrame(&self.monitor, snapshot, self.database) orelse return;
        const bus = if (frame.bus < self.database.doc.buses.items.len) self.database.doc.buses.items[frame.bus].name else return;
        const handle = self.database.compiled.findMessage(bus, frame.id, frame.flags.extended) orelse {
            self.notice = "Unknown messages cannot be pinned";
            return;
        };
        const signal: ?usize = if (self.monitor.detail_focus and self.monitor.selected_signal < self.database.compiled.messages[handle].signals.len)
            self.monitor.selected_signal
        else
            null;
        self.pins.toggle(.{ .message = handle, .signal = signal }) catch {
            self.notice = "Pin limit reached";
            return;
        };
        self.pins_dirty = true;
        self.last_pin_change_ns = now_ns;
        self.notice = if (self.pins.contains(.{ .message = handle, .signal = signal })) "Item pinned" else "Pin removed";
    }

    fn persistPins(self: *App) void {
        config.savePins(self.allocator, self.io, self.config_directory, &self.database_hash, self.database, &self.pins) catch |err| {
            self.notice = @errorName(err);
            return;
        };
        self.pins_dirty = false;
    }

    fn persistPlots(self: *App) void {
        var saved: config.PlotSet = .{};
        saved.columns_override = self.plot.columns_override;
        for (self.plot.targets[0..self.plot.target_count]) |target| {
            const plotted = target.?;
            saved.toggle(.{
                .message = plotted.message_handle,
                .signal = plotted.signal_index,
                .plot_index = plotted.plot_index,
                .window_ns = self.plot.plot_windows_ns[plotted.plot_index],
            }) catch break;
        }
        config.savePlots(self.allocator, self.io, self.config_directory, &self.database_hash, self.database, &saved) catch |err| {
            self.notice = @errorName(err);
            return;
        };
        self.plots_dirty = false;
    }

    fn persistSettings(self: *App) void {
        config.saveSettings(self.allocator, self.io, self.config_directory, self.settings) catch |err| {
            self.notice = @errorName(err);
            return;
        };
        self.settings_dirty = false;
    }

    fn toggleRecording(self: *App) void {
        if (self.engine.isLogging()) {
            self.engine.stopLogging();
            self.notice = "Recording stopped";
            return;
        }
        const path = self.log_path orelse self.defaultLogPath() catch |err| {
            self.notice = @errorName(err);
            return;
        };
        self.startRecording(path);
    }

    fn defaultLogPath(self: *App) std.mem.Allocator.Error![]const u8 {
        if (self.default_log_path) |path| return path;
        const timestamp = clock.nowNs(self.io);
        self.default_log_path = try std.fmt.allocPrint(self.allocator, "can_dbz_vis-{d}.canlog.jsonl", .{timestamp});
        return self.default_log_path.?;
    }

    fn startRecording(self: *App, path: []const u8) void {
        const header = self.makeLogHeader() catch |err| {
            self.notice = @errorName(err);
            return;
        };
        self.engine.startLogging(path, header) catch |err| {
            self.notice = @errorName(err);
            return;
        };
        self.notice = "Recording started";
    }

    fn makeLogHeader(self: *const App) !log_format.Header {
        var header = log_format.Header{};
        const wall_ns = std.Io.Clock.real.now(self.io).nanoseconds;
        if (wall_ns < 0) return error.InvalidClock;
        const seconds: u64 = @intCast(@divFloor(wall_ns, std.time.ns_per_s));
        const nanoseconds: u64 = @intCast(@mod(wall_ns, std.time.ns_per_s));
        const epoch = std.time.epoch.EpochSeconds{ .secs = seconds };
        const year_day = epoch.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_time = epoch.getDaySeconds();
        var utc_buffer: [40]u8 = undefined;
        const created_utc = try std.fmt.bufPrint(&utc_buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}Z", .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_time.getHoursIntoDay(),
            day_time.getMinutesIntoHour(),
            day_time.getSecondsIntoMinute(),
            nanoseconds,
        });
        try header.created_utc.set(created_utc);
        try header.tool.set("can_dbz_vis 0.1.0");
        header.database = .{};
        try header.database.?.file.set(std.fs.path.basename(self.database_file));
        try header.database.?.sha256.set(&self.database_hash);

        if (self.database.doc.buses.items.len > header.buses.len) return error.TooManyBuses;
        for (self.database.doc.buses.items, 0..) |database_bus, index| {
            const info = self.engine.channelInfo(@intCast(index));
            var bus = log_format.Bus{
                .index = @intCast(index),
                .bitrate = database_bus.nominal_bitrate,
                .data_bitrate = database_bus.data_bitrate,
            };
            try bus.name.set(database_bus.name);
            if (info) |channel| {
                try bus.backend.set(channel.backend);
                try bus.channel.set(channel.nameSlice());
            } else {
                try bus.backend.set("unmapped");
                try bus.channel.set(database_bus.name);
            }
            for (self.database.compiled.messages) |message| {
                if (std.mem.eql(u8, message.bus, database_bus.name) and message.frame == .fd) bus.fd = true;
            }
            header.buses[index] = bus;
        }
        header.bus_count = @intCast(self.database.doc.buses.items.len);
        return header;
    }

    fn renderSent(self: *const App, allocator: std.mem.Allocator, writer: *std.Io.Writer, snapshot: *const store.Snapshot) !void {
        try writeStyled(writer, allocator, "Sent  /  driver-accepted", (zz.Style{}).fg(zz.Color.brightCyan).bold(true).inline_style(true));
        try writer.writeByte('\n');
        if (snapshot.sent_count == 0) {
            try writeStyled(writer, allocator, "No TX events", (zz.Style{}).fg(zz.Color.gray(14)).italic(true).inline_style(true));
            try writer.writeByte('\n');
            return;
        }
        for (snapshot.sent[0..snapshot.sent_count]) |event| {
            const timestamp = try std.fmt.allocPrint(allocator, "{d:>12} ns", .{event.timestamp_ns});
            defer allocator.free(timestamp);
            try writeStyled(writer, allocator, timestamp, (zz.Style{}).fg(zz.Color.gray(14)).inline_style(true));
            try writer.print("  bus {s:<12} 0x{X:0>3}  ", .{
                if (event.frame.bus < self.database.doc.buses.items.len) self.database.doc.buses.items[event.frame.bus].name else "unknown",
                event.frame.id,
            });
            try writeStyled(writer, allocator, @tagName(event.status), sentStatusStyle(event.status).inline_style(true));
            try writer.print("  job {d}  ", .{event.job_id});
            var payload: [64 * 3]u8 = undefined;
            var payload_writer: std.Io.Writer = .fixed(&payload);
            for (event.frame.data[0..event.frame.len]) |byte| try payload_writer.print("{X:0>2} ", .{byte});
            try writeStyled(writer, allocator, payload_writer.buffered(), (zz.Style{}).fg(zz.Color.brightGreen).inline_style(true));
            try writer.writeByte('\n');
        }
    }

    fn adjustFps(self: *App, delta: i32, now_ns: u64) void {
        const next = @as(i32, @intCast(self.settings.fps)) + delta;
        self.settings.fps = @intCast(@min(@max(next, 10), 120));
        if (self.program_options) |options| options.fps = self.settings.fps;
        self.settings_dirty = true;
        self.last_settings_change_ns = now_ns;
    }

    fn renderHelp(_: *const App, writer: *std.Io.Writer) !void {
        try writer.writeAll("Keys\n  q quit   ? close help   c connect   Tab/1-5 tabs\n  arrows select/focus   p pin/unpin   / filter   g database messages only\n  t aggregate/trace   space pause/resume   +/- frame rate\nTransmit: arrows choose message/signal, +/- edit, c choices, Enter/s send\n  m periodic mode, [/] period, s start/update, x stop, k auto counter\nReplay: space play/pause, +/- speed, left or [/] seek 1s, n/N next/previous marker\n  ,/./right step backward/forward\nSent: ok means accepted by driver/kernel queue, not bus ACK\n  queue_full, bus_off, and driver_error report failures\n");
    }

    fn renderConnect(self: *const App, writer: *std.Io.Writer) !void {
        try writer.writeAll("Connect channels\n");
        const bus_count = @min(self.database.doc.buses.items.len, connect.max_buses);
        for (0..bus_count) |bus_index| {
            const mapping = self.connect.mappings[bus_index];
            try writer.print(" {s} bus {s}: ", .{
                if (bus_index == self.connect.selected_bus) ">" else " ",
                self.database.doc.buses.items[bus_index].name,
            });
            if (mapping) |choice_index| {
                const choice = self.connect.choices[choice_index].?;
                try writer.print("{s}:{s}\n", .{ choice.backend.name, choice.channel.nameSlice() });
            } else {
                try writer.writeAll("not mapped\n");
            }
        }
        if (bus_count > 0) {
            const settings = self.connect.bus_settings[self.connect.selected_bus];
            try writer.print("\n{s} rates: nominal {d} bit/s; {s}", .{
                self.database.doc.buses.items[self.connect.selected_bus].name,
                settings.nominal_bitrate,
                if (settings.use_fd) "CAN FD data" else "Classic CAN",
            });
            if (settings.use_fd) try writer.print(" {d} bit/s", .{settings.data_bitrate});
            if (self.connect.mappings[self.connect.selected_bus]) |choice_index| {
                const choice = self.connect.choices[choice_index].?;
                if (!choice.channel.capabilities.set_bitrate and std.mem.eql(u8, choice.backend.name, "socketcan")) {
                    try writer.writeAll(" (configure SocketCAN rate in OS)");
                }
            }
            try writer.writeByte('\n');
        }
        try writer.writeAll("\nAvailable channels\n");
        const first = self.connect.selected_channel -| 5;
        const last = @min(self.connect.choice_count, first + 12);
        for (first..last) |index| {
            const choice = self.connect.choices[index].?;
            try writer.print(" {s} {s}:{s}  {s}{s}\n", .{
                if (index == self.connect.selected_channel) ">" else " ",
                choice.backend.name,
                choice.channel.nameSlice(),
                choice.channel.description,
                if (choice.channel.capabilities.fd) " [FD]" else "",
            });
        }
        try writer.print("\n{s}\n", .{self.connect.notice});
        try writer.writeAll("up/down channel  left/right bus  m map  n nominal rate  f Classic/FD  d FD data rate\nEnter connect  Esc cancel\n");
    }
};

fn writeStyled(writer: *std.Io.Writer, allocator: std.mem.Allocator, text: []const u8, style: zz.Style) !void {
    const styled = try style.render(allocator, text);
    defer allocator.free(styled);
    try writer.writeAll(styled);
}

fn sentStatusStyle(status: store.TxStatus) zz.Style {
    return (zz.Style{}).fg(switch (status) {
        .ok => zz.Color.brightGreen,
        .queue_full => zz.Color.brightYellow,
        .bus_off, .driver_error => zz.Color.brightRed,
    }).bold(status != .ok);
}
