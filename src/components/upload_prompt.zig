const std = @import("std");

fn safeText(buffer: []u8, value: []const u8) []const u8 {
    var count: usize = 0;
    for (value) |byte| {
        if (count == buffer.len) break;
        const c: u8 = if (byte < 32 or std.mem.indexOfScalar(u8, "\\\";|#*", byte) != null) ' ' else byte;
        if (c == ' ' and (count == 0 or buffer[count - 1] == ' ')) continue;
        buffer[count] = c;
        count += 1;
    }
    while (count != 0 and !std.unicode.utf8ValidateSlice(buffer[0..count])) count -= 1;
    return std.mem.trimEnd(u8, buffer[0..count], " ");
}

pub fn script(alloc: std.mem.Allocator, stage: []const u8, filename: []const u8, detail: []const u8) ![]u8 {
    if (std.mem.eql(u8, stage, "close")) return alloc.dupe(u8, "RESPOND TYPE=command MSG=\"action:prompt_end Preparing G-code 3MF\"");
    var filename_buffer: [180]u8 = undefined;
    var detail_buffer: [180]u8 = undefined;
    const name = safeText(&filename_buffer, std.fs.path.basename(filename));
    const message = safeText(&detail_buffer, detail);
    const failed = std.mem.eql(u8, stage, "failed");
    if (!failed and !std.mem.eql(u8, stage, "stage")) return error.InvalidParams;
    return std.fmt.allocPrint(
        alloc,
        "RESPOND TYPE=command MSG=\"action:prompt_begin {s}\"\n" ++
            "RESPOND TYPE=command MSG=\"action:prompt_text {s}\"\n" ++
            "RESPOND TYPE=command MSG=\"action:prompt_text {s}\"\n{s}" ++
            "RESPOND TYPE=command MSG=\"action:prompt_show\"",
        .{ if (failed) "G-code 3MF preparation failed" else "Preparing G-code 3MF", name, message, if (failed) "RESPOND TYPE=command MSG=\"action:prompt_footer_button OK|RESPOND TYPE=command MSG=action:prompt_end|primary\"\n" else "" },
    );
}

test "upload prompts sanitize filenames and errors and retain dismissible failures" {
    const value = try script(std.testing.allocator, "failed", "a\";\nG28.gcode.3mf", "bad\"|#*");
    defer std.testing.allocator.free(value);
    try std.testing.expect(std.mem.indexOf(u8, value, "action:prompt_text a G28.gcode.3mf") != null);
    try std.testing.expect(std.mem.indexOf(u8, value, "action:prompt_footer_button OK|") != null);
    try std.testing.expect(std.mem.indexOf(u8, value, "MSG=\"action:prompt_text bad\"") != null);
}

test "fuzz upload prompt text is valid UTF-8 without injected control characters" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            var input: [256]u8 = undefined;
            var output: [180]u8 = undefined;
            smith.bytesWithHash(&input, 0);
            const value = safeText(&output, &input);
            try std.testing.expect(std.unicode.utf8ValidateSlice(value));
            try std.testing.expect(std.mem.indexOfAny(u8, value, "\r\n\x00\";|#*\\") == null);
        }
    }.run, .{});
}
