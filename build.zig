const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const os = target.result.os.tag;
    const abi = target.result.abi;
    const peak_default = os == .windows or (os == .linux and abi.isGnu());
    const peak = b.option(bool, "peak", "Enable the PEAK PCAN-Basic backend (loaded at runtime)") orelse peak_default;
    if (peak and os == .linux and !abi.isGnu()) {
        @panic("-Dpeak=true on Linux requires a *-linux-gnu target (libpcanbasic.so needs glibc)");
    }
    if (peak and os != .linux and os != .windows) {
        @panic("-Dpeak=true is only supported on Linux and Windows targets");
    }

    const options = b.addOptions();
    options.addOption(bool, "peak", peak);

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root.addOptions("build_options", options);
    // PCAN-Basic needs glibc on Linux; static-musl builds still link their static
    // libc so ReleaseFast math routines such as ldexp resolve without dynlibs.
    if (os == .linux and (peak or abi == .musl)) root.link_libc = true;
    // ReleaseFast's math lowering uses ldexp from the Windows C runtime too.
    if (os == .windows and optimize == .fast) root.link_libc = true;

    if (b.lazyDependency("can_dbz", .{ .target = target, .optimize = optimize })) |dep| {
        root.addImport("can_dbz", dep.module("can_dbz"));
    }
    if (b.lazyDependency("zigzag", .{ .target = target, .optimize = optimize })) |dep| {
        root.addImport("zigzag", dep.module("zigzag"));
    }

    const exe = b.addExecutable(.{
        .name = "can_dbz_vis",
        .root_module = root,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run can_dbz_vis");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = root });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const check_step = b.step("check", "Compile the app and unit tests");
    check_step.dependOn(&exe.step);
    check_step.dependOn(&tests.step);
    b.default_step.dependOn(check_step);

    const bench_module = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    if (b.lazyDependency("can_dbz", .{ .target = target, .optimize = .ReleaseFast })) |dep| {
        bench_module.addImport("can_dbz", dep.module("can_dbz"));
    }
    const bench_exe = b.addExecutable(.{
        .name = "can_dbz_vis_bench",
        .root_module = bench_module,
    });
    const bench_run = b.addRunArtifact(bench_exe);
    bench_run.addPassthruArgs();
    const bench_step = b.step("bench", "Run the configurable headless virtual-CAN engine benchmark");
    bench_step.dependOn(&bench_run.step);
}
