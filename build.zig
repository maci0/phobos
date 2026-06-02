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
    const with_lmdb = b.option(bool, "with_lmdb", "Compile vendored liblmdb datastore backend") orelse true;
    const moonraker_version = b.option([]const u8, "moonraker_version", "Reported server software version") orelse "phobos";

    const build_opts = b.addOptions();
    build_opts.addOption([]const u8, "moonraker_version", moonraker_version);
    build_opts.addOption(bool, "with_lmdb", with_lmdb);

    const mkmod = struct {
        fn f(bb: *std.Build, t: std.Build.ResolvedTarget, o: std.builtin.OptimizeMode, lmdb: bool, opts: *std.Build.Step.Options) *std.Build.Module {
            const m = bb.createModule(.{
                .root_source_file = bb.path("src/main.zig"),
                .target = t,
                .optimize = o,
                .link_libc = lmdb,
            });
            if (lmdb) addVendoredLmdb(bb, m);
            m.addOptions("build_options", opts);
            return m;
        }
    }.f;

    const exe = b.addExecutable(.{ .name = "phobos", .root_module = mkmod(b, target, optimize, with_lmdb, build_opts) });
    b.installArtifact(exe);

    const unit = b.addTest(.{ .root_module = mkmod(b, target, optimize, with_lmdb, build_opts) });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(unit).step);

    const fuzz = b.addTest(.{ .root_module = mkmod(b, target, optimize, with_lmdb, build_opts) });
    const fuzz_run = b.addRunArtifact(fuzz);
    b.step("fuzz", "Run fuzz harnesses").dependOn(&fuzz_run.step);
}

/// Compile the vendored liblmdb C sources into `module` and expose its headers.
/// We vendor `vendor/lmdb/{mdb.c,midl.c}` rather than linking a system
/// liblmdb so the on-disk format is pinned and the build is fully static.
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
