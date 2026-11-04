const std = @import("std");
const adapter = @import("../can/adapter.zig");
const Frame = @import("../can/frame.zig").Frame;
const clock = @import("../sync/clock.zig");
const spsc = @import("../sync/spsc.zig");
const store = @import("store.zig");

pub const max_jobs = 64;
pub const command_capacity = 256;
pub const retry_timeout_ns = 100 * std.time.ns_per_us;
const max_idle_sleep_ns = std.time.ns_per_ms;

pub const Job = struct {
    id: u16,
    bus_index: u8,
    frame: Frame,
    period_ns: u64 = 0,
    counter: ?CounterSpec = null,
};

pub const CounterSpec = struct {
    bit_positions: [64]u16 = @splat(0),
    bit_length: u8,
    little_endian: bool,
    initial: u64,
};

pub const Command = union(enum) {
    send_once: Job,
    start_periodic: Job,
    update: Job,
    stop: u16,
    stop_all,
};

pub const CommandQueue = spsc.Spsc(Command, command_capacity);
pub const EventQueue = store.TxEventQueue;

pub const AdapterSlot = struct {
    device: *adapter.Adapter,
    bus_index: u8,
};

const PeriodicJob = struct {
    job: Job,
    next_deadline_ns: u64,
    counter_value: u64,
};

pub const Worker = struct {
    io: std.Io,
    adapters: *[4]?AdapterSlot,
    adapter_count: *usize,
    commands: *CommandQueue,
    events: *EventQueue,
    stop: *std.atomic.Value(bool),
    active_jobs: *std.atomic.Value(u32),
    skipped_sends: *std.atomic.Value(u64),
    jobs: [max_jobs]?PeriodicJob = @splat(null),
    thread: ?std.Thread = null,

    pub const StartError = std.Thread.SpawnError || error{AlreadyStarted};

    pub fn start(self: *Worker) StartError!void {
        if (self.thread != null) return error.AlreadyStarted;
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn join(self: *Worker) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    pub fn step(self: *Worker, now_ns: u64) void {
        while (self.commands.pop()) |command| self.processCommand(command, now_ns);

        for (&self.jobs) |*slot| {
            const periodic = if (slot.*) |*job| job else continue;
            if (now_ns < periodic.next_deadline_ns) continue;

            const overdue_periods = (now_ns - periodic.next_deadline_ns) / periodic.job.period_ns;
            if (overdue_periods != 0) {
                _ = self.skipped_sends.fetchAdd(overdue_periods, .monotonic);
                periodic.next_deadline_ns +%= overdue_periods *% periodic.job.period_ns;
            }
            var due_job = periodic.job;
            if (due_job.counter) |counter| {
                writeCounter(&due_job.frame, counter, periodic.counter_value);
                periodic.counter_value = if (counter.bit_length == 64)
                    periodic.counter_value +% 1
                else
                    (periodic.counter_value +% 1) & ((@as(u64, 1) << @intCast(counter.bit_length)) - 1);
            }
            self.send(due_job);
            periodic.next_deadline_ns +%= periodic.job.period_ns;
        }
    }

    fn processCommand(self: *Worker, command: Command, now_ns: u64) void {
        switch (command) {
            .send_once => |job| self.send(job),
            .start_periodic => |job| {
                if (job.period_ns == 0) {
                    self.emit(job, .driver_error);
                    return;
                }
                var existing: ?usize = null;
                var free: ?usize = null;
                for (self.jobs, 0..) |maybe_job, index| {
                    if (maybe_job) |periodic| {
                        if (periodic.job.id == job.id) existing = index;
                    } else if (free == null) {
                        free = index;
                    }
                }
                const index = existing orelse free orelse {
                    self.emit(job, .driver_error);
                    return;
                };
                self.jobs[index] = .{
                    .job = job,
                    .next_deadline_ns = now_ns,
                    .counter_value = if (job.counter) |counter| counter.initial else 0,
                };
                self.refreshActiveCount();
            },
            .update => |job| {
                for (&self.jobs) |*maybe_periodic| {
                    if (maybe_periodic.*) |*periodic| {
                        if (periodic.job.id == job.id) {
                            const previous_counter = periodic.job.counter;
                            periodic.job.frame = job.frame;
                            periodic.job.bus_index = job.bus_index;
                            periodic.job.counter = job.counter;
                            if (job.counter) |counter| {
                                const same_counter = if (previous_counter) |previous|
                                    previous.bit_length == counter.bit_length and previous.little_endian == counter.little_endian and
                                        std.mem.eql(u16, &previous.bit_positions, &counter.bit_positions)
                                else
                                    false;
                                if (!same_counter) periodic.counter_value = counter.initial;
                            }
                            if (job.period_ns != 0 and periodic.job.period_ns != job.period_ns) {
                                periodic.job.period_ns = job.period_ns;
                                periodic.next_deadline_ns = now_ns +| job.period_ns;
                            }
                            break;
                        }
                    }
                }
            },
            .stop => |job_id| {
                for (&self.jobs) |*maybe_periodic| {
                    if (maybe_periodic.*) |periodic| {
                        if (periodic.job.id == job_id) maybe_periodic.* = null;
                    }
                }
                self.refreshActiveCount();
            },
            .stop_all => {
                self.jobs = @splat(null);
                self.active_jobs.store(0, .release);
            },
        }
    }

    fn send(self: *Worker, job: Job) void {
        const slot = self.findAdapter(job.bus_index) orelse {
            self.emit(job, .driver_error);
            return;
        };
        var status: store.TxStatus = switch (slot.device.status()) {
            .bus_off => .bus_off,
            .disconnected => .driver_error,
            else => .ok,
        };
        if (status == .ok) {
            slot.device.write(&job.frame, retry_timeout_ns) catch |first_error| {
                if (first_error == error.QueueFull) {
                    slot.device.write(&job.frame, 0) catch |retry_error| {
                        status = statusFromError(retry_error);
                    };
                } else {
                    status = statusFromError(first_error);
                }
            };
        }
        self.emit(job, status);
    }

    fn emit(self: *Worker, job: Job, status: store.TxStatus) void {
        var frame = job.frame;
        frame.timestamp_ns = clock.nowNs(self.io);
        _ = self.events.push(.{
            .frame = frame,
            .status = status,
            .job_id = job.id,
            .timestamp_ns = frame.timestamp_ns,
        });
    }

    fn findAdapter(self: *Worker, bus_index: u8) ?AdapterSlot {
        for (self.adapters[0..self.adapter_count.*]) |maybe_slot| {
            const slot = maybe_slot orelse continue;
            if (slot.bus_index == bus_index) return slot;
        }
        return null;
    }

    fn refreshActiveCount(self: *Worker) void {
        var count: u32 = 0;
        for (self.jobs) |job| {
            if (job != null) count += 1;
        }
        self.active_jobs.store(count, .release);
    }

    fn run(self: *Worker) void {
        while (!self.stop.load(.acquire)) {
            const now_ns = clock.nowNs(self.io);
            self.step(now_ns);
            const deadline = self.nextDeadline() orelse {
                std.Io.sleep(self.io, .{ .nanoseconds = max_idle_sleep_ns }, .awake) catch {};
                continue;
            };
            if (deadline > now_ns) {
                const delay = @min(deadline - now_ns, max_idle_sleep_ns);
                std.Io.sleep(self.io, .{ .nanoseconds = @intCast(delay) }, .awake) catch {};
            }
        }
        self.step(clock.nowNs(self.io));
        self.jobs = @splat(null);
        self.active_jobs.store(0, .release);
    }

    fn nextDeadline(self: *const Worker) ?u64 {
        var result: ?u64 = null;
        for (self.jobs) |maybe_job| {
            const job = maybe_job orelse continue;
            result = if (result) |current| @min(current, job.next_deadline_ns) else job.next_deadline_ns;
        }
        return result;
    }
};

fn statusFromError(err: adapter.Error) store.TxStatus {
    return switch (err) {
        error.QueueFull => .queue_full,
        error.BusOff => .bus_off,
        else => .driver_error,
    };
}

fn writeCounter(frame: *Frame, counter: CounterSpec, value: u64) void {
    for (counter.bit_positions[0..counter.bit_length], 0..) |position, index| {
        const source_bit: u6 = if (counter.little_endian)
            @intCast(index)
        else
            @intCast(counter.bit_length - index - 1);
        const mask: u8 = @as(u8, 1) << @as(u3, @truncate(position % 8));
        if ((value >> source_bit) & 1 == 1) {
            frame.data[position / 8] |= mask;
        } else {
            frame.data[position / 8] &= ~mask;
        }
    }
}

test "TX worker sends once and emits a driver-accepted event" {
    const allocator = std.testing.allocator;
    var sender = try @import("../can/virtual.zig").backend.open(allocator, .{ .channel = "virtual0" });
    defer sender.deinit();
    var receiver = try @import("../can/virtual.zig").backend.open(allocator, .{ .channel = "virtual0" });
    defer receiver.deinit();

    var adapters: [4]?AdapterSlot = @splat(null);
    adapters[0] = .{ .device = &sender, .bus_index = 0 };
    var adapter_count: usize = 1;
    var commands: CommandQueue = .{};
    var events: EventQueue = .{};
    var stop: std.atomic.Value(bool) = .init(false);
    var active_jobs: std.atomic.Value(u32) = .init(0);
    var skipped_sends: std.atomic.Value(u64) = .init(0);
    var worker = Worker{
        .io = std.testing.io,
        .adapters = &adapters,
        .adapter_count = &adapter_count,
        .commands = &commands,
        .events = &events,
        .stop = &stop,
        .active_jobs = &active_jobs,
        .skipped_sends = &skipped_sends,
    };
    const frame = Frame{
        .timestamp_ns = 1,
        .id = 0x321,
        .bus = 0,
        .len = 2,
        .flags = .{},
        ._pad = 0,
        .data = .{ 0x12, 0x34 } ++ @as([62]u8, @splat(0)),
    };
    try std.testing.expect(commands.push(.{ .send_once = .{ .id = 1, .bus_index = 0, .frame = frame } }));
    worker.step(10);

    const event = events.pop().?;
    try std.testing.expectEqual(store.TxStatus.ok, event.status);
    try std.testing.expectEqual(@as(u16, 1), event.job_id);
    var received: [1]Frame = undefined;
    try std.testing.expectEqual(@as(usize, 1), try receiver.read(&received, 0));
    try std.testing.expectEqual(frame.id, received[0].id);
}

test "TX periodic scheduler skips missed deadlines rather than bursting" {
    const allocator = std.testing.allocator;
    var sender = try @import("../can/virtual.zig").backend.open(allocator, .{ .channel = "virtual0" });
    defer sender.deinit();
    var receiver = try @import("../can/virtual.zig").backend.open(allocator, .{ .channel = "virtual0" });
    defer receiver.deinit();

    var adapters: [4]?AdapterSlot = @splat(null);
    adapters[0] = .{ .device = &sender, .bus_index = 0 };
    var adapter_count: usize = 1;
    var commands: CommandQueue = .{};
    var events: EventQueue = .{};
    var stop: std.atomic.Value(bool) = .init(false);
    var active_jobs: std.atomic.Value(u32) = .init(0);
    var skipped_sends: std.atomic.Value(u64) = .init(0);
    var worker = Worker{
        .io = std.testing.io,
        .adapters = &adapters,
        .adapter_count = &adapter_count,
        .commands = &commands,
        .events = &events,
        .stop = &stop,
        .active_jobs = &active_jobs,
        .skipped_sends = &skipped_sends,
    };
    const frame = Frame{
        .timestamp_ns = 0,
        .id = 2,
        .bus = 0,
        .len = 1,
        .flags = .{},
        ._pad = 0,
        .data = .{ 0, 0, 0, 0, 0, 0, 0, 0 } ++ @as([56]u8, @splat(0)),
    };
    var bit_positions: [64]u16 = @splat(0);
    bit_positions[0..4].* = .{ 0, 1, 2, 3 };
    try std.testing.expect(commands.push(.{ .start_periodic = .{
        .id = 2,
        .bus_index = 0,
        .frame = frame,
        .period_ns = 10,
        .counter = .{ .bit_positions = bit_positions, .bit_length = 4, .little_endian = true, .initial = 0 },
    } }));
    worker.step(100);
    var updated_frame = frame;
    updated_frame.data[1] = 0x44;
    try std.testing.expect(commands.push(.{ .update = .{
        .id = 2,
        .bus_index = 0,
        .frame = updated_frame,
        .period_ns = 10,
        .counter = .{ .bit_positions = bit_positions, .bit_length = 4, .little_endian = true, .initial = 0 },
    } }));
    worker.step(105);
    try std.testing.expectEqual(@as(usize, 1), events.lenApprox());
    worker.step(135);

    try std.testing.expectEqual(@as(u32, 1), active_jobs.load(.acquire));
    try std.testing.expectEqual(@as(u64, 2), skipped_sends.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 2), events.lenApprox());
    var received: [4]Frame = undefined;
    try std.testing.expectEqual(@as(usize, 2), try receiver.read(&received, 0));
    try std.testing.expectEqual(@as(u8, 0), received[0].data[0] & 0x0f);
    try std.testing.expectEqual(@as(u8, 1), received[1].data[0] & 0x0f);
    try std.testing.expectEqual(@as(u8, 0x44), received[1].data[1]);
}

test "50 periodic SocketCAN jobs stay within one millisecond jitter on vcan0" {
    const allocator = std.testing.allocator;
    const backend = @import("../can/registry.zig").find("socketcan") orelse return error.SkipZigTest;
    const channels = try backend.enumerate(allocator);
    defer allocator.free(channels);
    var has_vcan0 = false;
    for (channels) |channel| {
        if (std.mem.eql(u8, channel.nameSlice(), "vcan0")) has_vcan0 = true;
    }
    if (!has_vcan0) return error.SkipZigTest;

    var device = try backend.open(allocator, .{ .channel = "vcan0" });
    defer device.deinit();
    var adapters: [4]?AdapterSlot = @splat(null);
    adapters[0] = .{ .device = &device, .bus_index = 0 };
    var adapter_count: usize = 1;
    var commands: CommandQueue = .{};
    var events: EventQueue = .{};
    var stop: std.atomic.Value(bool) = .init(false);
    var active_jobs: std.atomic.Value(u32) = .init(0);
    var skipped_sends: std.atomic.Value(u64) = .init(0);
    var worker = Worker{
        .io = std.testing.io,
        .adapters = &adapters,
        .adapter_count = &adapter_count,
        .commands = &commands,
        .events = &events,
        .stop = &stop,
        .active_jobs = &active_jobs,
        .skipped_sends = &skipped_sends,
    };
    try worker.start();
    for (0..50) |index| {
        const frame = Frame{
            .timestamp_ns = 0,
            .id = 0x500 + @as(u32, @intCast(index)),
            .bus = 0,
            .len = 8,
            .flags = .{},
            ._pad = 0,
            .data = @splat(@intCast(index)),
        };
        try std.testing.expect(commands.push(.{ .start_periodic = .{
            .id = @intCast(index + 1),
            .bus_index = 0,
            .frame = frame,
            .period_ns = 10 * std.time.ns_per_ms,
        } }));
    }
    try std.Io.sleep(std.testing.io, .{ .nanoseconds = 120 * std.time.ns_per_ms }, .awake);
    stop.store(true, .release);
    worker.join();

    var first: [50]?u64 = @splat(null);
    var second: [50]?u64 = @splat(null);
    while (events.pop()) |event| {
        if (event.status != .ok or event.job_id == 0 or event.job_id > 50) continue;
        const index: usize = event.job_id - 1;
        if (first[index] == null) {
            first[index] = event.timestamp_ns;
        } else if (second[index] == null) {
            second[index] = event.timestamp_ns;
        }
    }

    const period_ns = 10 * std.time.ns_per_ms;
    var max_jitter: u64 = 0;
    for (0..50) |index| {
        const elapsed = second[index].? - first[index].?;
        const jitter = if (elapsed > period_ns) elapsed - period_ns else period_ns - elapsed;
        max_jitter = @max(max_jitter, jitter);
    }
    try std.testing.expect(max_jitter < std.time.ns_per_ms);
}
