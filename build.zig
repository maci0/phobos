const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const with_lmdb = b.option(bool, "with_lmdb", "Link liblmdb") orelse true;

    const mkmod = struct {
        fn f(bb: *std.Build, t: std.Build.ResolvedTarget, o: std.builtin.OptimizeMode, lmdb: bool) *std.Build.Module {
            const m = bb.createModule(.{
                .root_source_file = bb.path("src/main.zig"),
                .target = t, .optimize = o, .link_libc = lmdb,
            });
            if (lmdb) m.linkSystemLibrary("lmdb", .{});
            return m;
        }
    }.f;

    const exe = b.addExecutable(.{ .name = "phobos", .root_module = mkmod(b, target, optimize, with_lmdb) });
    b.installArtifact(exe);

    const unit = b.addTest(.{ .root_module = mkmod(b, target, optimize, with_lmdb) });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(unit).step);

    const fuzz = b.addTest(.{ .root_module = mkmod(b, target, optimize, with_lmdb) });
    const fuzz_run = b.addRunArtifact(fuzz);
    b.step("fuzz", "Run fuzz harnesses").dependOn(&fuzz_run.step);
}
