//! EXIF editing logic shared by the UI: turning values into text and back,
//! loading and saving documents, and batch operations over a folder.
//! Nothing here depends on LVGL or SDL, so it is covered by unit tests.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const wexif = @import("wexif");
const Exif = wexif.Exif;
const Tag = wexif.Tag;
const Type = wexif.Type;
const Value = wexif.Value;
const DateTime = wexif.DateTime;

// ---------------------------------------------------------------------------
// Fields

/// Something the user can set: a single tag, or "date taken", which writes
/// all three date tags at once (see `Exif.setDateTime`).
pub const Target = union(enum) {
    date_taken,
    tag: Tag,
};

pub const Choice = struct {
    target: Target,
    label: []const u8,
};

/// Fields offered when adding a field or in batch edits: the most edited
/// ones first, then every other known tag in table order.
pub const choices: []const Choice = blk: {
    const common = [_]Tag{
        .image_description,  .artist,               .copyright,   .user_comment, .orientation,
        .date_time_original, .offset_time_original, .make,        .model,        .software,
        .xp_title,           .xp_comment,           .xp_keywords, .xp_author,    .xp_subject,
    };
    @setEvalBranchQuota(100_000);
    var list: []const Choice = &.{.{ .target = .date_taken, .label = "Date taken (all date fields)" }};
    for (common) |t| list = list ++ .{Choice{ .target = .{ .tag = t }, .label = wexif.tags.name(t).? }};
    for (wexif.tags.table) |info| {
        const is_common = for (common) |t| {
            if (t.eql(info.tag)) break true;
        } else false;
        if (!is_common) list = list ++ .{Choice{ .target = .{ .tag = info.tag }, .label = info.name }};
    }
    break :blk list;
};

pub fn isDateTag(tag: Tag) bool {
    return tag.eql(.date_time) or tag.eql(.date_time_original) or tag.eql(.date_time_digitized);
}

pub fn isOffsetTag(tag: Tag) bool {
    return tag.eql(.offset_time) or tag.eql(.offset_time_original) or tag.eql(.offset_time_digitized);
}

/// Windows XP* tags: UTF-16LE text stored as BYTE.
pub fn isXpTag(tag: Tag) bool {
    return (tag.kind == .ifd0 or tag.kind == .ifd1) and tag.num >= 0x9C9B and tag.num <= 0x9C9F;
}

/// The offset tag that belongs to a date tag.
fn offsetTagFor(date_tag: Tag) ?Tag {
    if (date_tag.eql(.date_time)) return .offset_time;
    if (date_tag.eql(.date_time_original)) return .offset_time_original;
    if (date_tag.eql(.date_time_digitized)) return .offset_time_digitized;
    return null;
}

/// Value type used when the user enters text for a tag.
pub fn typeOf(tag: Tag) Type {
    return if (wexif.tags.info(tag)) |i| i.type else .ascii;
}

/// Display name of a tag, or "0xNNNN" for unknown tags.
pub fn tagName(buf: *[8]u8, tag: Tag) []const u8 {
    return wexif.tags.name(tag) orelse std.fmt.bufPrint(buf, "0x{X:0>4}", .{tag.num}) catch unreachable;
}

pub fn orientationLabel(o: wexif.Orientation) []const u8 {
    return switch (o) {
        .normal => "Normal",
        .mirror_horizontal => "Mirror horizontal",
        .rotate_180 => "Rotate 180",
        .mirror_vertical => "Mirror vertical",
        .mirror_horizontal_rotate_270_cw => "Mirror horizontal, rotate 270 CW",
        .rotate_90_cw => "Rotate 90 CW",
        .mirror_horizontal_rotate_90_cw => "Mirror horizontal, rotate 90 CW",
        .rotate_270_cw => "Rotate 270 CW",
    };
}

/// Short help shown under the edit box.
pub fn formatHint(target: Target) []const u8 {
    const tag = switch (target) {
        .date_taken => return "YYYY:MM:DD HH:MM:SS, optionally followed by +HH:MM. Sets DateTimeOriginal, DateTimeDigitized and DateTime.",
        .tag => |t| t,
    };
    if (isDateTag(tag)) return "YYYY:MM:DD HH:MM:SS (also 2026-11-08T18:30:00), optionally followed by +HH:MM";
    if (isOffsetTag(tag)) return "Time zone offset: +HH:MM or -HH:MM";
    if (tag.eql(.orientation)) return "1 Normal, 3 Rotate 180, 6 Rotate 90 CW, 8 Rotate 270 CW (2, 4, 5, 7 mirrored)";
    if (tag.eql(.user_comment) or isXpTag(tag)) return "Text (any language)";
    return switch (typeOf(tag)) {
        .ascii => "Text",
        .rational => "Number or fraction, e.g. 1/250 or 2.8; several values separated by commas",
        .srational => "Signed number or fraction, e.g. -1/3 or 0.7",
        .byte, .short, .long => "Whole number; several values separated by commas",
        .sbyte, .sshort, .slong => "Signed whole number; several values separated by commas",
        .float, .double => "Decimal number",
        .undefined => "Text, or bytes in hex like 0x30323332",
        _ => "Value",
    };
}

// ---------------------------------------------------------------------------
// Value -> text

/// Text shown in the field list. Allocated with `a`.
pub fn displayText(a: Allocator, exif: *const Exif, tag: Tag, v: Value) ![:0]u8 {
    if (tag.eql(.orientation)) {
        if (wexif.Orientation.fromInt(v.uint() orelse 0)) |o|
            return std.fmt.allocPrintSentinel(a, "{s} ({d})", .{ orientationLabel(o), @backingInt(o) }, 0);
    }
    return editText(a, exif, tag, v);
}

/// Text placed in the edit box; `applyText` accepts it back unchanged.
pub fn editText(a: Allocator, exif: *const Exif, tag: Tag, v: Value) ![:0]u8 {
    if (tag.eql(.user_comment)) {
        if (try exif.getUserComment(a)) |c| {
            defer a.free(c);
            return a.dupeSentinel(u8, c, 0);
        }
    }
    if (isXpTag(tag)) {
        if (v == .byte) if (try utf16LeToUtf8(a, v.byte)) |s| return s;
    }
    if (v == .ascii) return a.dupeSentinel(u8, v.string().?, 0);
    if (v == .undefined) {
        const b = v.undefined;
        const trimmed = std.mem.trimEnd(u8, b, "\x00");
        if (trimmed.len > 0 and isPrintable(trimmed)) return a.dupeSentinel(u8, trimmed, 0);
        if (b.len > 64) return std.fmt.allocPrintSentinel(a, "({d} bytes)", .{b.len}, 0);
        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        try out.writer.writeAll("0x");
        for (b) |c| try out.writer.print("{X:0>2}", .{c});
        return out.toOwnedSliceSentinel(0);
    }
    return std.fmt.allocPrintSentinel(a, "{f}", .{v}, 0);
}

fn isPrintable(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isPrint(c)) return false;
    return true;
}

fn utf16LeToUtf8(a: Allocator, bytes: []const u8) !?[:0]u8 {
    const n = bytes.len / 2;
    const units = try a.alloc(u16, n);
    defer a.free(units);
    var len: usize = 0;
    while (len < n) : (len += 1) {
        const u = std.mem.readInt(u16, bytes[len * 2 ..][0..2], .little);
        if (u == 0) break;
        units[len] = std.mem.nativeToLittle(u16, u);
    }
    const s = std.unicode.utf16LeToUtf8Alloc(a, units[0..len]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer a.free(s);
    return try a.dupeSentinel(u8, s, 0);
}

// ---------------------------------------------------------------------------
// Text -> value

pub const ApplyError = error{ InvalidValue, InvalidDateTime, InvalidUtf8, ReservedTag, OutOfMemory };

/// User-facing message for an `ApplyError`.
pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidValue => "This value does not match the field's format.",
        error.InvalidDateTime => "Invalid date. Use YYYY:MM:DD HH:MM:SS, e.g. 2026:11:08 18:30:00.",
        error.InvalidUtf8 => "The text contains invalid characters.",
        error.ReservedTag => "This field is managed automatically and cannot be edited.",
        error.OutOfMemory => "Out of memory.",
        error.NotJpeg => "Not a JPEG file.",
        error.Truncated => "The file is truncated or damaged.",
        error.InvalidHeader => "The EXIF data is damaged.",
        error.ExifTooLarge => "The EXIF data is too large for a JPEG file (64 KB).",
        error.FileNotFound => "File not found.",
        error.AccessDenied, error.PermissionDenied => "Permission denied.",
        else => @errorName(err),
    };
}

/// Parses `text` for `target` and stores it in `exif`.
pub fn applyText(exif: *Exif, target: Target, text_in: []const u8) ApplyError!void {
    const text = std.mem.trim(u8, text_in, " \t\r\n");
    const tag = switch (target) {
        .date_taken => return exif.setDateTime(try DateTime.parse(text)) catch |e| narrow(e),
        .tag => |t| t,
    };

    if (tag.eql(.user_comment)) return exif.setUserComment(text_in) catch |e| narrow(e);
    if (isXpTag(tag)) return setXp(exif, tag, text_in);
    if (isDateTag(tag)) {
        const dt = try DateTime.parse(text);
        const s = dt.exifString();
        exif.setString(tag, &s) catch |e| return narrow(e);
        if (dt.offsetString()) |o| exif.setString(offsetTagFor(tag).?, &o) catch |e| return narrow(e);
        return;
    }
    if (isOffsetTag(tag)) {
        _ = try DateTime.parseOffset(text);
        return exif.setString(tag, text) catch |e| narrow(e);
    }
    if (tag.eql(.orientation)) {
        const n = std.fmt.parseInt(u32, text, 10) catch return error.InvalidValue;
        const o = wexif.Orientation.fromInt(n) orelse return error.InvalidValue;
        return exif.setOrientation(o) catch |e| narrow(e);
    }

    const ty = typeOf(tag);
    if (ty == .ascii) {
        if (!std.unicode.utf8ValidateSlice(text_in)) return error.InvalidUtf8;
        return exif.setString(tag, text_in) catch |e| narrow(e);
    }
    var buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const v = wexif.parseValue(fba.allocator(), ty, text) catch |e| return narrow(e);
    switch (v) {
        .rational => |r| for (@constCast(r)) |*x| reduce(u32, x),
        .srational => |r| for (@constCast(r)) |*x| reduce(i32, x),
        else => {},
    }
    return exif.set(tag, v) catch |e| narrow(e);
}

/// 28000/10000 -> 14/5 (parseValue stores decimals over 10000).
fn reduce(comptime I: type, r: anytype) void {
    if (r.den == 0) return;
    const g = std.math.gcd(@abs(r.num), @abs(r.den));
    if (g > 1) {
        r.num = @divExact(r.num, @as(I, @intCast(g)));
        r.den = @divExact(r.den, @as(I, @intCast(g)));
    }
}

fn setXp(exif: *Exif, tag: Tag, text: []const u8) ApplyError!void {
    var buf: [8192]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const units = std.unicode.utf8ToUtf16LeAlloc(fba.allocator(), text) catch |e| return narrow(e);
    const bytes = fba.allocator().alloc(u8, units.len * 2 + 2) catch return error.OutOfMemory;
    for (units, 0..) |u, i| std.mem.writeInt(u16, bytes[i * 2 ..][0..2], std.mem.littleToNative(u16, u), .little);
    bytes[bytes.len - 2] = 0;
    bytes[bytes.len - 1] = 0;
    return exif.set(tag, .{ .byte = bytes }) catch |e| narrow(e);
}

/// Maps the many error sets of wexif helpers onto `ApplyError`.
fn narrow(err: anyerror) ApplyError {
    return switch (err) {
        error.InvalidDateTime => error.InvalidDateTime,
        error.InvalidUtf8 => error.InvalidUtf8,
        error.ReservedTag => error.ReservedTag,
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidValue,
    };
}

// ---------------------------------------------------------------------------
// Documents

/// An open JPEG file and its editable EXIF.
pub const Doc = struct {
    gpa: Allocator,
    path: [:0]u8,
    /// Whole file as last read or saved
    data: []u8,
    exif: Exif,
    /// True if the file had no EXIF when opened
    was_empty: bool,
    dirty: bool = false,

    pub fn load(gpa: Allocator, io: Io, path: []const u8) !Doc {
        const data = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_size));
        errdefer gpa.free(data);
        const parsed = try wexif.readJpeg(gpa, data);
        var exif = parsed orelse Exif.init(gpa, .little);
        errdefer exif.deinit();
        return .{
            .gpa = gpa,
            .path = try gpa.dupeSentinel(u8, path, 0),
            .data = data,
            .exif = exif,
            .was_empty = parsed == null,
        };
    }

    pub fn deinit(self: *Doc) void {
        self.exif.deinit();
        self.gpa.free(self.data);
        self.gpa.free(self.path);
        self.* = undefined;
    }

    /// Writes the EXIF back into the file (atomically) and keeps the new
    /// bytes as the document's data.
    pub fn save(self: *Doc, io: Io) !void {
        const out = try wexif.writeJpeg(self.gpa, self.data, &self.exif);
        errdefer self.gpa.free(out);
        try saveAtomic(io, self.path, out);
        self.gpa.free(self.data);
        self.data = out;
        self.dirty = false;
        self.was_empty = self.exif.isEmpty();
    }

    /// Discards edits by re-reading the EXIF from the file data.
    pub fn revert(self: *Doc) !void {
        const parsed = try wexif.readJpeg(self.gpa, self.data);
        self.exif.deinit();
        self.exif = parsed orelse Exif.init(self.gpa, .little);
        self.dirty = false;
    }
};

pub const max_file_size = 512 * 1024 * 1024;

/// Writes `data` to a temporary file next to `path`, then renames it over
/// `path`, so a crash never leaves a half-written photo.
pub fn saveAtomic(io: Io, path: []const u8, data: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&buf, "{s}.eexif-tmp", .{path});
    const cwd = Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = tmp, .data = data });
    errdefer cwd.deleteFile(io, tmp) catch {};
    try cwd.rename(tmp, cwd, path, io);
}

// ---------------------------------------------------------------------------
// Folders

pub fn isJpegName(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    return std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg");
}

/// Sorted names of the JPEG files directly inside `dir_path`.
/// Free with `freeNames`.
pub fn listJpegs(gpa: Allocator, io: Io, dir_path: []const u8) ![][:0]u8 {
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var list: std.ArrayList([:0]u8) = .empty;
    errdefer {
        for (list.items) |n| gpa.free(n);
        list.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!isJpegName(entry.name)) continue;
        try list.append(gpa, try gpa.dupeSentinel(u8, entry.name, 0));
    }
    std.mem.sort([:0]u8, list.items, {}, struct {
        fn lessThan(_: void, a: [:0]u8, b: [:0]u8) bool {
            return std.ascii.lessThanIgnoreCase(a, b);
        }
    }.lessThan);
    return list.toOwnedSlice(gpa);
}

pub fn freeNames(gpa: Allocator, names: [][:0]u8) void {
    for (names) |n| gpa.free(n);
    gpa.free(names);
}

// ---------------------------------------------------------------------------
// Batch edits

pub const Op = union(enum) {
    set: struct { target: Target, text: []const u8 },
    remove: Tag,
    remove_gps,
    remove_thumbnail,
    remove_all,
};

/// Applies operations in order.
pub fn applyOps(exif: *Exif, ops: []const Op) ApplyError!void {
    for (ops) |op| switch (op) {
        .set => |s| try applyText(exif, s.target, s.text),
        .remove => |t| _ = exif.remove(t),
        .remove_gps => exif.clear(.gps),
        .remove_thumbnail => exif.removeThumbnail(),
        .remove_all => exif.clearAll(),
    };
}

/// Checks every operation's text before touching any file.
/// Returns the index of the first invalid operation and its error.
pub fn validateOps(gpa: Allocator, ops: []const Op) ?struct { index: usize, err: ApplyError } {
    var scratch = Exif.init(gpa, .little);
    defer scratch.deinit();
    for (ops, 0..) |op, i| {
        applyOps(&scratch, &.{op}) catch |err| return .{ .index = i, .err = err };
    }
    return null;
}

/// Applies `ops` to one file and saves it.
pub fn processFile(gpa: Allocator, io: Io, path: []const u8, ops: []const Op) !void {
    var doc = try Doc.load(gpa, io, path);
    defer doc.deinit();
    try applyOps(&doc.exif, ops);
    try doc.save(io);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

/// Smallest structurally valid JPEG for EXIF tests (not decodable).
const tiny_jpeg = "\xFF\xD8\xFF\xDA\x00\x03\x00scan\xFF\xD9";

test "choices start with the common fields and contain every tag once" {
    try testing.expect(choices[0].target == .date_taken);
    try testing.expectEqualStrings("ImageDescription", choices[1].label);
    try testing.expectEqual(wexif.tags.table.len + 1, choices.len);
    for (choices, 0..) |a, i| for (choices[i + 1 ..]) |b| {
        try testing.expect(!std.mem.eql(u8, a.label, b.label));
    };
}

test "applyText and editText roundtrip per kind of field" {
    const a = testing.allocator;
    var ex = Exif.init(a, .big);
    defer ex.deinit();

    const cases = [_]struct { tag: Tag, in: []const u8, out: []const u8 }{
        .{ .tag = .artist, .in = "Jane Doe", .out = "Jane Doe" },
        .{ .tag = .image_description, .in = "Caf\u{e9} at night", .out = "Caf\u{e9} at night" },
        .{ .tag = .exposure_time, .in = "1/250", .out = "1/250" },
        .{ .tag = .f_number, .in = "2.8", .out = "14/5" },
        .{ .tag = .iso_speed_ratings, .in = "400", .out = "400" },
        .{ .tag = .exposure_bias_value, .in = "-1/3", .out = "-1/3" },
        .{ .tag = .lens_specification, .in = "24/1, 70/1, 28/10, 28/10", .out = "24/1, 70/1, 14/5, 14/5" },
        .{ .tag = .orientation, .in = "6", .out = "6" },
        .{ .tag = .date_time_original, .in = "2026-11-08T18:30:00", .out = "2026:11:08 18:30:00" },
        .{ .tag = .offset_time_original, .in = "+03:00", .out = "+03:00" },
        .{ .tag = .user_comment, .in = "Shot on a phone \u{1F4F7}", .out = "Shot on a phone \u{1F4F7}" },
        .{ .tag = .xp_title, .in = "Title \u{e9}", .out = "Title \u{e9}" },
        .{ .tag = .exif_version, .in = "0x30323332", .out = "0232" },
        .{ .tag = .components_configuration, .in = "0x01020300", .out = "0x01020300" },
    };
    for (cases) |c| {
        try applyText(&ex, .{ .tag = c.tag }, c.in);
        const s = try editText(a, &ex, c.tag, ex.get(c.tag).?);
        defer a.free(s);
        testing.expectEqualStrings(c.out, s) catch |err| {
            std.debug.print("tag {s}\n", .{wexif.tags.name(c.tag).?});
            return err;
        };
        // Whatever editText shows must be accepted again unchanged.
        try applyText(&ex, .{ .tag = c.tag }, s);
        const again = try editText(a, &ex, c.tag, ex.get(c.tag).?);
        defer a.free(again);
        try testing.expectEqualStrings(s, again);
    }

    const shown = try displayText(a, &ex, .orientation, ex.get(.orientation).?);
    defer a.free(shown);
    try testing.expectEqualStrings("Rotate 90 CW (6)", shown);
}

test "applyText rejects invalid input" {
    var ex = Exif.init(testing.allocator, .little);
    defer ex.deinit();
    try testing.expectError(error.InvalidDateTime, applyText(&ex, .{ .tag = .date_time_original }, "yesterday"));
    try testing.expectError(error.InvalidDateTime, applyText(&ex, .date_taken, "2026:02:30 00:00:00"));
    try testing.expectError(error.InvalidDateTime, applyText(&ex, .{ .tag = .offset_time }, "3 hours"));
    try testing.expectError(error.InvalidValue, applyText(&ex, .{ .tag = .orientation }, "9"));
    try testing.expectError(error.InvalidValue, applyText(&ex, .{ .tag = .exposure_time }, "fast"));
    try testing.expectError(error.InvalidUtf8, applyText(&ex, .{ .tag = .artist }, "bad \xff"));
    try testing.expect(ex.isEmpty());
}

test "date with offset also sets the matching offset tag" {
    var ex = Exif.init(testing.allocator, .little);
    defer ex.deinit();
    try applyText(&ex, .{ .tag = .date_time_digitized }, "2026:11:08 18:30:00 -05:30");
    try testing.expectEqualStrings("-05:30", ex.getString(.offset_time_digitized).?);
    try applyText(&ex, .date_taken, "2020-01-02 03:04:05+01:00");
    try testing.expectEqualStrings("2020:01:02 03:04:05", ex.getString(.date_time).?);
    try testing.expectEqualStrings("+01:00", ex.getString(.offset_time).?);
}

test "batch ops: validate, then apply to every file in a folder" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Two JPEGs (one with EXIF), one non-JPEG that must be ignored.
    try tmp.dir.writeFile(io, .{ .sub_path = "b.jpg", .data = tiny_jpeg });
    {
        var ex = Exif.init(gpa, .big);
        defer ex.deinit();
        try ex.setString(.artist, "Old");
        try ex.setGps(.{ .latitude = 1, .longitude = 2 });
        const with = try wexif.writeJpeg(gpa, tiny_jpeg, &ex);
        defer gpa.free(with);
        try tmp.dir.writeFile(io, .{ .sub_path = "A.JPEG", .data = with });
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "x" });

    var dir_buf: [256]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const names = try listJpegs(gpa, io, dir_path);
    defer freeNames(gpa, names);
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("A.JPEG", names[0]);
    try testing.expectEqualStrings("b.jpg", names[1]);

    const bad = [_]Op{
        .{ .set = .{ .target = .{ .tag = .copyright }, .text = "(c) 2026" } },
        .{ .set = .{ .target = .date_taken, .text = "not a date" } },
    };
    const v = validateOps(gpa, &bad).?;
    try testing.expectEqual(@as(usize, 1), v.index);
    try testing.expectEqual(error.InvalidDateTime, v.err);

    const ops = [_]Op{
        .{ .set = .{ .target = .{ .tag = .copyright }, .text = "(c) 2026 Jane" } },
        .{ .set = .{ .target = .date_taken, .text = "2026:11:08 18:30:00" } },
        .{ .remove = .artist },
        .remove_gps,
    };
    try testing.expect(validateOps(gpa, &ops) == null);

    for (names) |n| {
        var path_buf: [512]u8 = undefined;
        const p = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, n });
        try processFile(gpa, io, p, &ops);

        var doc = try Doc.load(gpa, io, p);
        defer doc.deinit();
        try testing.expectEqualStrings("(c) 2026 Jane", doc.exif.getString(.copyright).?);
        try testing.expectEqualStrings("2026:11:08 18:30:00", doc.exif.getString(.date_time_original).?);
        try testing.expect(doc.exif.getString(.artist) == null);
        try testing.expect(doc.exif.getGps() == null);
    }
    // No temporary files left behind.
    var check = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer check.close(io);
    var it = check.iterate();
    var count: usize = 0;
    while (try it.next(io)) |e| {
        try testing.expect(!std.mem.endsWith(u8, e.name, ".eexif-tmp"));
        count += 1;
    }
    try testing.expectEqual(@as(usize, 3), count);
}

test "doc edit, save, revert" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "p.jpg", .data = tiny_jpeg });
    var path_buf: [256]u8 = undefined;
    const p = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/p.jpg", .{tmp.sub_path});

    var doc = try Doc.load(gpa, io, p);
    defer doc.deinit();
    try testing.expect(doc.was_empty);
    try applyText(&doc.exif, .{ .tag = .artist }, "First");
    try doc.save(io);
    try testing.expect(!doc.was_empty);

    try applyText(&doc.exif, .{ .tag = .artist }, "Second");
    try doc.revert();
    try testing.expectEqualStrings("First", doc.exif.getString(.artist).?);

    // Removing everything and saving leaves a JPEG without EXIF.
    try applyOps(&doc.exif, &.{.remove_all});
    try doc.save(io);
    try testing.expectEqualStrings(tiny_jpeg, doc.data);
}

test "load errors" {
    const gpa = testing.allocator;
    const io = testing.io;
    try testing.expectError(error.FileNotFound, Doc.load(gpa, io, "no/such/file.jpg"));
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "x.jpg", .data = "not a jpeg" });
    var path_buf: [256]u8 = undefined;
    const p = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/x.jpg", .{tmp.sub_path});
    try testing.expectError(error.NotJpeg, Doc.load(gpa, io, p));
}
