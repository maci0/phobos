//! Lightweight gcode metadata parser — extracts slicer name, layer count,
//! filament usage, estimated print time, and embedded thumbnails from gcode
//! comment headers. Pure functions: all parsing operates on a `[]const u8`
//! slice so callers can feed file contents without any I/O in the parser.
//!
//! Mirror of the logic in `vendor/moonraker/moonraker/components/file_manager/metadata.py`
//! (BaseSlicer + subclasses), simplified to the subset phobos needs for
//! faithful `buildMetadata` records: slicer identification, filament_total,
//! estimated_time, layer_count, first_layer_extr_temp, first_layer_bed_temp,
//! and embedded base64 thumbnails.

const std = @import("std");

/// Parsed gcode header metadata. All fields are optional/defaulted; callers
/// overlay only the ones that were found on top of the stat-based record.
pub const GcodeMetadata = struct {
    slicer: ?[]const u8 = null,
    slicer_version: ?[]const u8 = null,
    layer_count: ?i64 = null,
    estimated_time: ?f64 = null,
    filament_total: ?f64 = null,
    filament_weight_total: ?f64 = null,
    first_layer_extr_temp: ?f64 = null,
    first_layer_bed_temp: ?f64 = null,
    layer_height: ?f64 = null,
    object_height: ?f64 = null,
    nozzle_diameter: ?f64 = null,
    /// Thumbnail entries: {width, height, size, data (base64 string)}.
    thumbnails: []Thumbnail = &.{},
};

/// A single embedded thumbnail parsed from a `; thumbnail begin … end` block.
/// Caller owns `data` and frees it with the parser allocator.
pub const Thumbnail = struct {
    width: i64,
    height: i64,
    size: i64,
    data: []const u8,
};

/// Parse gcode header text and return extracted metadata. The caller owns the
/// returned `GcodeMetadata`. String fields borrow `text`; free each thumbnail's
/// `data`, then the thumbnail slice, with `alloc`.
pub fn parse(alloc: std.mem.Allocator, text: []const u8) GcodeMetadata {
    var m: GcodeMetadata = .{};

    // Detect slicer.
    if (detectPrusaSlicer(text)) |slicer| {
        m.slicer = slicer.name;
        m.slicer_version = slicer.version;
    } else if (detectCura(text)) |slicer| {
        m.slicer = slicer.name;
        m.slicer_version = slicer.version;
    } else if (detectSimplify3D(text)) |slicer| {
        m.slicer = slicer.name;
        m.slicer_version = slicer.version;
    } else if (detectIdeaMaker(text)) |slicer| {
        m.slicer = slicer.name;
        m.slicer_version = slicer.version;
    } else if (detectKISSlicer(text)) |slicer| {
        m.slicer = slicer.name;
        m.slicer_version = slicer.version;
    }

    // Parse values that are independent of slicer family.
    m.layer_count = parseLayerCount(text);
    m.estimated_time = findEstimatedTime(text);
    m.filament_total = findFilamentTotal(text);
    m.filament_weight_total = findFilamentWeightTotal(text);
    m.first_layer_extr_temp = findFirstLayerExtrTemp(text);
    m.first_layer_bed_temp = findFirstLayerBedTemp(text);
    m.layer_height = findLayerHeight(text);
    m.object_height = findObjectHeight(text);
    m.nozzle_diameter = findNozzleDiameter(text);
    m.thumbnails = parseThumbnails(alloc, text) catch &.{};

    return m;
}

/// Parse using both the file header AND footer. PrusaSlicer / OrcaSlicer /
/// BambuStudio write their config block (estimated time, filament totals,
/// temps, layer height, nozzle, and the final G1 Z moves) at the END of the
/// file, so a header-only scan misses them on real prints. Header values win;
/// the footer fills any gaps. String fields borrow `header`/`footer`, which the
/// caller must keep alive while the result is in use.
pub fn parseFull(alloc: std.mem.Allocator, header: []const u8, footer: []const u8) GcodeMetadata {
    var m = parse(alloc, header);
    if (footer.len == 0 or footer.ptr == header.ptr) return m;

    if (m.slicer == null) {
        if (detectPrusaSlicer(footer) orelse detectCura(footer) orelse
            detectSimplify3D(footer) orelse detectIdeaMaker(footer) orelse
            detectKISSlicer(footer)) |s|
        {
            m.slicer = s.name;
            m.slicer_version = s.version;
        }
    }
    if (m.layer_count == null) m.layer_count = parseLayerCount(footer);
    if (m.estimated_time == null) m.estimated_time = findEstimatedTime(footer);
    if (m.filament_total == null) m.filament_total = findFilamentTotal(footer);
    if (m.filament_weight_total == null) m.filament_weight_total = findFilamentWeightTotal(footer);
    if (m.first_layer_extr_temp == null) m.first_layer_extr_temp = findFirstLayerExtrTemp(footer);
    if (m.first_layer_bed_temp == null) m.first_layer_bed_temp = findFirstLayerBedTemp(footer);
    if (m.layer_height == null) m.layer_height = findLayerHeight(footer);
    if (m.nozzle_diameter == null) m.nozzle_diameter = findNozzleDiameter(footer);
    // object_height: Z grows toward the end, so the footer usually carries the
    // true maximum — take the larger of header/footer.
    if (findObjectHeight(footer)) |fz| {
        if (m.object_height == null or fz > m.object_height.?) m.object_height = fz;
    }
    return m;
}

// ---------------------------------------------------------------------------
// Slicer-specific detection
// ---------------------------------------------------------------------------

const SlicerInfo = struct { name: []const u8, version: []const u8 };

/// Match `; generated by <Name> <Version> on YYYY-MM-DD at HH:MM:SS UTC`
/// Pattern used by PrusaSlicer, SuperSlicer, OrcaSlicer, BambuStudio, etc.
fn detectPrusaSlicer(text: []const u8) ?SlicerInfo {
    const prefix = "; generated by ";
    const idx = std.mem.indexOf(u8, text, prefix) orelse return null;
    const start = idx + prefix.len;
    const line_end = scanLineEnd(text, start);

    // Now find " on " within this slice to get the version delimiter.
    const rest = text[start..line_end];
    const on_idx = std.mem.lastIndexOf(u8, rest, " on ") orelse return null;

    const name_and_ver = rest[0..on_idx];
    // Version is the last space-separated word; name is everything before it.
    const last_space = std.mem.lastIndexOfScalar(u8, name_and_ver, ' ') orelse return null;
    return SlicerInfo{
        .name = name_and_ver[0..last_space],
        .version = name_and_ver[last_space + 1 ..],
    };
}

/// Match Cura-style headers: `; sliced by <Name> <Version>` or
/// `;Sliced by <name> <version>` or `; sliced with <name> <version>`.
fn detectCura(text: []const u8) ?SlicerInfo {
    const patterns = [_][]const u8{
        "; sliced by ",
        ";Sliced by ",
        "; sliced with ",
        ";Sliced with ",
        "; generated with ",
    };
    for (patterns) |prefix| {
        if (std.mem.indexOf(u8, text, prefix)) |idx| {
            const start = idx + prefix.len;
            const line_end = scanLineEnd(text, start);
            const rest = text[start..line_end];
            // Version is the last space-separated token.
            const last_space = std.mem.lastIndexOfScalar(u8, rest, ' ') orelse return null;
            return SlicerInfo{
                .name = rest[0..last_space],
                .version = rest[last_space + 1 ..],
            };
        }
    }
    return null;
}

/// Match Simplify3D: `; Simplify3D(R) Version <version>`
fn detectSimplify3D(text: []const u8) ?SlicerInfo {
    const prefix = "; Simplify3D";
    const idx = std.mem.indexOf(u8, text, prefix) orelse return null;
    // Look for "Version " after the prefix on the same line.
    const start = idx;
    const line_end = scanLineEnd(text, start);
    const line = text[start..line_end];
    const ver_prefix = "Version ";
    if (std.mem.indexOf(u8, line, ver_prefix)) |vi| {
        const ver_start = vi + ver_prefix.len;
        const ver_end = std.mem.findAnyPos(u8, line, ver_start, &std.ascii.whitespace) orelse line.len;
        return SlicerInfo{ .name = "Simplify3D", .version = line[ver_start..ver_end] };
    }
    return SlicerInfo{ .name = "Simplify3D", .version = "" };
}

/// Match KISSlicer: `; KISSlicer` or `; KISSlicer <version>`
fn detectKISSlicer(text: []const u8) ?SlicerInfo {
    const prefix = "; KISSlicer";
    const idx = std.mem.indexOf(u8, text, prefix) orelse return null;
    const start = idx + prefix.len;
    const line_end = scanLineEnd(text, start);
    var rest = std.mem.trim(u8, text[start..line_end], " \t\r");
    // If there's a version token after the prefix, use it.
    if (rest.len > 0) {
        // Split on first space to separate potential version
        if (std.mem.indexOfScalar(u8, rest, ' ')) |sp| {
            rest = rest[0..sp];
        }
    }
    return SlicerInfo{ .name = "KISSlicer", .version = rest };
}

/// Match IdeaMaker: `; ideaMaker` or `; ideaMaker <version>`
fn detectIdeaMaker(text: []const u8) ?SlicerInfo {
    const prefix = "; ideaMaker";
    const idx = std.mem.indexOf(u8, text, prefix) orelse return null;
    const start = idx + prefix.len;
    const line_end = scanLineEnd(text, start);
    var rest = std.mem.trim(u8, text[start..line_end], " \t\r");
    if (rest.len > 0) {
        if (std.mem.indexOfScalar(u8, rest, ' ')) |sp| {
            rest = rest[0..sp];
        }
    }
    return SlicerInfo{ .name = "ideaMaker", .version = rest };
}

// ---------------------------------------------------------------------------
// Value parsers
// ---------------------------------------------------------------------------

/// Scan for `;LAYER_COUNT:<int>` (Cura) or `; layer_count: <int>` (IceSL)
/// or count `;LAYER_CHANGE` occurrences.
fn parseLayerCount(text: []const u8) ?i64 {
    // Direct declarations first.
    const patterns = [_][]const u8{
        ";LAYER_COUNT:",
        "; layer_count:",
        "; layer_count :",
        ";Layer count:",
        "; total layer number:",
        "; total layers count =",
    };
    for (patterns) |prefix| {
        if (findIntAfterPrefix(text, prefix)) |v| return v;
    }

    // Fall back: count ;LAYER_CHANGE lines (common in PrusaSlicer/Cura output).
    var count: i64 = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, trimmed, ";LAYER_CHANGE")) count += 1;
    }
    return if (count > 0) count else null;
}

/// Scan for estimated print time in various formats.
fn findEstimatedTime(text: []const u8) ?f64 {
    // "; estimated printing time (normal mode) = <float>s"  (PrusaSlicer)
    const normal_prefix = "; estimated printing time (normal mode) =";
    if (std.mem.indexOf(u8, text, normal_prefix)) |idx| {
        const start = idx + normal_prefix.len;
        const duration = std.mem.trim(u8, text[start..scanLineEnd(text, start)], " \t\r");
        const scalar: ?f64 = std.fmt.parseFloat(f64, duration) catch null;
        if (scalar) |value| return if (std.math.isFinite(value) and value >= 0) value else null;
        var parts = std.mem.tokenizeAny(u8, duration, " \t\r");
        var total: f64 = 0;
        var found = false;
        while (parts.next()) |part| {
            if (part.len < 2) return null;
            const scale: f64 = switch (part[part.len - 1]) {
                'd' => 86400,
                'h' => 3600,
                'm' => 60,
                's' => 1,
                else => return null,
            };
            const value = std.fmt.parseFloat(f64, part[0 .. part.len - 1]) catch return null;
            if (!std.math.isFinite(value) or value < 0) return null;
            total += value * scale;
            if (!std.math.isFinite(total)) return null;
            found = true;
        }
        if (found) return total;
    }
    // "; estimated printing time = <float>"  (Cura)
    if (findFloatAfterPrefix(text, "; estimated printing time =")) |v| return v;
    // "; TIME:<float>" (Simplify3D, Slic3r)
    if (findFloatAfterPrefix(text, "; TIME:")) |v| return v;
    // ";Build time: <HH:MM>" — parse as total seconds
    if (findBuildTime(text)) |v| return v;
    // "; estimated printing time: <float>" (some forks)
    if (findFloatAfterPrefix(text, "; estimated printing time:")) |v| return v;
    // "; print_time = <float>" (PrusaSlicer config data)
    if (findFloatAfterPrefix(text, "; print_time =")) |v| return v;
    return null;
}

/// Parse ";Build time: <HH> hours <MM> minutes" or ";Build time: <MM> minutes"
fn findBuildTime(text: []const u8) ?f64 {
    const prefix = ";Build time: ";
    const idx = std.mem.indexOf(u8, text, prefix) orelse return null;
    const start = idx + prefix.len;
    const line_end = scanLineEnd(text, start);
    const line = std.mem.trim(u8, text[start..line_end], " \t\r");
    var total: f64 = 0;
    var rest = line;

    // Match "<N> hours"
    if (std.mem.indexOf(u8, rest, "hours")) |hpos| {
        const num_str = std.mem.trim(u8, rest[0..hpos], " \t");
        const h = std.fmt.parseFloat(f64, num_str) catch return null;
        total += h * 3600.0;
        rest = rest[hpos + 5 ..];
    }
    // Match "<N> minutes"
    if (std.mem.indexOf(u8, rest, "minutes")) |_| {
        const after_hours = if (std.mem.indexOfScalar(u8, rest, ',') orelse std.mem.indexOfScalar(u8, rest, ' ')) |idx2| blk: {
            break :blk rest[idx2 + 1 ..];
        } else rest;
        const mpos = std.mem.indexOf(u8, after_hours, "minutes") orelse return null;
        const num_str = std.mem.trim(u8, after_hours[0..mpos], " \t");
        const m = std.fmt.parseFloat(f64, num_str) catch return null;
        total += m * 60.0;
    } else if (total == 0) {
        // Just minutes: "<N> minutes"
        const m_str = std.mem.trim(u8, rest, " \t");
        const m = std.fmt.parseFloat(f64, m_str) catch return null;
        total = m * 60.0;
    }
    return if (total > 0) total else null;
}

/// Scan for total filament used in mm.
fn findFilamentTotal(text: []const u8) ?f64 {
    // "; filament used [mm] = <float>" (PrusaSlicer)
    if (findFloatAfterPrefix(text, "; filament used [mm] =")) |v| return v;
    // "; total filament length [mm] = <float>"
    if (findFloatAfterPrefix(text, "; total filament length [mm] =")) |v| return v;
    // ";Filament used: <float>m" (Simplify3D v5, may be in meters)
    if (findFloatAfterPrefix(text, ";Filament used:")) |v| return v;
    // "; filament_length = <float>" (PrusaSlicer config)
    if (findFloatAfterPrefix(text, "; filament_length =")) |v| return v;
    // "; total filament length = <float>"
    if (findFloatAfterPrefix(text, "; total filament length =")) |v| return v;
    // ";Filament used [mm] = <float>"
    if (findFloatAfterPrefix(text, ";Filament used [mm] =")) |v| return v;
    return null;
}

/// Scan for total filament weight in grams.
fn findFilamentWeightTotal(text: []const u8) ?f64 {
    // "; total filament used [g] = <float>" (PrusaSlicer)
    if (findFloatAfterPrefix(text, "; total filament used [g] =")) |v| return v;
    // "; total filament weight [g] : <float>" (Cura)
    if (findFloatAfterPrefix(text, "; total filament weight [g] :")) |v| return v;
    if (findFloatAfterPrefix(text, "; total filament weight [g] =")) |v| return v;
    // "; filament used [g] = <float1>,<float2>,..." (PrusaSlicer) — sum weights
    if (findSumFloatsAfterPrefix(text, "; filament used [g] =")) |v| return v;
    // "; filament mass_g = <float>" (some forks)
    if (findFloatAfterPrefix(text, "; filament mass_g =")) |v| return v;
    // "; filament weight [g] = <float>" (OrcaSlicer)
    if (findFloatAfterPrefix(text, "; filament weight [g] =")) |v| return v;
    // ";Filament weight = [<float1>, <float2>, ...]" (Simplify3D) — sum
    if (findBracketedSumFloats(text, ";Filament weight =")) |v| return v;
    return null;
}

/// Scan for nozzle diameter.
fn findNozzleDiameter(text: []const u8) ?f64 {
    // "; nozzle_diameter = <float>" (PrusaSlicer/SuperSlicer config)
    if (findFloatAfterPrefix(text, "; nozzle_diameter =")) |v| return v;
    // "; nozzle_diameter_mm_0 : <float>" (BambuStudio)
    if (findFloatAfterPrefix(text, "; nozzle_diameter_mm_0 :")) |v| return v;
    if (findFloatAfterPrefix(text, "; nozzle_diameter_mm_0:")) |v| return v;
    return null;
}

/// Helper: find a comma-separated list of floats after prefix and return their sum.
fn findSumFloatsAfterPrefix(text: []const u8, prefix: []const u8) ?f64 {
    const idx = std.mem.indexOf(u8, text, prefix) orelse return null;
    const start = idx + prefix.len;
    const line_end = scanLineEnd(text, start);
    const num_str = std.mem.trim(u8, text[start..line_end], " \t\r");
    var sum: f64 = 0;
    var count: usize = 0;
    var tok_it = std.mem.tokenizeScalar(u8, num_str, ',');
    while (tok_it.next()) |tok| {
        const trimmed = std.mem.trim(u8, tok, " \t");
        if (std.fmt.parseFloat(f64, trimmed)) |f| {
            sum += f;
            count += 1;
        } else |_| {}
    }
    return if (count > 0) sum else null;
}

/// Helper: find floats inside brackets "[...]" after prefix and return their sum.
fn findBracketedSumFloats(text: []const u8, prefix: []const u8) ?f64 {
    const idx = std.mem.indexOf(u8, text, prefix) orelse return null;
    var start = std.mem.findNonePos(u8, text, idx + prefix.len, " \t") orelse text.len;
    if (start >= text.len or text[start] != '[') return null;
    start += 1; // skip '['
    const line_end = scanLineEnd(text, start);
    var end = line_end;
    if (end > start and text[end - 1] == ']') end -= 1;
    const inside = text[start..end];
    var sum: f64 = 0;
    var count: usize = 0;
    var tok_it = std.mem.tokenizeScalar(u8, inside, ',');
    while (tok_it.next()) |tok| {
        const trimmed = std.mem.trim(u8, tok, " \t");
        if (std.fmt.parseFloat(f64, trimmed)) |f| {
            sum += f;
            count += 1;
        } else |_| {}
    }
    return if (count > 0) sum else null;
}

/// First layer extruder temperature.
fn findFirstLayerExtrTemp(text: []const u8) ?f64 {
    const patterns = [_][]const u8{
        "; first_layer_temperature =",
        "; first_layer_extr_temperature =",
        "; nozzle_temperature =",
        "; first_layer_print_temperature =",
    };
    for (patterns) |prefix| {
        if (findFloatAfterPrefix(text, prefix)) |v| return v;
    }
    return null;
}

/// First layer bed temperature.
fn findFirstLayerBedTemp(text: []const u8) ?f64 {
    const patterns = [_][]const u8{
        "; first_layer_bed_temperature =",
        "; bed_temperature =",
        "; first_layer_bed_temp =",
    };
    for (patterns) |prefix| {
        if (findFloatAfterPrefix(text, prefix)) |v| return v;
    }
    return null;
}

/// Layer height from config comment.
fn findLayerHeight(text: []const u8) ?f64 {
    const patterns = [_][]const u8{
        "; layer_height =",
        "; layer height =",
        ";Layer height:",
    };
    for (patterns) |prefix| {
        if (findFloatAfterPrefix(text, prefix)) |v| return v;
    }
    return null;
}

/// Object height from max Z coordinate. Matches common slicer patterns:
///   - PrusaSlicer:  max of `;BEFORE_LAYER_CHANGE\n;<Z>` values
///   - Cura:         `; max_z_height: <float>`
///   - Simplify3D:   `;MAXZ:<float>`
///   - Slic3r PE:    `;Bounding Box: X Y Z` (third float)
///   - BambuStudio:  `; print_height_mm : <float>`
///   - Fallback:     max `G1 Z<float>` in the entire text
fn findObjectHeight(text: []const u8) ?f64 {
    // Cura-style direct declaration.
    if (findFloatAfterPrefix(text, "; max_z_height:")) |v| return v;
    if (findFloatAfterPrefix(text, "; max_z_height =")) |v| return v;

    // Simplify3D direct declaration.
    if (findFloatAfterPrefix(text, ";MAXZ:")) |v| return v;

    // BambuStudio / OrcaSlicer config.
    if (findFloatAfterPrefix(text, "; print_height_mm :")) |v| return v;
    if (findFloatAfterPrefix(text, "; print_height_mm:")) |v| return v;

    // Slic3r PE: ";Bounding Box: X Y Z"
    if (std.mem.indexOf(u8, text, ";Bounding Box:")) |idx| {
        const start = idx + ";Bounding Box:".len;
        const line_end = scanLineEnd(text, start);
        const line = text[start..line_end];
        var floats: [3]f64 = @splat(0);
        var fi: usize = 0;
        var tok_it = std.mem.tokenizeScalar(u8, line, ' ');
        while (tok_it.next()) |tok| {
            if (fi >= 3) break;
            floats[fi] = std.fmt.parseFloat(f64, tok) catch continue;
            fi += 1;
        }
        if (fi >= 3) return floats[2]; // Z is the third coordinate
    }

    // PrusaSlicer: semicolon-prefixed Z values after BEFORE_LAYER_CHANGE.
    if (findMaxBeforeLayerChange(text)) |v| return v;

    // Fallback: scan for max G1/G0 Z value in the text.
    return findMaxG1Z(text);
}

/// Scan `;BEFORE_LAYER_CHANGE\n;<Z>` blocks and return the maximum Z.
fn findMaxBeforeLayerChange(text: []const u8) ?f64 {
    const tag = ";BEFORE_LAYER_CHANGE";
    var max_z: ?f64 = null;
    var search_start: usize = 0;
    while (std.mem.indexOf(u8, text[search_start..], tag)) |rel_idx| {
        const tag_idx = search_start + rel_idx;
        // Move past the tag line.
        const tag_line_end = scanLineEnd(text, tag_idx);
        var next_start = tag_line_end;
        if (next_start < text.len and text[next_start] == '\n') next_start += 1;
        if (next_start >= text.len) break;

        // The next line should be "; <Z>"
        const zline_end = scanLineEnd(text, next_start);
        const zline = text[next_start..zline_end];
        // Skip leading "; " or ";"
        var zstr = zline;
        if (zstr.len >= 2 and zstr[0] == ';' and zstr[1] == ' ') {
            zstr = zstr[2..];
        } else if (zstr.len >= 1 and zstr[0] == ';') {
            zstr = zstr[1..];
        }
        if (std.fmt.parseFloat(f64, zstr)) |z| {
            if (max_z == null or z > max_z.?) max_z = z;
        } else |_| {}

        search_start = tag_idx + tag.len;
    }
    return max_z;
}

/// Scan for `G1 Z<float>` (or `G0 Z<float>`) and return the maximum Z found.
fn findMaxG1Z(text: []const u8) ?f64 {
    var max_z: ?f64 = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        // Match "G1 Z..." or "G0 Z..."
        if (!std.mem.startsWith(u8, trimmed, "G1 ") and !std.mem.startsWith(u8, trimmed, "G0 ")) continue;
        // Find Z parameter.
        if (std.mem.indexOf(u8, trimmed, "Z")) |zi| {
            // Make sure Z is at a parameter boundary (preceded by space or at start after Gx).
            if (zi > 0 and trimmed[zi - 1] != ' ') continue;
            const zstart = zi + 1;
            if (zstart >= trimmed.len) continue;
            const zend = std.mem.findNonePos(u8, trimmed, zstart, "0123456789.-") orelse trimmed.len;
            if (zend == zstart) continue;
            if (std.fmt.parseFloat(f64, trimmed[zstart..zend])) |z| {
                if (max_z == null or z > max_z.?) max_z = z;
            } else |_| {}
        }
    }
    return max_z;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn scanLineEnd(text: []const u8, start: usize) usize {
    return std.mem.findAnyPos(u8, text, start, "\r\n") orelse text.len;
}

fn findIntAfterPrefix(text: []const u8, prefix: []const u8) ?i64 {
    const idx = std.mem.indexOf(u8, text, prefix) orelse return null;
    const start = idx + prefix.len;
    const line_end = scanLineEnd(text, start);
    const num_str = std.mem.trim(u8, text[start..line_end], " \t\r");
    return std.fmt.parseInt(i64, num_str, 10) catch null;
}

fn findFloatAfterPrefix(text: []const u8, prefix: []const u8) ?f64 {
    const idx = std.mem.indexOf(u8, text, prefix) orelse return null;
    const start = idx + prefix.len;
    const line_end = scanLineEnd(text, start);
    const num_str = std.mem.trim(u8, text[start..line_end], " \t\rs");
    // Strip trailing 's' (seconds) or 'm' (meters) suffix.
    var n = num_str;
    if (n.len > 0 and (n[n.len - 1] == 's' or n[n.len - 1] == 'm')) {
        n = n[0 .. n.len - 1];
    }
    return std.fmt.parseFloat(f64, n) catch null;
}

// ---------------------------------------------------------------------------
// Thumbnail parser
// ---------------------------------------------------------------------------

/// Parse embedded base64 thumbnails from the standard Moonraker format:
///   ; thumbnail begin <W>x<H> <len>
///   ; <base64 lines...>
///   ; thumbnail end
///
/// Caller owns the returned slice and each thumbnail's `data` allocation.
fn parseThumbnails(alloc: std.mem.Allocator, text: []const u8) ![]Thumbnail {
    var list: std.ArrayList(Thumbnail) = .empty;
    errdefer {
        for (list.items) |thumb| alloc.free(thumb.data);
        list.deinit(alloc);
    }

    const begin_tag = "; thumbnail begin ";
    var search_start: usize = 0;
    while (std.mem.indexOf(u8, text[search_start..], begin_tag)) |rel_idx| {
        const begin_idx = search_start + rel_idx;
        const header_start = begin_idx + begin_tag.len;
        const header_end = scanLineEnd(text, header_start);
        const header = text[header_start..header_end];

        // Parse "WxH len"
        var parts = std.mem.tokenizeScalar(u8, header, ' ');
        const dims_str = parts.next() orelse {
            search_start = begin_idx + 1;
            continue;
        };
        const size_str = parts.next() orelse {
            search_start = begin_idx + 1;
            continue;
        };
        const x_pos = std.mem.indexOfScalar(u8, dims_str, 'x') orelse {
            search_start = begin_idx + 1;
            continue;
        };
        const w = std.fmt.parseInt(i64, dims_str[0..x_pos], 10) catch {
            search_start = begin_idx + 1;
            continue;
        };
        const h = std.fmt.parseInt(i64, dims_str[x_pos + 1 ..], 10) catch {
            search_start = begin_idx + 1;
            continue;
        };
        const size = std.fmt.parseInt(i64, size_str, 10) catch {
            search_start = begin_idx + 1;
            continue;
        };

        // Find "; thumbnail end"
        const end_tag = "; thumbnail end";
        const end_rel = std.mem.indexOf(u8, text[header_end..], end_tag) orelse {
            search_start = header_end;
            continue;
        };
        const end_idx = header_end + end_rel;

        // Clamp the allocation: `size` comes from the (untrusted) file header, so
        // cap it at the actual bytes between header and end-tag — a bogus
        // "begin 1x1 999999999" must not force a huge allocation on a 5 MB target.
        if (size <= 0) {
            search_start = begin_idx + 1;
            continue;
        }
        const max_data = end_idx - header_end;
        const cap: usize = @min(@as(usize, @intCast(size)), max_data);

        // Extract base64 data between begin and end (strip "; " prefix and newlines).
        var data = try std.Io.Writer.Allocating.initCapacity(alloc, cap);
        defer data.deinit();
        var line_start = header_end + 1; // skip the \n after header
        while (line_start < end_idx) {
            const line_end2 = scanLineEnd(text, line_start);
            const line = text[line_start..line_end2];
            // Strip leading "; " or ";"
            var content = line;
            if (content.len >= 2 and content[0] == ';' and content[1] == ' ') {
                content = content[2..];
            } else if (content.len >= 1 and content[0] == ';') {
                content = content[1..];
            }
            if (data.written().len + content.len <= cap) {
                data.writer.writeAll(content) catch return error.OutOfMemory;
            }
            line_start = line_end2 + 1;
            if (line_start >= text.len) break;
        }

        const owned = try data.toOwnedSlice();
        errdefer alloc.free(owned);
        try list.append(alloc, Thumbnail{
            .width = w,
            .height = h,
            .size = size,
            .data = owned,
        });

        search_start = end_idx + end_tag.len;
    }

    return list.toOwnedSlice(alloc);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "detectPrusaSlicer: standard header" {
    const header = "; generated by PrusaSlicer 2.7.0 on 2024-01-15 at 12:30:00 UTC\n";
    const info = detectPrusaSlicer(header).?;
    try testing.expectEqualStrings("PrusaSlicer", info.name);
    try testing.expectEqualStrings("2.7.0", info.version);
}

test "detectPrusaSlicer: SuperSlicer fork" {
    const header = "; generated by SuperSlicer 2.5.59.0 on 2024-01-15 at 12:30:00 UTC\n";
    const info = detectPrusaSlicer(header).?;
    try testing.expectEqualStrings("SuperSlicer", info.name);
    try testing.expectEqualStrings("2.5.59.0", info.version);
}

test "detectPrusaSlicer: OrcaSlicer" {
    const header = "; generated by OrcaSlicer 1.9.0 on 2024-02-01 at 08:00:00 UTC\n";
    const info = detectPrusaSlicer(header).?;
    try testing.expectEqualStrings("OrcaSlicer", info.name);
    try testing.expectEqualStrings("1.9.0", info.version);
}

test "detectCura: sliced by" {
    const header = "; sliced by Ultimaker Cura 5.6.0\n";
    const info = detectCura(header).?;
    try testing.expectEqualStrings("Ultimaker Cura", info.name);
    try testing.expectEqualStrings("5.6.0", info.version);
}

test "detectCura: Sliced by" {
    const header = ";Sliced by CuraEngine 4.13.0\n";
    const info = detectCura(header).?;
    try testing.expectEqualStrings("CuraEngine", info.name);
    try testing.expectEqualStrings("4.13.0", info.version);
}

test "detectSimplify3D" {
    const header = "; Simplify3D(R) Version 5.1.2\n";
    const info = detectSimplify3D(header).?;
    try testing.expectEqualStrings("Simplify3D", info.name);
    try testing.expectEqualStrings("5.1.2", info.version);
}

test "detectKISSlicer" {
    const header = "; KISSlicer 1.7.0\n";
    const info = detectKISSlicer(header).?;
    try testing.expectEqualStrings("KISSlicer", info.name);
    try testing.expectEqualStrings("1.7.0", info.version);
}

test "detectIdeaMaker" {
    const header = "; ideaMaker 4.3.2\n";
    const info = detectIdeaMaker(header).?;
    try testing.expectEqualStrings("ideaMaker", info.name);
    try testing.expectEqualStrings("4.3.2", info.version);
}

test "parseLayerCount: LAYER_COUNT directive" {
    const text = ";LAYER_COUNT:120\nG28\n";
    try testing.expectEqual(@as(?i64, 120), parseLayerCount(text));
}

test "parseLayerCount: layer_count directive" {
    const text = "; layer_count: 42\nG28\n";
    try testing.expectEqual(@as(?i64, 42), parseLayerCount(text));
}

test "parseLayerCount: OrcaSlicer total overrides partial layer changes" {
    const text = "; total layer number: 240\n;LAYER_CHANGE\n;LAYER_CHANGE\n";
    try testing.expectEqual(@as(?i64, 240), parseLayerCount(text));
}

test "parseLayerCount: fallback LAYER_CHANGE counting" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    for (0..50) |_| {
        w.writeAll(";LAYER_CHANGE\n") catch unreachable;
    }
    const text = w.buffered();
    try testing.expectEqual(@as(?i64, 50), parseLayerCount(text));
}

test "findEstimatedTime: PrusaSlicer format" {
    const text = "; estimated printing time (normal mode) = 3600.5s\n";
    try testing.expectEqual(@as(?f64, 3600.5), findEstimatedTime(text).?);
}

test "findEstimatedTime: OrcaSlicer duration units" {
    const text = "; estimated printing time (normal mode) = 1h 16m 59s\n";
    try testing.expectEqual(@as(?f64, 4619), findEstimatedTime(text));
    try testing.expectEqual(@as(?f64, 960), findEstimatedTime("; estimated printing time (normal mode) = 16m\n"));
    try testing.expectEqual(@as(?f64, 3600), findEstimatedTime("; estimated printing time (normal mode) = 1h\n"));
    try testing.expectEqual(@as(?f64, 90000), findEstimatedTime("; estimated printing time (normal mode) = 1d 1h\n"));
    try testing.expectEqual(@as(?f64, null), findEstimatedTime("; estimated printing time (normal mode) = 1h nope\n"));
    try testing.expectEqual(@as(?f64, null), findEstimatedTime("; estimated printing time (normal mode) = 1e309h\n"));
}

test "fuzz OrcaSlicer metadata fields preserve durations and total layers" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            const hours = smith.valueRangeAtMostWithHash(u16, 0, 1000, 0);
            const minutes = smith.valueRangeAtMostWithHash(u16, 0, 59, 1);
            const seconds = smith.valueRangeAtMostWithHash(u16, 0, 59, 2);
            const layers = smith.valueRangeAtMostWithHash(u16, 0, 65535, 3);
            var buf: [192]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, "; estimated printing time (normal mode) = {d}h {d}m {d}s\n; total layer number: {d}\n;LAYER_CHANGE\n", .{ hours, minutes, seconds, layers });
            const expected: f64 = @floatFromInt(@as(u32, hours) * 3600 + @as(u32, minutes) * 60 + seconds);
            try testing.expectEqual(@as(?f64, expected), findEstimatedTime(text));
            try testing.expectEqual(@as(?i64, layers), parseLayerCount(text));
            const minute_only = try std.fmt.bufPrint(&buf, "; estimated printing time (normal mode) = {d}m\n", .{minutes});
            try testing.expectEqual(@as(?f64, @floatFromInt(@as(u32, minutes) * 60)), findEstimatedTime(minute_only));
        }
    }.run, .{});
}

test "findEstimatedTime: Cura format" {
    const text = "; estimated printing time = 1800\n";
    try testing.expectEqual(@as(?f64, 1800), findEstimatedTime(text).?);
}

test "findEstimatedTime: Simplify3D format" {
    const text = "; TIME:7200\n";
    try testing.expectEqual(@as(?f64, 7200), findEstimatedTime(text).?);
}

test "findEstimatedTime: Build time format" {
    const text = ";Build time: 2 hours 30 minutes\n";
    try testing.expectEqual(@as(?f64, 9000), findEstimatedTime(text).?);
}

test "findFilamentTotal: PrusaSlicer format" {
    const text = "; filament used [mm] = 12345.6\n";
    try testing.expectEqual(@as(?f64, 12345.6), findFilamentTotal(text).?);
}

test "findFilamentTotal: Cura format" {
    const text = "; total filament length = 5000\n";
    try testing.expectEqual(@as(?f64, 5000), findFilamentTotal(text).?);
}

test "findFirstLayerExtrTemp" {
    const text = "; first_layer_temperature = 215\n";
    try testing.expectEqual(@as(?f64, 215), findFirstLayerExtrTemp(text).?);
}

test "findFirstLayerBedTemp" {
    const text = "; first_layer_bed_temperature = 60\n";
    try testing.expectEqual(@as(?f64, 60), findFirstLayerBedTemp(text).?);
}

test "findLayerHeight" {
    const text = "; layer_height = 0.2\n";
    try testing.expectEqual(@as(?f64, 0.2), findLayerHeight(text).?);
}

test "parseThumbnails: single thumbnail" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const text =
        \\; thumbnail begin 32x32 8
        \\; YQAB
        \\; thumbnail end
    ;
    const thumbs = try parseThumbnails(a, text);
    try testing.expectEqual(@as(usize, 1), thumbs.len);
    try testing.expectEqual(@as(i64, 32), thumbs[0].width);
    try testing.expectEqual(@as(i64, 32), thumbs[0].height);
    try testing.expectEqual(@as(i64, 8), thumbs[0].size);
    try testing.expectEqualStrings("YQAB", thumbs[0].data);
}

test "thumbnail data owns exact storage and cleans up on allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: std.mem.Allocator) !void {
            const block = "; thumbnail begin 32x32 8\n; YQAB\n; thumbnail end\n";
            const text = block ++ block;
            const thumbs = try parseThumbnails(alloc, text);
            defer {
                for (thumbs) |thumb| alloc.free(thumb.data);
                alloc.free(thumbs);
            }
            try testing.expectEqual(@as(usize, 2), thumbs.len);
            for (thumbs) |thumb| try testing.expectEqualStrings("YQAB", thumb.data);
        }
    }.run, .{});
}

test "fuzz thumbnail data remains owned after source storage changes" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            const alloc = testing.allocator;
            var bytes: [32]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            const expected = std.fmt.bytesToHex(bytes, .lower);
            const text = try std.fmt.allocPrint(alloc, "; thumbnail begin 32x32 80\n; {s}\n; thumbnail end\n", .{expected});
            defer alloc.free(text);
            const thumbs = try parseThumbnails(alloc, text);
            defer {
                for (thumbs) |thumb| alloc.free(thumb.data);
                alloc.free(thumbs);
            }
            @memset(text, 0);
            try testing.expectEqual(@as(usize, 1), thumbs.len);
            try testing.expectEqualStrings(&expected, thumbs[0].data);
        }
    }.run, .{});
}

test "parse: full header extracts slicer and values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const header =
        \\; generated by PrusaSlicer 2.7.1 on 2024-06-01 at 10:00:00 UTC
        \\; layer_height = 0.2
        \\; first_layer_temperature = 215
        \\; first_layer_bed_temperature = 60
        \\; filament used [mm] = 50000.0
        \\; estimated printing time (normal mode) = 7200s
        \\;LAYER_CHANGE
        \\;LAYER_CHANGE
        \\;LAYER_CHANGE
    ;

    const meta = parse(a, header);
    try testing.expectEqualStrings("PrusaSlicer", meta.slicer.?);
    try testing.expectEqualStrings("2.7.1", meta.slicer_version.?);
    try testing.expectEqual(@as(?f64, 0.2), meta.layer_height);
    try testing.expectEqual(@as(?f64, 215), meta.first_layer_extr_temp);
    try testing.expectEqual(@as(?f64, 60), meta.first_layer_bed_temp);
    try testing.expectEqual(@as(?f64, 50000.0), meta.filament_total);
    try testing.expectEqual(@as(?f64, 7200), meta.estimated_time);
    try testing.expectEqual(@as(?i64, 3), meta.layer_count);
}

test "parse: unknown slicer returns null slicer fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const header = "G28\nG1 X0 Y0 Z0\n";
    const meta = parse(a, header);
    try testing.expect(meta.slicer == null);
    try testing.expect(meta.slicer_version == null);
}

test "findObjectHeight: Cura max_z_height" {
    const text = "; max_z_height: 150.5\n";
    try testing.expectEqual(@as(?f64, 150.5), findObjectHeight(text));
}

test "findObjectHeight: Simplify3D MAXZ" {
    const text = ";MAXZ:200.0\n";
    try testing.expectEqual(@as(?f64, 200.0), findObjectHeight(text));
}

test "findObjectHeight: BambuStudio print_height_mm" {
    const text = "; print_height_mm : 180.25\n";
    try testing.expectEqual(@as(?f64, 180.25), findObjectHeight(text));
}

test "findObjectHeight: Slic3r PE Bounding Box" {
    const text = ";Bounding Box: 100.0 150.0 75.5\n";
    try testing.expectEqual(@as(?f64, 75.5), findObjectHeight(text));
}

test "findObjectHeight: PrusaSlicer BEFORE_LAYER_CHANGE" {
    const text =
        \\;BEFORE_LAYER_CHANGE
        \\;0.2
        \\;BEFORE_LAYER_CHANGE
        \\;0.4
        \\;BEFORE_LAYER_CHANGE
        \\;0.3
    ;
    try testing.expectEqual(@as(?f64, 0.4), findObjectHeight(text));
}

test "findObjectHeight: G1 Z fallback" {
    const text =
        \\G1 X10 Y20 Z0.3 F6000
        \\G1 X15 Y25 Z5.5 F6000
        \\G1 X20 Y30 Z3.2 F6000
    ;
    try testing.expectEqual(@as(?f64, 5.5), findObjectHeight(text));
}

test "findObjectHeight: G0 Z fallback" {
    const text =
        \\G0 Z10.0
        \\G1 X10 Y20
    ;
    try testing.expectEqual(@as(?f64, 10.0), findObjectHeight(text));
}

test "findObjectHeight: empty returns null" {
    try testing.expect(findObjectHeight("") == null);
}

test "findObjectHeight: no match returns null" {
    try testing.expect(findObjectHeight("G28\nM106 S255\n") == null);
}

test "parse: full header with object_height" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const header =
        \\; generated by PrusaSlicer 2.7.1 on 2024-06-01 at 10:00:00 UTC
        \\; layer_height = 0.2
        \\; max_z_height: 155.0
        \\; filament used [mm] = 50000.0
        \\; estimated printing time (normal mode) = 7200s
    ;

    const meta = parse(a, header);
    try testing.expectEqual(@as(?f64, 155.0), meta.object_height);
}

test "findFilamentWeightTotal: PrusaSlicer format" {
    const text = "; total filament used [g] = 150.5\n";
    try testing.expectEqual(@as(?f64, 150.5), findFilamentWeightTotal(text));
}

test "findFilamentWeightTotal: Cura format" {
    const text = "; total filament weight [g] : 75.3\n";
    try testing.expectEqual(@as(?f64, 75.3), findFilamentWeightTotal(text));
}

test "findFilamentWeightTotal: comma-separated sum" {
    const text = "; filament used [g] = 50.0, 25.5, 30.0\n";
    try testing.expectEqual(@as(?f64, 105.5), findFilamentWeightTotal(text));
}

test "findFilamentWeightTotal: mass_g format" {
    const text = "; filament mass_g = 42.0\n";
    try testing.expectEqual(@as(?f64, 42.0), findFilamentWeightTotal(text));
}

test "findNozzleDiameter: PrusaSlicer format" {
    const text = "; nozzle_diameter = 0.4\n";
    try testing.expectEqual(@as(?f64, 0.4), findNozzleDiameter(text));
}

test "findNozzleDiameter: BambuStudio format" {
    const text = "; nozzle_diameter_mm_0 : 0.6\n";
    try testing.expectEqual(@as(?f64, 0.6), findNozzleDiameter(text));
}

test "findSumFloatsAfterPrefix: basic" {
    const text = "; prefix = 1.5, 2.5, 3.0\n";
    try testing.expectEqual(@as(?f64, 7.0), findSumFloatsAfterPrefix(text, "; prefix ="));
}

test "findSumFloatsAfterPrefix: single value" {
    const text = "; prefix = 42.0\n";
    try testing.expectEqual(@as(?f64, 42.0), findSumFloatsAfterPrefix(text, "; prefix ="));
}

test "findBracketedSumFloats: basic" {
    const text = ";Filament weight = [10.0, 20.0, 30.0]\n";
    try testing.expectEqual(@as(?f64, 60.0), findBracketedSumFloats(text, ";Filament weight ="));
}

test "parse: full header with new fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const header =
        \\; generated by PrusaSlicer 2.7.1 on 2024-06-01 at 10:00:00 UTC
        \\; nozzle_diameter = 0.4
        \\; layer_height = 0.2
        \\; max_z_height: 155.0
        \\; filament used [mm] = 50000.0
        \\; total filament used [g] = 125.5
        \\; estimated printing time (normal mode) = 7200s
    ;

    const meta = parse(a, header);
    try testing.expectEqualStrings("PrusaSlicer", meta.slicer.?);
    try testing.expectEqual(@as(?f64, 0.4), meta.nozzle_diameter);
    try testing.expectEqual(@as(?f64, 0.2), meta.layer_height);
    try testing.expectEqual(@as(?f64, 155.0), meta.object_height);
    try testing.expectEqual(@as(?f64, 50000.0), meta.filament_total);
    try testing.expectEqual(@as(?f64, 125.5), meta.filament_weight_total);
    try testing.expectEqual(@as(?f64, 7200.0), meta.estimated_time);
}

test "parse: handles empty input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const meta = parse(a, "");
    try testing.expect(meta.slicer == null);
    try testing.expect(meta.layer_count == null);
    try testing.expect(meta.estimated_time == null);
    try testing.expect(meta.filament_total == null);
    try testing.expectEqual(@as(usize, 0), meta.thumbnails.len);
}

test "parseFull: footer fills gaps the header lacks (PrusaSlicer config block)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Header: only the slicer line + early moves (low Z). No config block.
    const header =
        \\; generated by PrusaSlicer 2.7.1 on 2024-01-01 at 00:00:00 UTC
        \\G1 Z0.2
        \\G1 Z1.5
    ;
    // Footer: PrusaSlicer's end-of-file config block + the final high Z move.
    const footer =
        \\G1 Z18.6
        \\; estimated printing time (normal mode) = 7200s
        \\; filament used [mm] = 1234.5
        \\; total filament used [g] = 9.8
        \\; layer_height = 0.2
        \\; nozzle_diameter = 0.4
    ;
    const m = parseFull(a, header, footer);
    try testing.expectEqualStrings("PrusaSlicer", m.slicer.?);
    try testing.expectEqual(@as(f64, 7200.0), m.estimated_time.?);
    try testing.expectEqual(@as(f64, 1234.5), m.filament_total.?);
    try testing.expectEqual(@as(f64, 9.8), m.filament_weight_total.?);
    try testing.expectEqual(@as(f64, 0.2), m.layer_height.?);
    try testing.expectEqual(@as(f64, 0.4), m.nozzle_diameter.?);
    // object_height is the max G1 Z across header+footer.
    try testing.expectEqual(@as(f64, 18.6), m.object_height.?);
}

test "parseFull: header values win; empty footer is a no-op" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const header =
        \\; generated by PrusaSlicer 2.7.1 on 2024-01-01 at 00:00:00 UTC
        \\; layer_height = 0.3
    ;
    // Footer would say 0.2 but the header's 0.3 must win.
    const m = parseFull(a, header, "; layer_height = 0.2\n");
    try testing.expectEqual(@as(f64, 0.3), m.layer_height.?);
    // Empty footer ⇒ identical to header-only parse.
    const m2 = parseFull(a, header, "");
    try testing.expectEqual(@as(f64, 0.3), m2.layer_height.?);
}

test "fuzz parseFull: arbitrary header/footer never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var hbuf: [64]u8 = undefined;
            var fbuf: [64]u8 = undefined;
            smith.bytesWithHash(&hbuf, 0);
            smith.bytesWithHash(&fbuf, 1);
            _ = parseFull(a, &hbuf, &fbuf);
        }
    }.run, .{});
}

// ---------------------------------------------------------------------------
// Fuzz tests
// ---------------------------------------------------------------------------

test "fuzz_parse: never crashes on arbitrary bytes" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const text = buf[0 .. @as(u16, buf[0]) % 2048 + 1];
            _ = parse(a, text);
        }
    }.run, .{});
}

test "fuzz_detectPrusaSlicer: never crashes" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            _ = detectPrusaSlicer(&buf);
        }
    }.run, .{});
}

test "fuzz_findFloat: never crashes" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [128]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            _ = findFloatAfterPrefix(&buf, "; prefix =");
        }
    }.run, .{});
}

test "fuzz_findObjectHeight: never crashes on arbitrary bytes" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [2048]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            _ = findObjectHeight(&buf);
        }
    }.run, .{});
}

test "fuzz_findMaxBeforeLayerChange: never crashes" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [1024]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            _ = findMaxBeforeLayerChange(&buf);
        }
    }.run, .{});
}

test "fuzz_findMaxG1Z: never crashes" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [1024]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            _ = findMaxG1Z(&buf);
        }
    }.run, .{});
}

test "fuzz_findFilamentWeightTotal: never crashes" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            _ = findFilamentWeightTotal(&buf);
        }
    }.run, .{});
}

test "fuzz_findNozzleDiameter: never crashes" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            _ = findNozzleDiameter(&buf);
        }
    }.run, .{});
}

test "fuzz_findSumFloatsAfterPrefix: never crashes" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            _ = findSumFloatsAfterPrefix(&buf, "; test =");
        }
    }.run, .{});
}

test "fuzz_findBracketedSumFloats: never crashes" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            _ = findBracketedSumFloats(&buf, ";Test weight =");
        }
    }.run, .{});
}
