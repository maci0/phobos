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
    const moonraker_version = b.option([]const u8, "moonraker_version", "Reported server software version") orelse "phobos";

    const build_opts = b.addOptions();
    build_opts.addOption([]const u8, "moonraker_version", moonraker_version);

    // Strip debug info from the shipped binary in any release mode (smaller
    // on-disk binary; tests keep symbols for readable failure traces).
    const release = optimize != .Debug;

    // phobos always uses the vendored LMDB datastore (links libc + compiles the
    // vendored C). There is no no-lmdb / NullStore fallback.
    const mkmod = struct {
        fn f(bb: *std.Build, t: std.Build.ResolvedTarget, o: std.builtin.OptimizeMode, opts: *std.Build.Step.Options, strip: bool) *std.Build.Module {
            const m = bb.createModule(.{
                .root_source_file = bb.path("src/main.zig"),
                .target = t,
                .optimize = o,
                .link_libc = true,
                .strip = strip,
            });
            addVendoredLmdb(bb, m);
            addVendoredSqlite(bb, m);
            m.addOptions("build_options", opts);
            return m;
        }
    }.f;

    const exe = b.addExecutable(.{ .name = "phobos", .root_module = mkmod(b, target, optimize, build_opts, release) });
    // Link-time optimization in release: lets the linker drop unreachable code
    // across the Zig + vendored-C boundary and inline across objects (smaller
    // binary, tighter code). Skipped in Debug (slow, and we want fast iteration).
    if (release) exe.lto = .full;
    b.installArtifact(exe);

    const unit = b.addTest(.{ .root_module = mkmod(b, target, optimize, build_opts, false) });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(unit).step);
    b.step("test-artifact", "Build test binary (no run)").dependOn(&unit.step);

    const fuzz = b.addTest(.{ .root_module = mkmod(b, target, optimize, build_opts, false) });
    const fuzz_run = b.addRunArtifact(fuzz);
    b.step("fuzz", "Run fuzz harnesses").dependOn(&fuzz_run.step);
}

/// Compile the vendored liblmdb C sources into `module` and expose its headers.
/// We vendor `vendor/lmdb/{mdb.c,midl.c}` rather than linking a system
/// liblmdb so the on-disk format is pinned and the build is fully static.
/// Compile the vendored SQLite amalgamation into `module`. Built with
/// size/feature-reducing defines (no extension loading, no deprecated APIs, no
/// shared cache) to keep the static binary small — SQLite is the heaviest part
/// of the binary, so trim what phobos doesn't use.
fn addVendoredSqlite(b: *std.Build, module: *std.Build.Module) void {
    module.addIncludePath(b.path("vendor/sqlite"));
    module.addCSourceFiles(.{
        .root = b.path("vendor/sqlite"),
        .files = &.{"sqlite3.c"},
        .flags = &.{
            "-O2",
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
        },
    });
}

fn addVendoredLmdb(b: *std.Build, module: *std.Build.Module) void {
    module.addIncludePath(b.path("vendor/lmdb"));
    module.addCSourceFiles(.{
        .root = b.path("vendor/lmdb"),
        .files = &.{ "mdb.c", "midl.c" },
        .flags = &.{
            "-O2",
            "-pthread",
            // LMDB's own recommended portable flags. It deliberately avoids
            // _GNU_SOURCE; these silence the warnings it expects from libc.
            "-Wno-unused-parameter",
            "-Wno-format-extra-args",
            "-Wbad-function-cast",
            "-Wuninitialized",
        },
    });
}
