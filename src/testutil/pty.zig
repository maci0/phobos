//! Owned pseudo-terminal fixture for serial protocols, with bounded peer I/O.
const std = @import("std");
const Serial = @import("../components/serial.zig").Serial;

pub const Pty = struct {
    master: Serial,
    path_buf: [64]u8,
    path_len: usize,

    pub fn init(io: std.Io) !Pty {
        const master = try std.Io.Dir.cwd().openFile(io, "/dev/ptmx", .{ .mode = .read_write });
        errdefer master.close(io);
        var unlock: c_int = 0;
        if ((try io.operate(.{ .device_io_control = .{ .file = master, .code = std.os.linux.T.IOCSPTLCK, .arg = &unlock } })).device_io_control != 0)
            return error.PtyUnlock;
        var number: c_uint = undefined;
        if ((try io.operate(.{ .device_io_control = .{ .file = master, .code = std.os.linux.T.IOCGPTN, .arg = &number } })).device_io_control != 0)
            return error.PtyNumber;
        var self: Pty = .{ .master = .{ .io = io, .file = master }, .path_buf = undefined, .path_len = 0 };
        self.path_len = (try std.fmt.bufPrint(&self.path_buf, "/dev/pts/{d}", .{number})).len;
        return self;
    }

    pub fn path(self: *const Pty) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    pub fn deinit(self: *Pty) void {
        self.master.close();
    }
};
