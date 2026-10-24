const std = @import("std");

pub const Profile = enum {
    moonraker,
    forge_x,

    pub fn parse(value: []const u8) !Profile {
        if (std.mem.eql(u8, value, "moonraker")) return .moonraker;
        if (std.mem.eql(u8, value, "forge-x")) return .forge_x;
        return error.InvalidCompatibilityProfile;
    }

    pub fn name(self: Profile) []const u8 {
        return switch (self) {
            .moonraker => "moonraker",
            .forge_x => "forge-x",
        };
    }
};

test "compatibility profiles accept only documented names" {
    inline for (std.meta.tags(Profile)) |profile| try std.testing.expectEqual(profile, try Profile.parse(profile.name()));
    try std.testing.expectError(error.InvalidCompatibilityProfile, Profile.parse("forge_x"));
}

test "fuzz compatibility profile parsing" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            var buf: [64]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            if (Profile.parse(&buf)) |profile| try std.testing.expectEqualStrings(&buf, profile.name()) else |_| {}
        }
    }.run, .{});
}
