//! In-app test (EEXIF_TEST=1). Input goes through the same paths as real
//! use (pointer and keypad indevs); nothing is sent to the X server.
//!
//!   EEXIF_TEST=1 SDL_VIDEO_DRIVER=offscreen EEXIF_TEST_DIR=<tmp> \
//!   [EEXIF_SHOT=<dir>] ./zig-out/bin/eexif
//!
//! Prints "test: ok" at the end. EEXIF_SHOT saves screenshots (BMP).

const std = @import("std");
const Io = std.Io;
const sdl = @import("sdl3");
const lv = @import("lvgl");
const ui = @import("ui");
const wexif = @import("wexif");
const edit = @import("edit");
const main = @import("main.zig");

const photo = @embedFile("test_photo");

var gpa: std.mem.Allocator = undefined;
var io: Io = undefined;
var dir: []const u8 = "";

fn settle() void {
    _ = lv.lv_timer_handler();
    lv.lv_refr_now(main.display);
}

fn tap(obj: ?*lv.lv_obj_t) !void {
    const o = obj orelse return error.TestObjectMissing;
    lv.lv_obj_scroll_to_view_recursive(o, false);
    lv.lv_obj_update_layout(lv.lv_screen_active());
    var area: lv.lv_area_t = undefined;
    lv.lv_obj_get_coords(o, &area);
    main.mouse_x = @divTrunc(area.x1 + area.x2, 2);
    main.mouse_y = @divTrunc(area.y1 + area.y2, 2);
    main.mouse_down = true;
    lv.lv_indev_read(main.pointer);
    main.mouse_down = false;
    lv.lv_indev_read(main.pointer);
    settle();
}

/// Replaces a text area's content by typing.
fn typeInto(ta: ?*lv.lv_obj_t, s: []const u8) !void {
    try tap(ta);
    lv.lv_textarea_set_text(ta, "");
    main.typeText(s);
    settle();
}

fn choose(dd: ?*lv.lv_obj_t, index: usize) !void {
    if (dd == null) return error.TestObjectMissing;
    lv.lv_dropdown_set_selected(dd, @intCast(index));
    _ = lv.lv_obj_send_event(dd, lv.LV_EVENT_VALUE_CHANGED, null);
    settle();
}

fn choiceIndex(label: []const u8) usize {
    for (edit.choices, 0..) |c, i| if (std.mem.eql(u8, c.label, label)) return i;
    @panic("no such choice");
}

fn shot(name: []const u8) void {
    const d = sdl.SDL_getenv("EEXIF_SHOT") orelse return;
    settle();
    var buf: [512]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&buf, "{s}/{s}.bmp", .{ std.mem.span(d), name }, 0) catch return;
    const surf = sdl.SDL_CreateSurfaceFrom(main.frame_w, main.frame_h, sdl.SDL_PIXELFORMAT_XRGB8888, main.frame.ptr, main.frame_w * 4) orelse return;
    defer sdl.SDL_DestroySurface(surf);
    _ = sdl.SDL_SaveBMP(surf, path.ptr);
}

fn expect(ok: bool, comptime what: []const u8) !void {
    if (!ok) {
        std.debug.print("test: FAILED: {s} (status: '{s}')\n", .{ what, ui.status_text });
        return error.TestFailed;
    }
}

fn expectStatus(want: []const u8) !void {
    if (!std.mem.eql(u8, ui.status_text, want)) {
        std.debug.print("test: FAILED: status '{s}', expected '{s}'\n", .{ ui.status_text, want });
        return error.TestFailed;
    }
}

fn isVisible(obj: ?*lv.lv_obj_t) bool {
    return obj != null and !lv.lv_obj_is_hidden(obj);
}

/// Reads a photo from the test folder and returns its EXIF.
fn readExif(name: []const u8) !wexif.Exif {
    var buf: [512]u8 = undefined;
    const p = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name });
    return (try wexif.readFile(gpa, io, p)) orelse wexif.Exif.init(gpa, .little);
}

pub fn run(allocator: std.mem.Allocator, io_: Io) !void {
    gpa = allocator;
    io = io_;
    dir = if (sdl.SDL_getenv("EEXIF_TEST_DIR")) |d| std.mem.span(d) else return error.SetEeexifTestDir;

    // Fresh test folder: three photos and a file that is not a JPEG
    const cwd = Io.Dir.cwd();
    cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);
    for ([_][]const u8{ "a.jpg", "b.jpg", "c.JPG" }) |n| {
        var buf: [512]u8 = undefined;
        try cwd.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, n }), .data = photo });
    }
    {
        var buf: [512]u8 = undefined;
        try cwd.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&buf, "{s}/notes.txt", .{dir}), .data = "not a photo" });
    }

    settle();
    shot("00_empty");

    // --- Open the folder: first photo selected ---
    ui.openPath(dir);
    settle();
    try expect(ui.refs.file_buttons[2] != null and ui.refs.file_buttons[3] == null, "three JPEGs listed");
    try expect(ui.fieldButton(.make, false) != null, "fields of a.jpg shown");
    shot("01_folder");

    // --- Add a field (Artist) ---
    try tap(ui.refs.add_field_btn);
    try choose(ui.refs.dialog_field_dd, choiceIndex("Artist"));
    try typeInto(ui.refs.dialog_ta, "Jane Doe");
    shot("02_add_field");
    try tap(ui.refs.dialog_ok_btn);
    try expectStatus("Unsaved changes");
    try expect(ui.fieldButton(.artist, false) != null, "Artist row added");

    // --- Edit orientation with its dropdown ---
    try tap(ui.fieldButton(.orientation, false));
    try choose(ui.refs.dialog_orientation_dd, 5); // Rotate 90 CW (6)
    shot("03_orientation");
    try tap(ui.refs.dialog_ok_btn);

    // --- Invalid date is rejected, dialog stays open ---
    try tap(ui.refs.add_field_btn);
    try choose(ui.refs.dialog_field_dd, choiceIndex("Date taken (all date fields)"));
    try typeInto(ui.refs.dialog_ta, "yesterday");
    try tap(ui.refs.dialog_ok_btn);
    try expect(isVisible(ui.refs.dialog_error), "date error shown");
    shot("04_date_error");
    try typeInto(ui.refs.dialog_ta, "2026:11:08 18:30:00 +03:00");
    main.pushKey(lv.LV_KEY_ENTER); // Enter applies, like the button
    main.flushKeys();
    settle();
    try expect(ui.refs.dialog_ta == null, "dialog closed by Enter");

    // --- Edit a value with UTF-8 text (UserComment) ---
    try tap(ui.refs.add_field_btn);
    try choose(ui.refs.dialog_field_dd, choiceIndex("UserComment"));
    try typeInto(ui.refs.dialog_ta, "Naïve café comment \u{1F4F7}");
    try tap(ui.refs.dialog_ok_btn);

    // --- Delete a field, then save ---
    try tap(ui.fieldButton(.software, true));
    shot("05_edited");
    try tap(ui.refs.save_btn);
    try expectStatus("Saved a.jpg");
    {
        var ex = try readExif("a.jpg");
        defer ex.deinit();
        try expect(std.mem.eql(u8, ex.getString(.artist).?, "Jane Doe"), "Artist saved");
        try expect(ex.getOrientation().? == .rotate_90_cw, "Orientation saved");
        try expect(std.mem.eql(u8, ex.getString(.date_time_original).?, "2026:11:08 18:30:00"), "date saved");
        try expect(std.mem.eql(u8, ex.getString(.offset_time_original).?, "+03:00"), "offset saved");
        try expect(ex.getString(.software) == null, "Software deleted");
        const c = (try ex.getUserComment(gpa)).?;
        defer gpa.free(c);
        try expect(std.mem.eql(u8, c, "Naïve café comment \u{1F4F7}"), "UserComment saved");
        try expect(ex.getGps() != null and ex.thumbnail != null, "GPS and thumbnail kept");
    }
    shot("06_saved_rotated");

    // --- Revert discards edits ---
    try tap(ui.fieldButton(.artist, true));
    try expectStatus("Unsaved changes");
    try tap(ui.refs.revert_btn);
    try expect(ui.fieldButton(.artist, false) != null, "Artist back after revert");

    // --- Switching files with unsaved changes asks first ---
    try tap(ui.fieldButton(.model, true));
    try tap(ui.refs.file_buttons[1]);
    try expect(ui.refs.confirm_yes_btn != null, "discard question shown");
    shot("07_discard");
    try tap(ui.refs.confirm_yes_btn);
    try expect(ui.fieldButton(.artist, false) == null, "b.jpg shown (no Artist)");
    {
        var ex = try readExif("a.jpg");
        defer ex.deinit();
        try expect(ex.getString(.model) != null, "discarded change not written");
    }

    // --- Batch: invalid value is caught before any file changes ---
    try tap(ui.refs.batch_btn);
    try choose(ui.batch_rows[0].field, choiceIndex("Date taken (all date fields)"));
    try typeInto(ui.batch_rows[0].value, "not a date");
    try tap(ui.refs.batch_apply_btn);
    try expect(isVisible(ui.refs.dialog_error), "batch error shown");
    shot("08_batch_error");

    // --- Batch: set copyright and date, remove GPS, on all files ---
    try typeInto(ui.batch_rows[0].value, "2020:01:02 03:04:05");
    try tap(ui.refs.batch_add_btn);
    try choose(ui.batch_rows[1].field, choiceIndex("Copyright"));
    try typeInto(ui.batch_rows[1].value, "(c) 2026 Jane Doe");
    try tap(ui.refs.batch_add_btn);
    try choose(ui.batch_rows[2].action, 1); // Remove
    try choose(ui.batch_rows[2].field, choiceIndex("Make"));
    try tap(ui.refs.batch_gps_cb);
    shot("09_batch");
    try tap(ui.refs.batch_apply_btn);
    var waited: usize = 0;
    while (ui.refs.batch_summary == null) : (waited += 1) {
        if (waited > 5000) return error.TestBatchTimeout;
        settle();
        sdl.SDL_Delay(1);
    }
    shot("10_batch_done");
    try expectStatus("Batch edit: updated 3 files");
    for ([_][]const u8{ "a.jpg", "b.jpg", "c.JPG" }) |n| {
        var ex = try readExif(n);
        defer ex.deinit();
        try expect(std.mem.eql(u8, ex.getString(.copyright).?, "(c) 2026 Jane Doe"), "batch Copyright");
        try expect(std.mem.eql(u8, ex.getString(.date_time_original).?, "2020:01:02 03:04:05"), "batch date");
        try expect(std.mem.eql(u8, ex.getString(.date_time).?, "2020:01:02 03:04:05"), "batch DateTime");
        try expect(ex.getString(.make) == null, "batch removed Make");
        try expect(ex.getGps() == null, "batch removed GPS");
        try expect(ex.getString(.model) != null and ex.thumbnail != null, "other fields kept");
    }
    {
        var buf: [512]u8 = undefined;
        const notes = try cwd.readFileAlloc(io, try std.fmt.bufPrint(&buf, "{s}/notes.txt", .{dir}), gpa, .limited(100));
        defer gpa.free(notes);
        try expect(std.mem.eql(u8, notes, "not a photo"), "non-JPEG untouched");
    }
    try tap(ui.refs.batch_close_btn);
    try expect(ui.fieldButton(.copyright, false) != null, "current photo reloaded after batch");

    // --- Smaller window and larger UI scale ---
    try main.resizeDisplay(@intFromFloat(900 * main.uiScale()), @intFromFloat(560 * main.uiScale()));
    ui.onResize();
    shot("11_small_window");
    try ui.setScale(main.uiScale() * 1.25);
    settle();
    shot("12_scaled");

    std.debug.print("test: ok\n", .{});
}
