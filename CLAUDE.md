# eexif

Desktop EXIF editor: Zig 0.17.1 + LVGL 9.6 + SDL3 (allyourcodebase/SDL) + wexif.
Same platform layer and conventions as ~/project/repeto/repeto.

## Rules

- Everything in the repo is English (code, comments, UI text, README, commits).
- Never drive the real desktop (no xdotool, no opening windows to click around).
  Use the in-app test below; it runs offscreen.

## Build and test

- Build: `zig build`; unit tests: `zig build test` (src/edit.zig).
- In-app test (offscreen, checks written files, DebugAllocator reports leaks):
  `(ulimit -v 4000000; EEXIF_TEST=1 SDL_VIDEO_DRIVER=offscreen EEXIF_TEST_DIR=<tmp>/photos EEXIF_SHOT=<tmp>/shots timeout 150 nice ./zig-out/bin/eexif)`
  → must end with `test: ok`. Screenshots are BMP; convert to PNG to look at them.
  A relative EEXIF_TEST_DIR keeps paths short in screenshots.
- After UI changes, look at the screenshots, not only the test result.

## Layout

- `src/main.zig`: SDL3 window, LVGL display driver, mouse/keyboard input, shortcuts.
- `src/ui.zig`: screens and dialogs. `refs` and `fieldButton` expose widgets to the test.
- `src/edit.zig`: no UI. Value <-> text, documents (load/save/revert), atomic save,
  folder listing, batch operations. Unit tested.
- `src/dialogs.zig`: zenity open dialogs on a worker thread, polled by an LVGL timer.
- `src/preview.c`: JPEG preview with libjpeg (setjmp/longjmp error handling must stay
  in C), decoded at 1/2..1/8 scale, box-filtered and oriented by EXIF Orientation.
- `src/lv_helpers.c`: LVGL fields with bit fields (opaque in Zig): font fallback,
  draw buffer size.
- `src/app_test.zig`: in-app test; `test/photo.jpg` is its fixture.

## Notes

- `@cImport` is gone in Zig 0.17: C headers go through `b.addTranslateC`.
- LVGL 9.6 deprecates `lv_obj_add_flag(.., HIDDEN)` / `CLICKABLE` and NULL displays;
  use `lv_obj_set_hidden`, `lv_obj_set_clickable`, `lv_display_get_default()`.
  Deprecation warnings show up in the in-app test output; keep it clean.
- LVGL's image cache is off (`LV_CACHE_DEF_SIZE` 0): set the image source to null
  before destroying a preview draw buffer.
- A wide modal covers the preview; an "empty" preview in a screenshot with a dialog
  open is not a bug.
- wexif is pinned to a commit in build.zig.zon. To use a newer wexif:
  `zig fetch --save=wexif https://github.com/progfargo/wexif/archive/<commit>.tar.gz`
