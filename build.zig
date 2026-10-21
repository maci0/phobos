const std = @import("std");
pub fn build(b: *std.Build) void {
    // phobos is a musl-only project: it links its (vendored) C dependencies
    // against Zig's bundled musl libc rather than the host's libc. We therefore
    // default the *native* target to the musl ABI. An explicit `-Dtarget=...`
    // (e.g. arm-linux-musleabihf) still overrides this default.
    const target = b.standardTargetOptions(.{
        .default_target = .{ .abi = .musl },
    });
    const optimize = b.standardOptimizeOption(.{});
    const softfp = b.option(bool, "softfp", "Use VFPv3 softfp in C sources; Zig keeps software floating point") orelse false;
    if (softfp) validateSoftfp(target.result) catch |err| std.process.fatal("-Dsoftfp: {s}", .{switch (err) {
        error.UnsupportedTarget => "requires little-endian arm-linux-musleabi",
        error.UnsupportedFloatFeatures => "requires VFPv3 with 32 registers and no soft_float CPU feature",
    }});
    const moonraker_version = b.option([]const u8, "moonraker_version", "Reported server software version") orelse "phobos";

    const build_opts = b.addOptions();
    build_opts.addOption([]const u8, "moonraker_version", moonraker_version);
    build_opts.addOption([]const u8, "phobos_version", @import("build.zig.zon").version);

    // Strip debug info from the shipped binary in any release mode (smaller
    // on-disk binary; tests keep symbols for readable failure traces).
    // `-Dprofile` keeps symbols in a release build so perf/flamegraphs resolve
    // function names (see tools/perf_harness).
    const profile = b.option(bool, "profile", "Keep symbols in release builds for profiling") orelse false;
    const release = optimize != .debug and !profile;

    // phobos's DataStore is backed by the vendored SQLite amalgamation
    // (Moonraker `moonraker-sql.db`-compatible), compiled in + linked against
    // Zig's bundled musl libc. The pure-Zig atomic-rename file backend
    // (`store/file_store.zig`) is the dependency-free alternative.
    const mkmod = struct {
        fn f(bb: *std.Build, t: std.Build.ResolvedTarget, o: std.builtin.Optimize, opts: *std.Build.Step.Options, strip: bool, c_softfp: bool) *std.Build.Module {
            const m = bb.createModule(.{
                .root_source_file = bb.path("src/main.zig"),
                .target = t,
                .optimize = o,
                .link_libc = true,
                .strip = strip,
                // Keep frame pointers when unstripped (profiling/tests) so perf's
                // frame-pointer call-graph unwinds cleanly for flamegraphs.
                .omit_frame_pointer = strip,
            });
            addVendoredSqlite(bb, m, c_softfp);
            const c_flags: []const []const u8 = if (c_softfp) &.{ "-std=c11", "-mfloat-abi=softfp" } else &.{"-std=c11"};
            m.addCSourceFile(.{ .file = bb.path("src/disk_usage.c"), .flags = c_flags });
            m.addCSourceFile(.{ .file = bb.path("src/local_time.c"), .flags = c_flags });
            m.addOptions("build_options", opts);
            return m;
        }
    }.f;

    const exe = b.addExecutable(.{ .name = "phobos", .root_module = mkmod(b, target, optimize, build_opts, release, softfp) });
    // Link-time optimization in release: lets the linker drop unreachable code
    // across the Zig + vendored-C boundary and inline across objects (smaller
    // binary, tighter code). Skipped in Debug (slow, and we want fast iteration).
    if (release) exe.lto = releaseLtoMode(softfp);
    b.installArtifact(exe);

    const float_probe_module = b.createModule(.{
        .root_source_file = b.path("tests/fixtures/float_abi_probe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = release,
    });
    float_probe_module.addCSourceFile(.{
        .file = b.path("tests/fixtures/float_abi_probe.c"),
        .flags = if (softfp) &.{ "-std=c11", "-mfloat-abi=softfp" } else &.{"-std=c11"},
    });
    const float_probe = b.addExecutable(.{ .name = "float-abi-probe", .root_module = float_probe_module });
    if (release) float_probe.lto = releaseLtoMode(softfp);
    b.step("float-abi-probe", "Build the C/Zig floating-point ABI runtime check").dependOn(&b.addInstallArtifact(float_probe, .{}).step);

    // `zig build test --fuzz` runs the std.testing.fuzz harnesses in this
    // artifact with coverage-guided input.
    const timezone_probe_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    timezone_probe_module.addCSourceFiles(.{ .files = &.{ "src/local_time.c", "tests/fixtures/local_time_probe.c" }, .flags = if (softfp) &.{ "-std=c11", "-mfloat-abi=softfp" } else &.{"-std=c11"} });
    const timezone_probe = b.addExecutable(.{ .name = "local-time-probe", .root_module = timezone_probe_module });
    const test_opts = b.addOptions();
    test_opts.addOption([]const u8, "moonraker_version", moonraker_version);
    test_opts.addOption([]const u8, "phobos_version", @import("build.zig.zon").version);
    test_opts.addOptionPath("local_time_probe", timezone_probe.getEmittedBin());
    const unit = b.addTest(.{ .root_module = mkmod(b, target, optimize, test_opts, false, softfp) });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(unit).step);
    b.step("test-artifact", "Build test binary (no run)").dependOn(&unit.step);
}

/// Compile the vendored SQLite amalgamation into `module`. Built with
/// size/feature-reducing defines (no extension loading, no deprecated APIs, no
/// shared cache) to keep the static binary small — SQLite is the heaviest part
/// of the binary, so trim what phobos doesn't use. No -O flag: the module's
/// optimize mode applies, so ReleaseSmall builds SQLite for size (an -O2
/// override made the ReleaseSmall cortex_a7 binary 284,112 bytes larger).
fn addVendoredSqlite(b: *std.Build, module: *std.Build.Module, softfp: bool) void {
    const flags = &[_][]const u8{
        "-DSQLITE_THREADSAFE=1",
        "-DSQLITE_DEFAULT_MEMSTATUS=0",
        "-DSQLITE_DQS=0",
        "-DSQLITE_OMIT_LOAD_EXTENSION",
        "-DSQLITE_OMIT_DEPRECATED",
        "-DSQLITE_OMIT_SHARED_CACHE",
        "-DSQLITE_OMIT_PROGRESS_CALLBACK",
        "-DSQLITE_OMIT_AUTOINIT",
        "-DSQLITE_USE_ALLOCA",
        "-DSQLITE_ENABLE_API_ARMOR",
        "-Wno-unused-parameter",
    };
    module.addIncludePath(b.path("vendor/sqlite"));
    module.addCSourceFiles(.{
        .root = b.path("vendor/sqlite"),
        .files = &.{"sqlite3.c"},
        .flags = if (softfp) flags ++ &[_][]const u8{"-mfloat-abi=softfp"} else flags,
    });
}

fn validateSoftfp(target: std.Target) error{ UnsupportedTarget, UnsupportedFloatFeatures }!void {
    if (target.cpu.arch != .arm or target.os.tag != .linux or target.abi != .musleabi) return error.UnsupportedTarget;
    if (!target.cpu.hasAll(.arm, &.{ .vfp3, .d32 }) or target.cpu.has(.arm, .soft_float)) return error.UnsupportedFloatFeatures;
}

fn releaseLtoMode(softfp: bool) std.zig.LtoMode {
    // Zig 0.17 full LTO changes C softfp calls to VFP registers while Zig keeps the base ABI.
    return if (softfp) .none else .full;
}

test "release LTO preserves the mixed C softfp calling convention" {
    try std.testing.expectEqual(std.zig.LtoMode.none, releaseLtoMode(true));
    try std.testing.expectEqual(std.zig.LtoMode.full, releaseLtoMode(false));
}

test "fuzz release LTO policy keeps every mixed C softfp build out of LTO" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            var bytes: [1]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            const softfp = bytes[0] & 1 != 0;
            switch (releaseLtoMode(softfp)) {
                .none => try std.testing.expect(softfp),
                .full => try std.testing.expect(!softfp),
                .thin => return error.UnexpectedThinLto,
            }
        }
    }.run, .{});
}

test "C softfp accepts VFPv3 soft ABI and rejects incompatible targets" {
    var target = @import("builtin").target;
    target.cpu = std.Target.arm.cpu.generic.toCpu(.arm);
    target.cpu.features = std.Target.arm.featureSet(&.{ .v7a, .vfp3, .d32 });
    target.os.tag = .linux;
    target.abi = .musleabi;
    try validateSoftfp(target);
    target.abi = .musleabihf;
    try std.testing.expectError(error.UnsupportedTarget, validateSoftfp(target));
    target.abi = .musleabi;
    target.cpu.arch = .aarch64;
    try std.testing.expectError(error.UnsupportedTarget, validateSoftfp(target));
    target.cpu.arch = .arm;
    target.cpu.features = std.Target.arm.featureSet(&.{ .v7a, .vfp3d16 });
    try std.testing.expectError(error.UnsupportedFloatFeatures, validateSoftfp(target));
    target.cpu.features = std.Target.arm.featureSet(&.{ .v7a, .soft_float });
    try std.testing.expectError(error.UnsupportedFloatFeatures, validateSoftfp(target));
}

test "fuzz C softfp validation accepts only the declared ARM ABI and FPU" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            var bytes: [8]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            var target = @import("builtin").target;
            target.cpu = std.Target.arm.cpu.generic.toCpu(.arm);
            target.cpu.arch = if (bytes[0] & 1 == 0) .arm else .aarch64;
            target.os.tag = if (bytes[1] & 1 == 0) .linux else .windows;
            target.abi = if (bytes[2] & 1 == 0) .musleabi else .musleabihf;
            if (bytes[3] & 1 == 0) target.cpu.features.addFeature(@backingInt(std.Target.arm.Feature.vfp3));
            if (bytes[4] & 1 == 0) target.cpu.features.addFeature(@backingInt(std.Target.arm.Feature.d32));
            if (bytes[5] & 1 == 0) target.cpu.features.addFeature(@backingInt(std.Target.arm.Feature.soft_float));
            validateSoftfp(target) catch return;
            try std.testing.expectEqual(std.Target.Cpu.Arch.arm, target.cpu.arch);
            try std.testing.expectEqual(std.Target.Os.Tag.linux, target.os.tag);
            try std.testing.expectEqual(std.Target.Abi.musleabi, target.abi);
            try std.testing.expect(target.cpu.hasAll(.arm, &.{ .vfp3, .d32 }));
            try std.testing.expect(!target.cpu.has(.arm, .soft_float));
        }
    }.run, .{});
}
