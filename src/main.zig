//! Platform layer: SDL3 window, LVGL display driver, mouse and keyboard
//! input, and the in-app test mode. The screens are in src/ui.zig.
//!
//! Usage: eexif [photo.jpg | folder]

const std = @import("std");
const sdl = @import("sdl3");
const lv = @import("lvgl");
const ui = @import("ui");
const app_test = @import("app_test.zig");

/// Default window size at 1x scale
const base_w = 1280;
const base_h = 800;

pub var window: ?*sdl.SDL_Window = null;
var renderer: ?*sdl.SDL_Renderer = null;
var texture: ?*sdl.SDL_Texture = null;
/// Buffer LVGL draws into; same size as the window in pixels.
pub var frame: []u32 = &.{};
pub var frame_w: i32 = 0;
pub var frame_h: i32 = 0;
pub var display: ?*lv.lv_display_t = null;
var gpa: std.mem.Allocator = undefined;
/// Window coordinates -> pixels (> 1 on HiDPI)
var pixel_density: f32 = 1.0;
/// UI scale override (EEXIF_SCALE)
var scale_override: ?f32 = null;

// Mouse state, read by the pointer indev
pub var mouse_x: i32 = 0;
pub var mouse_y: i32 = 0;
pub var mouse_down = false;
pub var pointer: ?*lv.lv_indev_t = null;

// Keyboard queue, read by the keypad indev. Each item is a character
// (its UTF-8 bytes packed little-endian into a u32) or an LV_KEY_* code.
var key_queue: [64]u32 = undefined;
var key_count: usize = 0;
var key_release_pending = false;
pub var keypad: ?*lv.lv_indev_t = null;

// src/lv_helpers.c
extern fn eexif_is_textarea(obj: ?*const lv.lv_obj_t) bool;

fn fail(msg: []const u8) noreturn {
    std.debug.panic("{s}: {s}", .{ msg, sdl.SDL_GetError() });
}

/// Starts SDL text input when a text area gets focus, stops it otherwise.
fn onFocusChanged(g: ?*lv.lv_group_t) callconv(.c) void {
    if (eexif_is_textarea(lv.lv_group_get_focused(g))) {
        _ = sdl.SDL_StartTextInput(window);
    } else {
        _ = sdl.SDL_StopTextInput(window);
    }
}

fn tickCb() callconv(.c) u32 {
    return @truncate(sdl.SDL_GetTicks());
}

fn flushCb(disp: ?*lv.lv_display_t, area: [*c]const lv.lv_area_t, px: [*c]u8) callconv(.c) void {
    _ = area;
    _ = px;
    if (lv.lv_display_flush_is_last(disp)) present();
    lv.lv_display_flush_ready(disp);
}

/// Copies the last frame to the window.
fn present() void {
    _ = sdl.SDL_UpdateTexture(texture, null, frame.ptr, frame_w * 4);
    _ = sdl.SDL_RenderClear(renderer);
    _ = sdl.SDL_RenderTexture(renderer, texture, null, null);
    _ = sdl.SDL_RenderPresent(renderer);
}

fn pointerRead(_: ?*lv.lv_indev_t, data: [*c]lv.lv_indev_data_t) callconv(.c) void {
    data.*.point.x = mouse_x;
    data.*.point.y = mouse_y;
    data.*.state = if (mouse_down) lv.LV_INDEV_STATE_PRESSED else lv.LV_INDEV_STATE_RELEASED;
}

fn keypadRead(_: ?*lv.lv_indev_t, data: [*c]lv.lv_indev_data_t) callconv(.c) void {
    if (key_release_pending) {
        key_release_pending = false;
        data.*.state = lv.LV_INDEV_STATE_RELEASED;
        return;
    }
    if (key_count > 0) {
        data.*.key = key_queue[0];
        data.*.state = lv.LV_INDEV_STATE_PRESSED;
        std.mem.copyForwards(u32, key_queue[0 .. key_count - 1], key_queue[1..key_count]);
        key_count -= 1;
        key_release_pending = true;
    }
}

pub fn pushKey(key: u32) void {
    if (key_count < key_queue.len) {
        key_queue[key_count] = key;
        key_count += 1;
    }
}

/// Queues UTF-8 text one character at a time.
fn pushText(s: []const u8) void {
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const end = @min(i + n, s.len);
        var packed_key: u32 = 0;
        for (s[i..end], 0..) |byte, j| packed_key |= @as(u32, byte) << @intCast(j * 8);
        pushKey(packed_key);
        i = end;
    }
}

pub fn flushKeys() void {
    while (key_count > 0) {
        lv.lv_indev_read(keypad); // press
        lv.lv_indev_read(keypad); // release
    }
}

/// Types text into the focused widget in chunks so the queue never overflows.
pub fn typeText(s: []const u8) void {
    var i: usize = 0;
    while (i < s.len) {
        var end = @min(i + 32, s.len);
        while (end < s.len and (s[end] & 0xC0) == 0x80) end += 1; // keep UTF-8 characters whole
        pushText(s[i..end]);
        flushKeys();
        i = end;
    }
}

fn ctrlKey(key: sdl.SDL_Keycode) ?u32 {
    return switch (key) {
        sdl.SDLK_BACKSPACE => lv.LV_KEY_BACKSPACE,
        sdl.SDLK_DELETE => lv.LV_KEY_DEL,
        sdl.SDLK_RETURN, sdl.SDLK_KP_ENTER => lv.LV_KEY_ENTER,
        sdl.SDLK_LEFT => lv.LV_KEY_LEFT,
        sdl.SDLK_RIGHT => lv.LV_KEY_RIGHT,
        sdl.SDLK_UP => lv.LV_KEY_UP,
        sdl.SDLK_DOWN => lv.LV_KEY_DOWN,
        sdl.SDLK_HOME => lv.LV_KEY_HOME,
        sdl.SDLK_END => lv.LV_KEY_END,
        sdl.SDLK_TAB => lv.LV_KEY_NEXT,
        else => null,
    };
}

/// Sizes the draw buffer, texture and LVGL resolution to the window.
pub fn resizeDisplay(w: i32, h: i32) !void {
    if (w == frame_w and h == frame_h) return;
    const new_frame = try gpa.alloc(u32, @intCast(w * h));
    @memset(new_frame, 0);
    if (texture) |t| sdl.SDL_DestroyTexture(t);
    texture = sdl.SDL_CreateTexture(renderer, sdl.SDL_PIXELFORMAT_ARGB8888, sdl.SDL_TEXTUREACCESS_STREAMING, w, h) orelse fail("SDL_CreateTexture");
    const old = frame;
    frame = new_frame;
    frame_w = w;
    frame_h = h;
    if (display == null) {
        display = lv.lv_display_create(w, h);
        lv.lv_display_set_flush_cb(display, flushCb);
    } else {
        lv.lv_display_set_resolution(display, w, h);
    }
    lv.lv_display_set_buffers(display, frame.ptr, null, @intCast(frame.len * 4), lv.LV_DISPLAY_RENDER_MODE_DIRECT);
    if (old.len > 0) gpa.free(old);
}

fn syncWindowSize() !void {
    var w: c_int = 0;
    var h: c_int = 0;
    _ = sdl.SDL_GetWindowSizeInPixels(window, &w, &h);
    pixel_density = sdl.SDL_GetWindowPixelDensity(window);
    if (pixel_density <= 0) pixel_density = 1;
    try resizeDisplay(w, h);
}

/// UI scale: the display's DPI scale (pixel density x content scale).
pub fn uiScale() f32 {
    if (scale_override) |s| return s;
    const s = sdl.SDL_GetWindowDisplayScale(window);
    return if (s > 0) s else 1.0;
}

fn applyScale(s: f32) !void {
    // The theme's own sizes (LV_DPX) follow the display DPI.
    lv.lv_display_set_dpi(display, @intFromFloat(@round(130.0 * s)));
    try ui.setScale(s);
}

/// Scrolls the scrollable object under the mouse. Open dropdown lists live
/// on the top layer, so that is searched first.
pub fn scrollUnderMouse(dy: i32) void {
    var p: lv.lv_point_t = .{ .x = mouse_x, .y = mouse_y };
    for ([_]?*lv.lv_obj_t{ lv.lv_layer_top(), lv.lv_screen_active() }) |layer| {
        var obj = lv.lv_indev_search_obj(layer, &p);
        while (obj) |o| : (obj = lv.lv_obj_get_parent(o)) {
            if (lv.lv_obj_is_scrollable(o) and (lv.lv_obj_get_scroll_top(o) > 0 or lv.lv_obj_get_scroll_bottom(o) > 0)) {
                lv.lv_obj_scroll_by_bounded(o, 0, dy, false);
                return;
            }
        }
        // A modal on the top layer blocks scrolling of the screen below it.
        if (layer == lv.lv_layer_top() and lv.lv_obj_get_child_count(layer) > 0) return;
    }
}

fn pasteClipboard() void {
    const c = sdl.SDL_GetClipboardText() orelse return;
    defer sdl.SDL_free(c);
    // Fields are one line: paste only the first line
    const s = std.mem.span(c);
    typeText(s[0 .. std.mem.indexOfAny(u8, s, "\r\n") orelse s.len]);
}

/// Passes one SDL event to LVGL (used by the main loop and the test mode).
pub fn handleEvent(ev: *const sdl.SDL_Event) !void {
    switch (ev.type) {
        sdl.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => {
            try syncWindowSize();
            ui.onResize();
        },
        sdl.SDL_EVENT_WINDOW_EXPOSED, sdl.SDL_EVENT_WINDOW_RESTORED, sdl.SDL_EVENT_WINDOW_SHOWN, sdl.SDL_EVENT_RENDER_TARGETS_RESET => present(),
        sdl.SDL_EVENT_RENDER_DEVICE_RESET => {
            texture = sdl.SDL_CreateTexture(renderer, sdl.SDL_PIXELFORMAT_ARGB8888, sdl.SDL_TEXTUREACCESS_STREAMING, frame_w, frame_h) orelse fail("SDL_CreateTexture");
            present();
        },
        sdl.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED => {
            try syncWindowSize();
            try applyScale(uiScale());
        },
        // Mouse events are read immediately so fast clicks between two
        // LVGL timer runs are not lost.
        sdl.SDL_EVENT_MOUSE_MOTION => {
            mouse_x = @intFromFloat(ev.motion.x * pixel_density);
            mouse_y = @intFromFloat(ev.motion.y * pixel_density);
            lv.lv_indev_read(pointer);
        },
        sdl.SDL_EVENT_MOUSE_BUTTON_DOWN, sdl.SDL_EVENT_MOUSE_BUTTON_UP => {
            if (ev.button.button != sdl.SDL_BUTTON_LEFT) return;
            mouse_x = @intFromFloat(ev.button.x * pixel_density);
            mouse_y = @intFromFloat(ev.button.y * pixel_density);
            mouse_down = ev.type == sdl.SDL_EVENT_MOUSE_BUTTON_DOWN;
            lv.lv_indev_read(pointer);
        },
        sdl.SDL_EVENT_MOUSE_WHEEL => scrollUnderMouse(@intFromFloat(ev.wheel.y * 40 * uiScale())),
        sdl.SDL_EVENT_TEXT_INPUT => {
            pushText(std.mem.span(ev.text.text));
            flushKeys();
        },
        sdl.SDL_EVENT_KEY_DOWN => {
            // Ctrl on Windows and Linux, Cmd on macOS
            if ((ev.key.mod & (sdl.SDL_KMOD_CTRL | sdl.SDL_KMOD_GUI)) != 0) {
                switch (ev.key.key) {
                    sdl.SDLK_S => ui.saveShortcut(),
                    sdl.SDLK_O => ui.openFileShortcut(),
                    sdl.SDLK_V => pasteClipboard(),
                    else => {},
                }
                return;
            }
            if (ev.key.key == sdl.SDLK_ESCAPE) {
                _ = ui.back();
                return;
            }
            if (ctrlKey(ev.key.key)) |k| {
                pushKey(k);
                flushKeys();
            }
        },
        else => {},
    }
}

pub fn main(init: std.process.Init) !void {
    // All Zig-side memory goes through this allocator; leaks are reported on exit.
    var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer if (debug_alloc.deinit() == .leak) std.debug.print("WARNING: memory leak found (see the report above)\n", .{});
    gpa = debug_alloc.allocator();
    defer if (frame.len > 0) gpa.free(frame);

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) fail("SDL_Init");
    defer sdl.SDL_Quit();

    if (sdl.SDL_getenv("EEXIF_SCALE")) |v| scale_override = std.fmt.parseFloat(f32, std.mem.span(v)) catch null;

    window = sdl.SDL_CreateWindow("eexif", base_w, base_h, sdl.SDL_WINDOW_RESIZABLE | sdl.SDL_WINDOW_HIGH_PIXEL_DENSITY) orelse fail("SDL_CreateWindow");
    // Grow the window by the scale the pixel density does not cover
    // (e.g. 1.5x desktop scale on X11).
    {
        const density = @max(sdl.SDL_GetWindowPixelDensity(window), 1.0);
        const extra = uiScale() / density;
        if (extra > 1.01) _ = sdl.SDL_SetWindowSize(window, @intFromFloat(base_w * extra), @intFromFloat(base_h * extra));
    }
    _ = sdl.SDL_SetWindowMinimumSize(window, 800, 500);
    renderer = sdl.SDL_CreateRenderer(window, null) orelse fail("SDL_CreateRenderer");

    lv.lv_init();
    defer lv.lv_deinit();
    lv.lv_tick_set_cb(tickCb);
    try syncWindowSize();
    const scale = uiScale();
    lv.lv_display_set_dpi(display, @intFromFloat(@round(130.0 * scale)));

    pointer = lv.lv_indev_create();
    lv.lv_indev_set_type(pointer, lv.LV_INDEV_TYPE_POINTER);
    lv.lv_indev_set_read_cb(pointer, pointerRead);
    lv.lv_indev_set_mode(pointer, lv.LV_INDEV_MODE_EVENT);

    const group = lv.lv_group_create();
    lv.lv_group_set_default(group);
    keypad = lv.lv_indev_create();
    lv.lv_indev_set_type(keypad, lv.LV_INDEV_TYPE_KEYPAD);
    lv.lv_indev_set_read_cb(keypad, keypadRead);
    lv.lv_indev_set_mode(keypad, lv.LV_INDEV_MODE_EVENT);
    lv.lv_indev_set_group(keypad, group);
    lv.lv_group_set_focus_cb(group, onFocusChanged);

    try ui.init(gpa, init.io, window, scale);
    defer ui.deinit();

    if (sdl.SDL_getenv("EEXIF_TEST") != null) return app_test.run(gpa, init.io);

    if (args.len > 1) ui.openPath(args[1]);

    while (!ui.shouldQuit()) {
        var ev: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&ev)) {
            if (ev.type == sdl.SDL_EVENT_QUIT) ui.requestQuit();
            try handleEvent(&ev);
        }
        const wait_ms = lv.lv_timer_handler();
        sdl.SDL_Delay(@min(wait_ms, 10));
    }
}
