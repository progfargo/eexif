# eexif

A desktop EXIF editor for JPEG photos, written in Zig with LVGL and SDL3.

Open a photo to see its EXIF data, edit any field with the pencil button and
save. Open a folder to step through its photos one by one, or change all of
them at once: set the date taken, add a copyright, remove GPS location, and so on.

![Main window](docs/main.png)

## Features

- Shows every EXIF field, grouped as Image, Photo, GPS, Interoperability and Thumbnail
- Edit, add and delete fields; values are checked before they are stored
  (dates, fractions like `1/250`, numbers, text in any language)
- Orientation is picked from a list, and the preview follows it
- **Batch edit folder**: apply several changes to every JPEG in a folder
  - set or remove any field, including "Date taken" (all three date fields at once)
  - remove GPS location, remove thumbnails, or remove all EXIF first
  - every value is validated before any file is touched
- Safe saving: each file is written to a temporary file and then renamed over
  the original, so an interrupted save never leaves a broken photo
- Image data is never re-encoded; only the EXIF segment changes
- Unsaved changes are never lost silently

![Batch edit](docs/batch.png)

EXIF reading and writing is done by [wexif](https://github.com/progfargo/wexif).

## Usage

```sh
eexif                 # then use Open photo / Open folder
eexif photo.jpg
eexif ~/Pictures/trip
```

| Key | Action |
|---|---|
| Ctrl+O | Open photo |
| Ctrl+S | Save |
| Ctrl+V | Paste into the text field |
| Enter | Apply the dialog |
| Esc | Close the dialog |

Value formats:

| Field | Example |
|---|---|
| Dates | `2026:11:08 18:30:00`, `2026-11-08T18:30:00+03:00` |
| Time zone (OffsetTime*) | `+03:00` |
| Fractions (ExposureTime, FNumber, ...) | `1/250`, `2.8` |
| Several values | `24/1, 70/1, 14/5, 14/5` |
| Raw bytes | `0x30323332` |

## Building

The only requirement is Zig 0.17.1. LVGL, SDL3, stb_image and wexif are
fetched and built by the Zig build system; nothing else needs to be installed.

```sh
zig build                          # debug build: zig-out/bin/eexif
zig build -Doptimize=ReleaseSmall  # about 5 MB
zig build run -- ~/Pictures
```

Windows build (from Linux or Windows):

```sh
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSmall   # zig-out/bin/eexif.exe
```

The result is a single `eexif.exe` that only uses DLLs that come with Windows
10 and later.

## Tests

```sh
zig build test
```

runs the unit tests of the editing logic (parsing values, batch operations,
saving).

The in-app test drives the real UI without opening a window and checks the
files it writes:

```sh
EEXIF_TEST=1 SDL_VIDEO_DRIVER=offscreen EEXIF_TEST_DIR=/tmp/eexif-test ./zig-out/bin/eexif
```

It prints `test: ok` at the end. Add `EEXIF_SHOT=<dir>` to save screenshots.

## Limitations

- JPEG only
- The MakerNote field is kept as is but cannot be edited
- XMP and IPTC metadata are left untouched
- CMYK JPEGs have no preview (their EXIF can still be edited)

## Platforms

- **Linux:** developed and tested on Linux (X11).
- **Windows:** the code is portable and builds for Windows (see above), but
  the Windows build has not been tested on Windows yet. Reports are welcome.
- **macOS:** not built or tested. Nothing in the code is Linux-specific
  (SDL3 provides the window and the native open dialogs, and shortcuts also
  work with Cmd), so `zig build` on a Mac should work, but this has not been
  tried. Building for macOS from another OS is not supported, as it needs
  Apple's SDK.

Built with [Claude Code](https://claude.com/claude-code). I defined the
features and requirements, chose the tools (Zig, LVGL, SDL3, wexif),
reviewed the results and tested the app; Claude wrote most of the code.

## License

MIT. Bundled fonts: Montserrat (SIL Open Font License, `assets/Montserrat-OFL.txt`)
and Font Awesome Free (`assets/FontAwesome-LICENSE.txt`).
