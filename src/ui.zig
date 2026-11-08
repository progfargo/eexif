//! Screens (LVGL).
//!
//! Layout: a toolbar on top; below it the folder's file list (when a folder
//! is open), the photo preview, and the EXIF field list. Editing, adding a
//! field and batch editing open modal dialogs on the top layer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const lv = @import("lvgl");
const sdl = @import("sdl3");
const wexif = @import("wexif");
const edit = @import("edit");
const dialogs = @import("dialogs.zig");
const Tag = wexif.Tag;

// src/lv_helpers.c and src/preview.c
extern fn eexif_font_set_fallback(font: ?*lv.lv_font_t, fallback: ?*const lv.lv_font_t) void;
extern fn eexif_draw_buf_size(buf: ?*const lv.lv_draw_buf_t, w: *i32, h: *i32) void;
extern fn eexif_decode_preview(data: [*]const u8, len: usize, max_w: c_int, max_h: c_int, orientation: c_int, orig_w: *c_int, orig_h: *c_int) ?*lv.lv_draw_buf_t;

// ---------------------------------------------------------------------------
// Look

const color_primary = 0x2196F3;
const color_danger = 0xF44336;
const color_warning = 0xE65100;
const color_success = 0x2E7D32;
const color_text = 0x212121;
const color_bg = 0xF2F4F7;
const color_section = 0xEEF3FB;

var scale: f32 = 1.0;

/// 1x pixels -> screen pixels
fn dp(v: i32) i32 {
    if (v == 0) return 0;
    return @max(1, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(v)) * scale))));
}

const font_regular_data = @embedFile("font_regular");
const font_semibold_data = @embedFile("font_semibold");
const font_icons_data = @embedFile("font_icons");

var font_normal: ?*lv.lv_font_t = null;
var font_small: ?*lv.lv_font_t = null;
var font_bold: ?*lv.lv_font_t = null;
var font_title: ?*lv.lv_font_t = null;
var icon_fonts: [4]?*lv.lv_font_t = @splat(null);

fn makeFont(data: []const u8, size: i32, icon_slot: usize) ?*lv.lv_font_t {
    const px = dp(size);
    const f = lv.lv_tiny_ttf_create_data(data.ptr, data.len, px);
    const icons = lv.lv_tiny_ttf_create_data(font_icons_data.ptr, font_icons_data.len, px);
    icon_fonts[icon_slot] = icons;
    eexif_font_set_fallback(f, icons);
    return f;
}

fn destroyFonts() void {
    for ([_]*?*lv.lv_font_t{ &font_normal, &font_small, &font_bold, &font_title }) |f| {
        if (f.*) |ff| lv.lv_tiny_ttf_destroy(ff);
        f.* = null;
    }
    for (&icon_fonts) |*f| {
        if (f.*) |ff| lv.lv_tiny_ttf_destroy(ff);
        f.* = null;
    }
}

// ---------------------------------------------------------------------------
// State

var gpa: Allocator = undefined;
var io: Io = undefined;

/// Open folder and its JPEG file names
var folder: ?[:0]u8 = null;
var names: [][:0]u8 = &.{};
var selected: ?usize = null;

/// Open photo
var doc: ?edit.Doc = null;
var preview_buf: ?*lv.lv_draw_buf_t = null;
var preview_orig: [2]c_int = .{ 0, 0 };

/// Temporary strings for the current screen build
var frame_arena: std.heap.ArenaAllocator = undefined;
/// Dropdown options for `edit.choices` ("A\nB\n...")
var choice_options: [:0]u8 = undefined;

var quit_requested = false;
var dialog_timer: ?*lv.lv_timer_t = null;

/// What to do after the user agrees to discard unsaved changes
const Pending = union(enum) {
    none,
    open_file_dialog,
    open_folder_dialog,
    select: usize,
    batch,
    quit,
};
var pending: Pending = .none;

// Widgets
var toolbar_status: ?*lv.lv_obj_t = null;
var btn_save: ?*lv.lv_obj_t = null;
var btn_revert: ?*lv.lv_obj_t = null;
var btn_batch: ?*lv.lv_obj_t = null;
var files_card: ?*lv.lv_obj_t = null;
var files_title: ?*lv.lv_obj_t = null;
var files_list: ?*lv.lv_obj_t = null;
var preview_card: ?*lv.lv_obj_t = null;
var preview_img: ?*lv.lv_obj_t = null;
var preview_info: ?*lv.lv_obj_t = null;
var fields_card: ?*lv.lv_obj_t = null;
var fields_list: ?*lv.lv_obj_t = null;
var body: ?*lv.lv_obj_t = null;

/// Objects the in-app test drives (null when not on screen)
pub const Refs = struct {
    open_file_btn: ?*lv.lv_obj_t = null,
    open_folder_btn: ?*lv.lv_obj_t = null,
    save_btn: ?*lv.lv_obj_t = null,
    revert_btn: ?*lv.lv_obj_t = null,
    batch_btn: ?*lv.lv_obj_t = null,
    add_field_btn: ?*lv.lv_obj_t = null,
    file_buttons: [8]?*lv.lv_obj_t = @splat(null),
    // dialog
    dialog_ta: ?*lv.lv_obj_t = null,
    dialog_field_dd: ?*lv.lv_obj_t = null,
    dialog_orientation_dd: ?*lv.lv_obj_t = null,
    dialog_ok_btn: ?*lv.lv_obj_t = null,
    dialog_error: ?*lv.lv_obj_t = null,
    confirm_yes_btn: ?*lv.lv_obj_t = null,
    // batch dialog
    batch_add_btn: ?*lv.lv_obj_t = null,
    batch_gps_cb: ?*lv.lv_obj_t = null,
    batch_apply_btn: ?*lv.lv_obj_t = null,
    batch_close_btn: ?*lv.lv_obj_t = null,
    batch_summary: ?*lv.lv_obj_t = null,
};
pub var refs: Refs = .{};

/// Edit/delete buttons of the field rows, by tag (for the in-app test)
pub fn fieldButton(tag: Tag, delete: bool) ?*lv.lv_obj_t {
    for (row_refs[0..row_ref_count]) |r| {
        if (r.tag.eql(tag)) return if (delete) r.delete else r.edit;
    }
    return null;
}
const RowRef = struct { tag: Tag, edit: ?*lv.lv_obj_t, delete: ?*lv.lv_obj_t };
var row_refs: [256]RowRef = undefined;
var row_ref_count: usize = 0;

/// Batch operation rows, for the in-app test
pub const BatchRow = struct {
    action: ?*lv.lv_obj_t, // "Set" / "Remove"
    field: ?*lv.lv_obj_t,
    value: ?*lv.lv_obj_t,
};
pub var batch_rows: [16]BatchRow = undefined;
pub var batch_row_count: usize = 0;

/// Last message shown in the status bar (for the in-app test)
pub var status_buf: [256]u8 = undefined;
pub var status_text: []const u8 = "";

// ---------------------------------------------------------------------------
// Setup

pub fn init(allocator: Allocator, io_: Io, window: ?*sdl.SDL_Window, ui_scale: f32) !void {
    gpa = allocator;
    io = io_;
    frame_arena = .init(gpa);
    dialogs.init(gpa, window);

    var opts: std.Io.Writer.Allocating = .init(gpa);
    defer opts.deinit();
    for (edit.choices, 0..) |c, i| {
        if (i > 0) try opts.writer.writeByte('\n');
        try opts.writer.writeAll(c.label);
    }
    choice_options = try opts.toOwnedSliceSentinel(0);

    dialog_timer = lv.lv_timer_create(pollDialogs, 100, null);
    try build(ui_scale);
}

pub fn deinit() void {
    dialogs.deinit();
    if (dialog_timer) |t| lv.lv_timer_delete(t);
    if (batch_timer) |t| lv.lv_timer_delete(t);
    closeDoc(); // uses the preview image widget
    closeFolder();
    // Delete widgets before the fonts they use
    lv.lv_obj_clean(lv.lv_layer_top());
    lv.lv_obj_clean(lv.lv_screen_active());
    destroyFonts();
    batchFree();
    gpa.free(choice_options);
    frame_arena.deinit();
}

/// Rebuilds the UI for a new scale; open folder and photo are kept.
pub fn setScale(ui_scale: f32) !void {
    if (@abs(ui_scale - scale) < 0.01) return;
    lv.lv_obj_clean(lv.lv_layer_top());
    lv.lv_obj_clean(lv.lv_screen_active());
    refs = .{};
    destroyFonts();
    try build(ui_scale);
}

fn build(ui_scale: f32) !void {
    scale = ui_scale;
    font_normal = makeFont(font_regular_data, 15, 0);
    font_small = makeFont(font_regular_data, 13, 1);
    font_bold = makeFont(font_semibold_data, 15, 2);
    font_title = makeFont(font_semibold_data, 19, 3);
    if (font_normal == null or font_small == null or font_bold == null or font_title == null)
        return error.FontLoadFailed;

    const disp = lv.lv_display_get_default();
    const theme = lv.lv_theme_default_init(disp, lv.lv_color_hex(color_primary), lv.lv_color_hex(color_danger), false, font_normal);
    lv.lv_display_set_theme(disp, theme);

    const scr = lv.lv_screen_active();
    lv.lv_obj_set_style_text_font(scr, font_normal, 0);
    lv.lv_obj_set_style_text_font(lv.lv_layer_top(), font_normal, 0);
    lv.lv_obj_set_style_bg_color(scr, lv.lv_color_hex(color_bg), 0);
    lv.lv_obj_set_flex_flow(scr, lv.LV_FLEX_FLOW_COLUMN);
    lv.lv_obj_set_style_pad_all(scr, 0, 0);
    lv.lv_obj_set_style_pad_row(scr, 0, 0);
    lv.lv_obj_set_scrollable(scr, false);

    buildToolbar(scr);

    body = box(scr, lv.LV_FLEX_FLOW_ROW);
    lv.lv_obj_set_width(body, lv.lv_pct(100));
    lv.lv_obj_set_flex_grow(body, 1);
    lv.lv_obj_set_style_pad_all(body, dp(12), 0);
    lv.lv_obj_set_style_pad_column(body, dp(12), 0);
    lv.lv_obj_set_flex_align(body, lv.LV_FLEX_ALIGN_START, lv.LV_FLEX_ALIGN_START, lv.LV_FLEX_ALIGN_START);

    // Side panels shrink with the window so the preview always keeps room.
    files_card = card(body);
    lv.lv_obj_set_size(files_card, lv.lv_pct(20), lv.lv_pct(100));
    lv.lv_obj_set_style_min_width(files_card, dp(160), 0);
    lv.lv_obj_set_style_max_width(files_card, dp(260), 0);
    files_title = bold(files_card, "");
    files_list = lv.lv_obj_create(files_card);
    lv.lv_obj_remove_style_all(files_list);
    lv.lv_obj_set_width(files_list, lv.lv_pct(100));
    lv.lv_obj_set_flex_grow(files_list, 1);
    lv.lv_obj_set_flex_flow(files_list, lv.LV_FLEX_FLOW_COLUMN);
    lv.lv_obj_set_style_pad_row(files_list, dp(2), 0);
    lv.lv_obj_set_scroll_dir(files_list, lv.LV_DIR_VER);

    preview_card = card(body);
    lv.lv_obj_set_height(preview_card, lv.lv_pct(100));
    lv.lv_obj_set_width(preview_card, 1);
    lv.lv_obj_set_flex_grow(preview_card, 1);
    lv.lv_obj_set_style_min_width(preview_card, dp(180), 0);
    lv.lv_obj_set_flex_align(preview_card, lv.LV_FLEX_ALIGN_CENTER, lv.LV_FLEX_ALIGN_CENTER, lv.LV_FLEX_ALIGN_CENTER);
    preview_img = lv.lv_image_create(preview_card);
    preview_info = muted(preview_card, "");
    lv.lv_obj_set_style_text_align(preview_info, lv.LV_TEXT_ALIGN_CENTER, 0);

    fields_card = card(body);
    lv.lv_obj_set_size(fields_card, lv.lv_pct(46), lv.lv_pct(100));
    lv.lv_obj_set_style_min_width(fields_card, dp(360), 0);
    lv.lv_obj_set_style_max_width(fields_card, dp(620), 0);
    const head = box(fields_card, lv.LV_FLEX_FLOW_ROW);
    const t = title(head, "EXIF");
    lv.lv_obj_set_width(t, 1);
    lv.lv_obj_set_flex_grow(t, 1);
    refs.add_field_btn = button(head, lv.LV_SYMBOL_PLUS ++ "  Add field", onAddField, null);
    fields_list = lv.lv_obj_create(fields_card);
    lv.lv_obj_remove_style_all(fields_list);
    lv.lv_obj_set_width(fields_list, lv.lv_pct(100));
    lv.lv_obj_set_flex_grow(fields_list, 1);
    lv.lv_obj_set_flex_flow(fields_list, lv.LV_FLEX_FLOW_COLUMN);
    lv.lv_obj_set_style_pad_row(fields_list, dp(2), 0);
    lv.lv_obj_set_scroll_dir(fields_list, lv.LV_DIR_VER);

    renderFiles();
    renderDoc();
}

fn buildToolbar(scr: ?*lv.lv_obj_t) void {
    const bar = lv.lv_obj_create(scr);
    lv.lv_obj_remove_style_all(bar);
    lv.lv_obj_set_size(bar, lv.lv_pct(100), lv.LV_SIZE_CONTENT);
    lv.lv_obj_set_flex_flow(bar, lv.LV_FLEX_FLOW_ROW);
    lv.lv_obj_set_flex_align(bar, lv.LV_FLEX_ALIGN_START, lv.LV_FLEX_ALIGN_CENTER, lv.LV_FLEX_ALIGN_CENTER);
    lv.lv_obj_set_style_bg_color(bar, lv.lv_color_white(), 0);
    lv.lv_obj_set_style_bg_opa(bar, lv.LV_OPA_COVER, 0);
    lv.lv_obj_set_style_pad_hor(bar, dp(12), 0);
    lv.lv_obj_set_style_pad_ver(bar, dp(8), 0);
    lv.lv_obj_set_style_pad_column(bar, dp(8), 0);
    lv.lv_obj_set_style_shadow_width(bar, dp(8), 0);
    lv.lv_obj_set_style_shadow_opa(bar, lv.LV_OPA_10, 0);

    refs.open_file_btn = outlineButton(bar, lv.LV_SYMBOL_IMAGE ++ "  Open photo", onOpenFile, null, false);
    refs.open_folder_btn = outlineButton(bar, lv.LV_SYMBOL_DIRECTORY ++ "  Open folder", onOpenFolder, null, false);
    spacer(bar, dp(16));
    btn_save = button(bar, lv.LV_SYMBOL_SAVE ++ "  Save", onSave, null);
    btn_revert = outlineButton(bar, lv.LV_SYMBOL_REFRESH ++ "  Revert", onRevert, null, false);
    spacer(bar, dp(16));
    btn_batch = outlineButton(bar, lv.LV_SYMBOL_LIST ++ "  Batch edit folder", onBatch, null, false);
    refs.save_btn = btn_save;
    refs.revert_btn = btn_revert;
    refs.batch_btn = btn_batch;

    toolbar_status = lv.lv_label_create(bar);
    lv.lv_obj_set_width(toolbar_status, 1);
    lv.lv_obj_set_flex_grow(toolbar_status, 1);
    oneLine(toolbar_status, font_small);
    lv.lv_obj_set_style_text_align(toolbar_status, lv.LV_TEXT_ALIGN_RIGHT, 0);
    lv.lv_obj_set_style_text_font(toolbar_status, font_small, 0);
    setStatusText(status_text, status_color);
}

// ---------------------------------------------------------------------------
// Widget helpers

fn zfmt(comptime fmt: []const u8, args: anytype) [*:0]const u8 {
    return (std.fmt.allocPrintSentinel(frame_arena.allocator(), fmt, args, 0) catch return "").ptr;
}

fn box(parent: ?*lv.lv_obj_t, flow: lv.lv_flex_flow_t) ?*lv.lv_obj_t {
    const b = lv.lv_obj_create(parent);
    lv.lv_obj_remove_style_all(b);
    lv.lv_obj_set_size(b, lv.lv_pct(100), lv.LV_SIZE_CONTENT);
    lv.lv_obj_set_flex_flow(b, flow);
    lv.lv_obj_set_flex_align(b, lv.LV_FLEX_ALIGN_START, lv.LV_FLEX_ALIGN_CENTER, lv.LV_FLEX_ALIGN_CENTER);
    lv.lv_obj_set_style_pad_column(b, dp(8), 0);
    lv.lv_obj_set_style_pad_row(b, dp(6), 0);
    return b;
}

fn spacer(parent: ?*lv.lv_obj_t, w: i32) void {
    const s = lv.lv_obj_create(parent);
    lv.lv_obj_remove_style_all(s);
    lv.lv_obj_set_size(s, w, 1);
}

fn card(parent: ?*lv.lv_obj_t) ?*lv.lv_obj_t {
    const c = lv.lv_obj_create(parent);
    lv.lv_obj_set_flex_flow(c, lv.LV_FLEX_FLOW_COLUMN);
    lv.lv_obj_set_style_pad_all(c, dp(14), 0);
    lv.lv_obj_set_style_pad_row(c, dp(10), 0);
    lv.lv_obj_set_style_radius(c, dp(12), 0);
    lv.lv_obj_set_style_border_width(c, 0, 0);
    lv.lv_obj_set_style_shadow_width(c, dp(16), 0);
    lv.lv_obj_set_style_shadow_offset_y(c, dp(3), 0);
    lv.lv_obj_set_style_shadow_opa(c, lv.LV_OPA_10, 0);
    lv.lv_obj_set_scrollable(c, false);
    return c;
}

/// Keeps a label on one line and ends it with "..." if it does not fit.
fn oneLine(l: ?*lv.lv_obj_t, font: ?*const lv.lv_font_t) void {
    lv.lv_label_set_long_mode(l, lv.LV_LABEL_LONG_MODE_DOTS);
    lv.lv_obj_set_height(l, lv.lv_font_get_line_height(font));
}

fn label(parent: ?*lv.lv_obj_t, s: [*:0]const u8) ?*lv.lv_obj_t {
    const l = lv.lv_label_create(parent);
    lv.lv_label_set_text(l, s);
    lv.lv_label_set_long_mode(l, lv.LV_LABEL_LONG_MODE_WRAP);
    lv.lv_obj_set_width(l, lv.lv_pct(100));
    return l;
}

fn title(parent: ?*lv.lv_obj_t, s: [*:0]const u8) ?*lv.lv_obj_t {
    const l = label(parent, s);
    lv.lv_obj_set_style_text_font(l, font_title, 0);
    lv.lv_obj_set_style_text_color(l, lv.lv_color_hex(color_text), 0);
    return l;
}

fn bold(parent: ?*lv.lv_obj_t, s: [*:0]const u8) ?*lv.lv_obj_t {
    const l = label(parent, s);
    lv.lv_obj_set_style_text_font(l, font_bold, 0);
    return l;
}

fn muted(parent: ?*lv.lv_obj_t, s: [*:0]const u8) ?*lv.lv_obj_t {
    const l = label(parent, s);
    lv.lv_obj_set_style_text_font(l, font_small, 0);
    lv.lv_obj_set_style_text_opa(l, lv.LV_OPA_60, 0);
    return l;
}

fn button(parent: ?*lv.lv_obj_t, s: [*:0]const u8, cb: lv.lv_event_cb_t, user_data: ?*anyopaque) ?*lv.lv_obj_t {
    const b = lv.lv_button_create(parent);
    const l = lv.lv_label_create(b);
    lv.lv_label_set_text(l, s);
    lv.lv_obj_center(l);
    lv.lv_obj_set_style_radius(b, dp(8), 0);
    lv.lv_obj_set_style_pad_hor(b, dp(14), 0);
    lv.lv_obj_set_style_pad_ver(b, dp(8), 0);
    _ = lv.lv_obj_add_event_cb(b, cb, lv.LV_EVENT_CLICKED, user_data);
    return b;
}

fn outlineButton(parent: ?*lv.lv_obj_t, s: [*:0]const u8, cb: lv.lv_event_cb_t, user_data: ?*anyopaque, danger: bool) ?*lv.lv_obj_t {
    const b = button(parent, s, cb, user_data);
    const color = lv.lv_color_hex(if (danger) color_danger else color_primary);
    lv.lv_obj_set_style_bg_color(b, lv.lv_color_white(), 0);
    lv.lv_obj_set_style_border_color(b, color, 0);
    lv.lv_obj_set_style_border_width(b, dp(1), 0);
    lv.lv_obj_set_style_text_color(b, color, 0);
    lv.lv_obj_set_style_shadow_width(b, 0, 0);
    return b;
}

fn iconButton(parent: ?*lv.lv_obj_t, symbol: [*:0]const u8, cb: lv.lv_event_cb_t, user_data: ?*anyopaque, danger: bool) ?*lv.lv_obj_t {
    const b = outlineButton(parent, symbol, cb, user_data, danger);
    lv.lv_obj_set_size(b, dp(32), dp(32));
    lv.lv_obj_set_style_pad_all(b, 0, 0);
    lv.lv_obj_set_style_border_width(b, 0, 0);
    lv.lv_obj_set_style_bg_opa(b, lv.LV_OPA_TRANSP, 0);
    return b;
}

fn setEnabled(obj: ?*lv.lv_obj_t, on: bool) void {
    if (on) lv.lv_obj_remove_state(obj, lv.LV_STATE_DISABLED) else lv.lv_obj_add_state(obj, lv.LV_STATE_DISABLED);
}

fn textarea(parent: ?*lv.lv_obj_t, initial: [*:0]const u8) ?*lv.lv_obj_t {
    const ta = lv.lv_textarea_create(parent);
    lv.lv_obj_set_width(ta, lv.lv_pct(100));
    lv.lv_textarea_set_one_line(ta, true);
    lv.lv_textarea_set_max_length(ta, 2000);
    lv.lv_obj_set_style_radius(ta, dp(8), 0);
    lv.lv_textarea_set_text(ta, initial);
    _ = lv.lv_obj_add_event_cb(ta, onTextChanged, lv.LV_EVENT_VALUE_CHANGED, null);
    return ta;
}

/// Typing again hides the previous error message of the dialog.
fn onTextChanged(_: ?*lv.lv_event_t) callconv(.c) void {
    if (dialog_error) |l| lv.lv_obj_set_hidden(l, true);
}

fn dropdown(parent: ?*lv.lv_obj_t, options: [*:0]const u8) ?*lv.lv_obj_t {
    const dd = lv.lv_dropdown_create(parent);
    lv.lv_dropdown_set_options(dd, options);
    lv.lv_obj_set_style_radius(dd, dp(8), 0);
    return dd;
}

/// Tag packed into an event's user data (no allocation needed)
fn tagToPtr(tag: Tag) ?*anyopaque {
    return @ptrFromInt((@as(usize, @backingInt(tag.kind)) << 16 | tag.num) + 1);
}

fn ptrToTag(p: ?*anyopaque) Tag {
    const v = @intFromPtr(p) - 1;
    return .{ .kind = @fromBackingInt(@intCast(@as(u3, @intCast(v >> 16)))), .num = @truncate(v) };
}

// ---------------------------------------------------------------------------
// Status bar

const StatusColor = enum { normal, ok, warn, err };
var status_color: StatusColor = .normal;

fn setStatus(color: StatusColor, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&status_buf, fmt, args) catch status_buf[0..];
    setStatusText(s, color);
}

fn setStatusText(s: []const u8, color: StatusColor) void {
    status_text = s;
    status_color = color;
    if (toolbar_status == null) return;
    var buf: [260]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{s}, 0) catch return;
    lv.lv_label_set_text(toolbar_status, z.ptr);
    lv.lv_obj_set_style_text_color(toolbar_status, lv.lv_color_hex(switch (color) {
        .normal => 0x616161,
        .ok => color_success,
        .warn => color_warning,
        .err => color_danger,
    }), 0);
}

fn updateToolbar() void {
    const dirty = if (doc) |d| d.dirty else false;
    setEnabled(btn_save, dirty);
    setEnabled(btn_revert, dirty);
    setEnabled(btn_batch, folder != null and names.len > 0);
    setEnabled(refs.add_field_btn, doc != null);
    if (dirty) setStatusText("Unsaved changes", .warn);
}

// ---------------------------------------------------------------------------
// Opening

fn closeDoc() void {
    if (preview_buf) |b| {
        lv.lv_image_set_src(preview_img, null);
        lv.lv_draw_buf_destroy(b);
        preview_buf = null;
    }
    if (doc) |*d| d.deinit();
    doc = null;
}

fn closeFolder() void {
    edit.freeNames(gpa, names);
    names = &.{};
    if (folder) |f| gpa.free(f);
    folder = null;
    selected = null;
}

fn loadDoc(path: []const u8) void {
    closeDoc();
    doc = edit.Doc.load(gpa, io, path) catch |err| {
        setStatus(.err, "Cannot open {s}: {s}", .{ std.fs.path.basename(path), edit.errorMessage(err) });
        renderDoc();
        return;
    };
    setStatus(.normal, "{s}", .{path});
    renderDoc();
}

fn openFolder(path: []const u8) void {
    const list = edit.listJpegs(gpa, io, path) catch |err| {
        setStatus(.err, "Cannot open folder {s}: {s}", .{ path, edit.errorMessage(err) });
        return;
    };
    closeDoc();
    closeFolder();
    names = list;
    folder = gpa.dupeSentinel(u8, path, 0) catch null;
    renderFiles();
    if (names.len > 0) selectFile(0) else {
        renderDoc();
        setStatus(.warn, "No JPEG files in {s}", .{path});
    }
}

fn selectFile(i: usize) void {
    selected = i;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ folder.?, names[i] }) catch return;
    loadDoc(p);
    highlightFile();
}

/// Opens a photo or a folder (command line argument or test).
pub fn openPath(path: []const u8) void {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch |err| {
        setStatus(.err, "Cannot open {s}: {s}", .{ path, edit.errorMessage(err) });
        return;
    };
    if (st.kind == .directory) {
        openFolder(path);
    } else {
        closeFolder();
        renderFiles();
        loadDoc(path);
    }
}

/// Runs `action` now, or after confirming that unsaved changes may be lost.
fn guarded(action: Pending) void {
    if (doc) |d| {
        if (d.dirty) {
            confirm("Discard unsaved changes?", zfmt("{s} has changes that were not saved.", .{std.fs.path.basename(d.path)}), "Discard", onDiscardYes);
            pending = action; // after confirm(), which clears it
            return;
        }
    }
    runPending(action);
}

fn onDiscardYes(e: ?*lv.lv_event_t) callconv(.c) void {
    closeConfirm(e);
    if (doc) |*d| d.dirty = false;
    const p = pending;
    pending = .none;
    runPending(p);
}

fn runPending(action: Pending) void {
    switch (action) {
        .none => {},
        .open_file_dialog => dialogs.start(.open_file, folder orelse if (doc) |d| std.fs.path.dirname(d.path) else null),
        .open_folder_dialog => dialogs.start(.open_folder, folder orelse if (doc) |d| std.fs.path.dirname(d.path) else null),
        .select => |i| selectFile(i),
        .batch => openBatchDialog(),
        .quit => quit_requested = true,
    }
    updateToolbar();
}

fn pollDialogs(_: ?*lv.lv_timer_t) callconv(.c) void {
    const r = dialogs.poll() orelse return;
    if (r.err) |msg| {
        setStatus(.err, "Could not show the open dialog ({s}). You can pass a path on the command line: eexif <photo or folder>", .{msg});
        return;
    }
    const path = r.path orelse return;
    defer gpa.free(path);
    switch (r.kind) {
        .open_file => {
            closeFolder();
            renderFiles();
            loadDoc(path);
        },
        .open_folder => openFolder(path),
    }
    updateToolbar();
}

fn onOpenFile(_: ?*lv.lv_event_t) callconv(.c) void {
    guarded(.open_file_dialog);
}

fn onOpenFolder(_: ?*lv.lv_event_t) callconv(.c) void {
    guarded(.open_folder_dialog);
}

pub fn openFileShortcut() void {
    if (lv.lv_obj_get_child_count(lv.lv_layer_top()) == 0) guarded(.open_file_dialog);
}

fn onFileClicked(e: ?*lv.lv_event_t) callconv(.c) void {
    const i = @intFromPtr(lv.lv_event_get_user_data(e)) - 1;
    if (selected == i) return;
    guarded(.{ .select = i });
}

// ---------------------------------------------------------------------------
// Saving

fn save() void {
    const d = &(doc orelse return);
    if (!d.dirty) return;
    d.save(io) catch |err| {
        setStatus(.err, "Could not save {s}: {s}", .{ std.fs.path.basename(d.path), edit.errorMessage(err) });
        return;
    };
    setStatus(.ok, "Saved {s}", .{std.fs.path.basename(d.path)});
    renderFields();
    updateToolbar();
}

fn onSave(_: ?*lv.lv_event_t) callconv(.c) void {
    save();
}

pub fn saveShortcut() void {
    if (lv.lv_obj_get_child_count(lv.lv_layer_top()) == 0) save();
}

fn onRevert(_: ?*lv.lv_event_t) callconv(.c) void {
    const d = &(doc orelse return);
    d.revert() catch |err| {
        setStatus(.err, "Could not revert: {s}", .{edit.errorMessage(err)});
        return;
    };
    setStatus(.normal, "Reverted {s}", .{std.fs.path.basename(d.path)});
    renderDoc();
}

pub fn requestQuit() void {
    if (batch_running) return;
    guarded(.quit);
}

pub fn shouldQuit() bool {
    return quit_requested;
}

/// Escape: closes the open dialog. Returns false if there was none.
pub fn back() bool {
    if (batch_running) return true;
    if (lv.lv_obj_get_child_count(lv.lv_layer_top()) == 0) return false;
    closeModal();
    return true;
}

// ---------------------------------------------------------------------------
// File list

fn renderFiles() void {
    for (&refs.file_buttons) |*b| b.* = null;
    lv.lv_obj_clean(files_list);
    if (folder == null) {
        lv.lv_obj_set_hidden(files_card, true);
        return;
    }
    lv.lv_obj_set_hidden(files_card, false);
    lv.lv_label_set_text(files_title, zfmt("{s}\n{d} JPEG file{s}", .{
        std.fs.path.basename(folder.?), names.len, if (names.len == 1) "" else "s",
    }));
    for (names, 0..) |n, i| {
        const b = lv.lv_button_create(files_list);
        lv.lv_obj_set_width(b, lv.lv_pct(100));
        lv.lv_obj_set_style_shadow_width(b, 0, 0);
        lv.lv_obj_set_style_radius(b, dp(6), 0);
        lv.lv_obj_set_style_pad_ver(b, dp(6), 0);
        lv.lv_obj_set_style_pad_hor(b, dp(8), 0);
        lv.lv_obj_set_style_bg_color(b, lv.lv_color_white(), 0);
        lv.lv_obj_set_style_text_color(b, lv.lv_color_hex(color_text), 0);
        lv.lv_obj_set_style_bg_color(b, lv.lv_color_hex(color_section), lv.LV_STATE_CHECKED);
        lv.lv_obj_set_style_text_color(b, lv.lv_color_hex(color_primary), lv.LV_STATE_CHECKED);
        const l = lv.lv_label_create(b);
        lv.lv_label_set_text(l, n.ptr);
        lv.lv_label_set_long_mode(l, lv.LV_LABEL_LONG_MODE_DOTS);
        lv.lv_obj_set_width(l, lv.lv_pct(100));
        _ = lv.lv_obj_add_event_cb(b, onFileClicked, lv.LV_EVENT_CLICKED, @ptrFromInt(i + 1));
        if (i < refs.file_buttons.len) refs.file_buttons[i] = b;
    }
    highlightFile();
}

fn highlightFile() void {
    const n = lv.lv_obj_get_child_count(files_list);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const b = lv.lv_obj_get_child(files_list, @intCast(i));
        if (selected != null and selected.? == i) {
            lv.lv_obj_add_state(b, lv.LV_STATE_CHECKED);
            lv.lv_obj_scroll_to_view(b, false);
        } else lv.lv_obj_remove_state(b, lv.LV_STATE_CHECKED);
    }
}

// ---------------------------------------------------------------------------
// Preview

pub fn onResize() void {
    renderPreview();
}

fn renderDoc() void {
    renderPreview();
    renderFields();
    updateToolbar();
}

fn renderPreview() void {
    if (preview_buf) |b| {
        lv.lv_image_set_src(preview_img, null);
        lv.lv_draw_buf_destroy(b);
        preview_buf = null;
    }
    const d = doc orelse {
        lv.lv_obj_set_hidden(preview_img, true);
        lv.lv_label_set_text(preview_info, if (folder != null)
            "This folder has no JPEG files."
        else
            "Open a photo or a folder of photos to start.\n\nIn a folder you can edit photos one by one, or change all of them at once with Batch edit folder.");
        return;
    };
    lv.lv_obj_update_layout(preview_card);
    const max_w = lv.lv_obj_get_content_width(preview_card);
    const max_h = lv.lv_obj_get_content_height(preview_card) - dp(60);
    const orientation: c_int = @intCast(if (d.exif.getOrientation()) |o| @backingInt(o) else 1);
    preview_buf = eexif_decode_preview(d.data.ptr, d.data.len, max_w, @max(max_h, 1), orientation, &preview_orig[0], &preview_orig[1]);

    const kb = (d.data.len + 512) / 1024;
    if (preview_buf) |b| {
        lv.lv_obj_set_hidden(preview_img, false);
        lv.lv_image_set_src(preview_img, b);
        lv.lv_label_set_text(preview_info, zfmt("{s}\n{d} x {d} px, {d} KB", .{ std.fs.path.basename(d.path), preview_orig[0], preview_orig[1], kb }));
    } else {
        lv.lv_obj_set_hidden(preview_img, true);
        lv.lv_label_set_text(preview_info, zfmt("{s}\n{d} KB\n\nNo preview for this image (EXIF can still be edited).", .{ std.fs.path.basename(d.path), kb }));
    }
}

// ---------------------------------------------------------------------------
// Field list

const sections = [_]struct { kind: wexif.IfdKind, name: [*:0]const u8 }{
    .{ .kind = .ifd0, .name = "Image" },
    .{ .kind = .exif, .name = "Photo" },
    .{ .kind = .gps, .name = "GPS" },
    .{ .kind = .interop, .name = "Interoperability" },
    .{ .kind = .ifd1, .name = "Thumbnail" },
};

fn renderFields() void {
    _ = frame_arena.reset(.retain_capacity);
    row_ref_count = 0;
    lv.lv_obj_clean(fields_list);
    lv.lv_obj_scroll_to_y(fields_list, 0, false);
    const d = &(doc orelse {
        _ = muted(fields_list, "No photo open.");
        return;
    });
    if (d.exif.isEmpty()) {
        _ = muted(fields_list, "This photo has no EXIF data. Use Add field to create some.");
        return;
    }
    const a = frame_arena.allocator();
    for (sections) |sec| {
        const entries = d.exif.entries(sec.kind);
        if (entries.len == 0 and !(sec.kind == .ifd1 and d.exif.thumbnail != null)) continue;
        const h = bold(fields_list, zfmt("{s}", .{sec.name}));
        lv.lv_obj_set_style_bg_color(h, lv.lv_color_hex(color_section), 0);
        lv.lv_obj_set_style_bg_opa(h, lv.LV_OPA_COVER, 0);
        lv.lv_obj_set_style_radius(h, dp(6), 0);
        lv.lv_obj_set_style_pad_hor(h, dp(8), 0);
        lv.lv_obj_set_style_pad_ver(h, dp(4), 0);
        lv.lv_obj_set_style_margin_top(h, dp(6), 0);
        lv.lv_obj_set_style_text_color(h, lv.lv_color_hex(color_primary), 0);

        for (entries) |e| {
            const tag: Tag = .{ .kind = sec.kind, .num = e.tag };
            var name_buf: [8]u8 = undefined;
            const text = edit.displayText(a, &d.exif, tag, e.value) catch "?";
            const editable = !(e.value == .undefined and e.value.undefined.len > 64);
            fieldRow(tag, zfmt("{s}", .{edit.tagName(&name_buf, tag)}), zfmt("{s}", .{text}), editable);
        }
        if (sec.kind == .ifd1 and d.exif.thumbnail != null) {
            const th = d.exif.thumbnail.?;
            const row = box(fields_list, lv.LV_FLEX_FLOW_ROW);
            lv.lv_obj_set_style_pad_hor(row, dp(8), 0);
            const n = muted(row, zfmt("Thumbnail image: {d} KB", .{(th.len + 512) / 1024}));
            lv.lv_obj_set_width(n, 1);
            lv.lv_obj_set_flex_grow(n, 1);
            _ = iconButton(row, lv.LV_SYMBOL_TRASH, onRemoveThumbnail, null, true);
        }
    }
}

fn fieldRow(tag: Tag, name: [*:0]const u8, value: [*:0]const u8, editable: bool) void {
    const row = box(fields_list, lv.LV_FLEX_FLOW_ROW);
    lv.lv_obj_set_style_pad_hor(row, dp(8), 0);
    lv.lv_obj_set_style_pad_ver(row, dp(2), 0);
    const n = lv.lv_label_create(row);
    lv.lv_label_set_text(n, name);
    lv.lv_obj_set_width(n, dp(190));
    lv.lv_obj_set_style_text_font(n, font_small, 0);
    oneLine(n, font_small);
    lv.lv_obj_set_style_text_opa(n, lv.LV_OPA_70, 0);
    const v = lv.lv_label_create(row);
    lv.lv_label_set_text(v, value);
    lv.lv_label_set_long_mode(v, lv.LV_LABEL_LONG_MODE_WRAP);
    lv.lv_obj_set_width(v, 1);
    lv.lv_obj_set_flex_grow(v, 1);
    lv.lv_obj_set_style_text_color(v, lv.lv_color_hex(color_text), 0);
    const ed = if (editable) iconButton(row, lv.LV_SYMBOL_EDIT, onEditField, tagToPtr(tag), false) else blk: {
        spacer(row, dp(32));
        break :blk null;
    };
    const del = iconButton(row, lv.LV_SYMBOL_TRASH, onDeleteField, tagToPtr(tag), true);
    if (row_ref_count < row_refs.len) {
        row_refs[row_ref_count] = .{ .tag = tag, .edit = ed, .delete = del };
        row_ref_count += 1;
    }
}

fn markChanged(tag: ?Tag) void {
    const d = &(doc orelse return);
    d.dirty = true;
    renderFields();
    if (tag == null or tag.?.eql(.orientation)) renderPreview();
    updateToolbar();
}

fn onDeleteField(e: ?*lv.lv_event_t) callconv(.c) void {
    const d = &(doc orelse return);
    const tag = ptrToTag(lv.lv_event_get_user_data(e));
    _ = d.exif.remove(tag);
    markChanged(tag);
}

fn onRemoveThumbnail(_: ?*lv.lv_event_t) callconv(.c) void {
    const d = &(doc orelse return);
    d.exif.removeThumbnail();
    markChanged(.compression);
}

// ---------------------------------------------------------------------------
// Modal dialogs (on the top layer)

/// White box in the middle of a dimmed backdrop. Returns the box.
fn modal(width: i32) ?*lv.lv_obj_t {
    const backdrop = lv.lv_obj_create(lv.lv_layer_top());
    lv.lv_obj_remove_style_all(backdrop);
    lv.lv_obj_set_size(backdrop, lv.lv_pct(100), lv.lv_pct(100));
    lv.lv_obj_set_style_bg_color(backdrop, lv.lv_color_black(), 0);
    lv.lv_obj_set_style_bg_opa(backdrop, lv.LV_OPA_40, 0);
    lv.lv_obj_set_clickable(backdrop, true); // blocks clicks below
    const c = card(backdrop);
    lv.lv_obj_set_width(c, @min(width, lv.lv_display_get_horizontal_resolution(lv.lv_display_get_default()) - dp(40)));
    lv.lv_obj_set_height(c, lv.LV_SIZE_CONTENT);
    lv.lv_obj_set_style_max_height(c, lv.lv_display_get_vertical_resolution(lv.lv_display_get_default()) - dp(40), 0);
    lv.lv_obj_set_scrollable(c, true);
    lv.lv_obj_center(c);
    lv.lv_obj_set_style_pad_all(c, dp(20), 0);
    lv.lv_obj_set_style_pad_row(c, dp(12), 0);
    return c;
}

fn closeModal() void {
    lv.lv_obj_clean(lv.lv_layer_top());
    refs.dialog_ta = null;
    refs.dialog_field_dd = null;
    refs.dialog_orientation_dd = null;
    refs.dialog_ok_btn = null;
    refs.dialog_error = null;
    refs.confirm_yes_btn = null;
    refs.batch_add_btn = null;
    refs.batch_gps_cb = null;
    refs.batch_apply_btn = null;
    refs.batch_close_btn = null;
    refs.batch_summary = null;
    batch_row_count = 0;
    dialog_error = null;
    pending = .none;
}

/// Footer with Cancel and a primary button; returns the primary button.
fn footer(parent: ?*lv.lv_obj_t, ok_text: [*:0]const u8, on_ok: lv.lv_event_cb_t, danger: bool) ?*lv.lv_obj_t {
    const row = box(parent, lv.LV_FLEX_FLOW_ROW);
    lv.lv_obj_set_flex_align(row, lv.LV_FLEX_ALIGN_END, lv.LV_FLEX_ALIGN_CENTER, lv.LV_FLEX_ALIGN_CENTER);
    lv.lv_obj_set_style_pad_top(row, dp(6), 0);
    _ = outlineButton(row, "Cancel", onModalCancel, null, false);
    const ok = button(row, ok_text, on_ok, null);
    if (danger) lv.lv_obj_set_style_bg_color(ok, lv.lv_color_hex(color_danger), 0);
    return ok;
}

fn onModalCancel(_: ?*lv.lv_event_t) callconv(.c) void {
    closeModal();
}

fn confirm(question: [*:0]const u8, detail: [*:0]const u8, yes_text: [*:0]const u8, on_yes: lv.lv_event_cb_t) void {
    closeModal();
    const c = modal(dp(460));
    _ = title(c, question);
    _ = label(c, detail);
    refs.confirm_yes_btn = footer(c, yes_text, on_yes, true);
}

fn closeConfirm(_: ?*lv.lv_event_t) void {
    const keep = pending;
    pending = .none;
    closeModal();
    pending = keep;
}

var dialog_error: ?*lv.lv_obj_t = null;

fn showDialogError(msg: []const u8) void {
    const l = dialog_error orelse return;
    var buf: [300]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{msg}, 0) catch return;
    lv.lv_label_set_text(l, z.ptr);
    lv.lv_obj_set_hidden(l, false);
}

fn errorLabel(parent: ?*lv.lv_obj_t) ?*lv.lv_obj_t {
    const l = label(parent, "");
    lv.lv_obj_set_style_text_color(l, lv.lv_color_hex(color_danger), 0);
    lv.lv_obj_set_hidden(l, true);
    dialog_error = l;
    refs.dialog_error = l;
    return l;
}

// ---------------------------------------------------------------------------
// Edit / Add field dialog

var dialog_target: edit.Target = .date_taken;
var dialog_hint: ?*lv.lv_obj_t = null;
var dialog_value_box: ?*lv.lv_obj_t = null;

const orientation_options = "Normal (1)\nMirror horizontal (2)\nRotate 180 (3)\nMirror vertical (4)\nMirror horizontal, rotate 270 CW (5)\nRotate 90 CW (6)\nMirror horizontal, rotate 90 CW (7)\nRotate 270 CW (8)";

fn onEditField(e: ?*lv.lv_event_t) callconv(.c) void {
    const tag = ptrToTag(lv.lv_event_get_user_data(e));
    var name_buf: [8]u8 = undefined;
    openFieldDialog(zfmt("Edit {s}", .{edit.tagName(&name_buf, tag)}), .{ .tag = tag }, false);
}

fn onAddField(_: ?*lv.lv_event_t) callconv(.c) void {
    if (doc == null) return;
    openFieldDialog("Add or change a field", edit.choices[0].target, true);
}

fn openFieldDialog(heading: [*:0]const u8, target: edit.Target, choose: bool) void {
    closeModal();
    dialog_target = target;
    const c = modal(dp(600));
    _ = title(c, heading);
    if (choose) {
        _ = muted(c, "Field");
        const dd = dropdown(c, choice_options.ptr);
        lv.lv_obj_set_width(dd, lv.lv_pct(100));
        _ = lv.lv_obj_add_event_cb(dd, onFieldChosen, lv.LV_EVENT_VALUE_CHANGED, null);
        refs.dialog_field_dd = dd;
        _ = muted(c, "Value");
    }
    dialog_value_box = box(c, lv.LV_FLEX_FLOW_COLUMN);
    dialog_hint = muted(c, "");
    _ = errorLabel(c);
    refs.dialog_ok_btn = footer(c, if (choose) "Add" else "Apply", onFieldOk, false);
    fillValueEditor();
}

/// Value editor for `dialog_target`: a dropdown for Orientation, else a
/// text box with the current value.
fn fillValueEditor() void {
    lv.lv_obj_clean(dialog_value_box);
    refs.dialog_ta = null;
    refs.dialog_orientation_dd = null;
    if (dialog_error) |l| lv.lv_obj_set_hidden(l, true);
    lv.lv_label_set_text(dialog_hint, zfmt("{s}", .{edit.formatHint(dialog_target)}));
    const d = &(doc orelse return);

    if (dialog_target == .tag and dialog_target.tag.eql(.orientation)) {
        const dd = dropdown(dialog_value_box, orientation_options);
        lv.lv_obj_set_width(dd, lv.lv_pct(100));
        const cur = if (d.exif.getOrientation()) |o| @backingInt(o) else 1;
        lv.lv_dropdown_set_selected(dd, cur - 1);
        refs.dialog_orientation_dd = dd;
        lv.lv_label_set_text(dialog_hint, "Only tells viewers how to display the photo; the pixels are not changed.");
        return;
    }
    const current: [*:0]const u8 = switch (dialog_target) {
        .date_taken => if (d.exif.getDateTime()) |dt| zfmt("{f}", .{dt}) else "",
        .tag => |t| if (d.exif.get(t)) |v| blk: {
            const txt: [:0]const u8 = edit.editText(frame_arena.allocator(), &d.exif, t, v) catch "";
            break :blk txt.ptr;
        } else "",
    };
    const ta = textarea(dialog_value_box, current);
    _ = lv.lv_obj_add_event_cb(ta, onFieldOkEvent, lv.LV_EVENT_READY, null);
    lv.lv_group_focus_obj(ta);
    lv.lv_textarea_set_cursor_pos(ta, lv.LV_TEXTAREA_CURSOR_LAST);
    refs.dialog_ta = ta;
}

fn onFieldChosen(e: ?*lv.lv_event_t) callconv(.c) void {
    const dd: ?*lv.lv_obj_t = @ptrCast(@alignCast(lv.lv_event_get_target(e)));
    dialog_target = edit.choices[lv.lv_dropdown_get_selected(dd)].target;
    fillValueEditor();
}

fn onFieldOkEvent(_: ?*lv.lv_event_t) callconv(.c) void {
    applyFieldDialog();
}

fn onFieldOk(_: ?*lv.lv_event_t) callconv(.c) void {
    applyFieldDialog();
}

fn applyFieldDialog() void {
    const d = &(doc orelse return);
    var buf: [16]u8 = undefined;
    const text: []const u8 = if (refs.dialog_orientation_dd) |dd|
        std.fmt.bufPrint(&buf, "{d}", .{lv.lv_dropdown_get_selected(dd) + 1}) catch unreachable
    else if (refs.dialog_ta) |ta|
        std.mem.span(lv.lv_textarea_get_text(ta))
    else
        return;
    edit.applyText(&d.exif, dialog_target, text) catch |err| {
        showDialogError(edit.errorMessage(err));
        return;
    };
    const tag: ?Tag = switch (dialog_target) {
        .date_taken => null,
        .tag => |t| t,
    };
    closeModal();
    markChanged(tag);
}

// ---------------------------------------------------------------------------
// Batch edit

var batch_arena: ?std.heap.ArenaAllocator = null;
var batch_ops: []edit.Op = &.{};
var batch_index: usize = 0;
var batch_ok: usize = 0;
var batch_failures: std.ArrayList(u8) = .empty;
var batch_failed: usize = 0;
var batch_running = false;
var batch_timer: ?*lv.lv_timer_t = null;
var batch_rows_box: ?*lv.lv_obj_t = null;
var batch_progress_bar: ?*lv.lv_obj_t = null;
var batch_progress_label: ?*lv.lv_obj_t = null;
var batch_strip_all_cb: ?*lv.lv_obj_t = null;
var batch_thumb_cb: ?*lv.lv_obj_t = null;

fn batchFree() void {
    if (batch_arena) |*a| a.deinit();
    batch_arena = null;
    batch_ops = &.{};
    batch_failures.deinit(gpa);
    batch_failures = .empty;
}

fn onBatch(_: ?*lv.lv_event_t) callconv(.c) void {
    if (folder == null or names.len == 0) return;
    guarded(.batch);
}

fn openBatchDialog() void {
    closeModal();
    const c = modal(dp(820));
    _ = title(c, "Batch edit folder");
    _ = muted(c, zfmt("Changes are applied to all {d} JPEG files in {s}. Each file is saved right away.", .{ names.len, folder.? }));

    batch_rows_box = box(c, lv.LV_FLEX_FLOW_COLUMN);
    lv.lv_obj_set_style_pad_row(batch_rows_box, dp(8), 0);
    batch_row_count = 0;
    addBatchRow();
    refs.batch_add_btn = outlineButton(c, lv.LV_SYMBOL_PLUS ++ "  Add another change", onBatchAddRow, null, false);

    refs.batch_gps_cb = checkbox(c, "Remove GPS location");
    batch_thumb_cb = checkbox(c, "Remove thumbnail");
    batch_strip_all_cb = checkbox(c, "Remove all EXIF first (then apply the changes above)");
    _ = errorLabel(c);
    refs.batch_apply_btn = footer(c, zfmt("Apply to {d} files", .{names.len}), onBatchApply, false);
}

fn checkbox(parent: ?*lv.lv_obj_t, text: [*:0]const u8) ?*lv.lv_obj_t {
    const cb = lv.lv_checkbox_create(parent);
    lv.lv_checkbox_set_text(cb, text);
    return cb;
}

fn addBatchRow() void {
    if (batch_row_count == batch_rows.len) return;
    const row = box(batch_rows_box, lv.LV_FLEX_FLOW_ROW);
    const action = dropdown(row, "Set\nRemove");
    lv.lv_obj_set_width(action, dp(110));
    const field = dropdown(row, choice_options.ptr);
    lv.lv_obj_set_width(field, dp(260));
    const value = textarea(row, "");
    lv.lv_textarea_set_placeholder_text(value, "Value");
    lv.lv_obj_set_width(value, 1);
    lv.lv_obj_set_flex_grow(value, 1);
    _ = lv.lv_obj_add_event_cb(action, onBatchActionChanged, lv.LV_EVENT_VALUE_CHANGED, value);
    batch_rows[batch_row_count] = .{ .action = action, .field = field, .value = value };
    batch_row_count += 1;
}

fn onBatchAddRow(_: ?*lv.lv_event_t) callconv(.c) void {
    addBatchRow();
}

fn onBatchActionChanged(e: ?*lv.lv_event_t) callconv(.c) void {
    const dd: ?*lv.lv_obj_t = @ptrCast(@alignCast(lv.lv_event_get_target(e)));
    const value: ?*lv.lv_obj_t = @ptrCast(@alignCast(lv.lv_event_get_user_data(e)));
    if (lv.lv_dropdown_get_selected(dd) == 1) lv.lv_obj_set_hidden(value, true) else lv.lv_obj_set_hidden(value, false);
}

fn isChecked(cb: ?*lv.lv_obj_t) bool {
    return lv.lv_obj_has_state(cb, lv.LV_STATE_CHECKED);
}

/// Reads the batch dialog into `batch_ops`. Returns false and shows an
/// error if nothing was chosen or a value is invalid.
fn collectBatchOps() bool {
    batchFree();
    batch_arena = .init(gpa);
    const a = batch_arena.?.allocator();
    var ops: std.ArrayList(edit.Op) = .empty;

    if (isChecked(batch_strip_all_cb)) ops.append(a, .remove_all) catch return false;
    var row_of_op: [32]usize = undefined;
    for (batch_rows[0..batch_row_count], 0..) |r, i| {
        const target = edit.choices[lv.lv_dropdown_get_selected(r.field)].target;
        const remove = lv.lv_dropdown_get_selected(r.action) == 1;
        const text = std.mem.span(lv.lv_textarea_get_text(r.value));
        if (remove) {
            switch (target) {
                .date_taken => for ([_]Tag{ .date_time_original, .date_time_digitized, .date_time, .offset_time_original, .offset_time_digitized, .offset_time }) |t| {
                    ops.append(a, .{ .remove = t }) catch return false;
                },
                .tag => |t| ops.append(a, .{ .remove = t }) catch return false,
            }
        } else {
            if (std.mem.trim(u8, text, " ").len == 0) continue; // empty row: ignored
            row_of_op[@min(ops.items.len, row_of_op.len - 1)] = i;
            ops.append(a, .{ .set = .{ .target = target, .text = a.dupe(u8, text) catch return false } }) catch return false;
        }
    }
    if (isChecked(refs.batch_gps_cb)) ops.append(a, .remove_gps) catch return false;
    if (isChecked(batch_thumb_cb)) ops.append(a, .remove_thumbnail) catch return false;

    if (ops.items.len == 0) {
        showDialogError("Nothing to do: enter a value or tick an option.");
        return false;
    }
    if (edit.validateOps(gpa, ops.items)) |bad| {
        const row = row_of_op[@min(bad.index, row_of_op.len - 1)];
        var buf: [300]u8 = undefined;
        showDialogError(std.fmt.bufPrint(&buf, "Change {d}: {s}", .{ row + 1, edit.errorMessage(bad.err) }) catch "Invalid value.");
        return false;
    }
    batch_ops = ops.items;
    return true;
}

fn onBatchApply(_: ?*lv.lv_event_t) callconv(.c) void {
    if (!collectBatchOps()) return;
    startBatch();
}

fn startBatch() void {
    closeModal();
    const c = modal(dp(560));
    _ = title(c, "Updating photos");
    batch_progress_label = label(c, "");
    batch_progress_bar = lv.lv_bar_create(c);
    lv.lv_obj_set_width(batch_progress_bar, lv.lv_pct(100));
    lv.lv_bar_set_range(batch_progress_bar, 0, @intCast(names.len));
    batch_index = 0;
    batch_ok = 0;
    batch_failed = 0;
    batch_failures.clearRetainingCapacity();
    batch_running = true;
    // The current photo is reloaded afterwards
    closeDoc();
    renderDoc();
    batch_timer = lv.lv_timer_create(batchStep, 1, null);
}

/// Processes one file per timer tick so the window stays responsive.
fn batchStep(_: ?*lv.lv_timer_t) callconv(.c) void {
    if (batch_index < names.len) {
        const name = names[batch_index];
        lv.lv_label_set_text(batch_progress_label, zfmt("{d} / {d}: {s}", .{ batch_index + 1, names.len, name }));
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ folder.?, name }) catch "";
        if (edit.processFile(gpa, io, p, batch_ops)) |_| {
            batch_ok += 1;
        } else |err| {
            batch_failed += 1;
            if (batch_failed <= 20) batch_failures.print(gpa, "{s}: {s}\n", .{ name, edit.errorMessage(err) }) catch {};
        }
        batch_index += 1;
        lv.lv_bar_set_value(batch_progress_bar, @intCast(batch_index), false);
        return;
    }
    if (batch_timer) |t| lv.lv_timer_delete(t);
    batch_timer = null;
    batch_running = false;
    finishBatch();
}

fn finishBatch() void {
    closeModal();
    const c = modal(dp(560));
    _ = title(c, if (batch_failed == 0) "Done" else "Done, with errors");
    const summary = label(c, zfmt("Updated {d} of {d} files.", .{ batch_ok, names.len }));
    refs.batch_summary = summary;
    if (batch_failed > 0) {
        const l = label(c, zfmt("{d} failed:\n{s}{s}", .{ batch_failed, batch_failures.items, if (batch_failed > 20) "..." else "" }));
        lv.lv_obj_set_style_text_color(l, lv.lv_color_hex(color_danger), 0);
    }
    const row = box(c, lv.LV_FLEX_FLOW_ROW);
    lv.lv_obj_set_flex_align(row, lv.LV_FLEX_ALIGN_END, lv.LV_FLEX_ALIGN_CENTER, lv.LV_FLEX_ALIGN_CENTER);
    refs.batch_close_btn = button(row, "Close", onModalCancel, null);
    batchFree();
    if (selected) |i| selectFile(i); // reload; sets its own status first
    if (batch_failed == 0)
        setStatus(.ok, "Batch edit: updated {d} files", .{batch_ok})
    else
        setStatus(.err, "Batch edit: {d} updated, {d} failed", .{ batch_ok, batch_failed });
}
