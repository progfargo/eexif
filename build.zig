const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // SDL3 (allyourcodebase/SDL package)
    const sdl_dep = b.dependency("sdl", .{ .target = target, .optimize = optimize });

    // EXIF reading and writing
    const wexif_module = b.dependency("wexif", .{ .target = target, .optimize = optimize }).module("wexif");

    // LVGL sources
    const lvgl_dep = b.dependency("lvgl", .{});
    const c_flags: []const []const u8 = &.{ "-std=gnu11", "-DLV_CONF_INCLUDE_SIMPLE", "-Wno-gcc-install-dir-libstdcxx" };

    const lvgl_lib = b.addLibrary(.{
        .name = "lvgl",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    lvgl_lib.root_module.addIncludePath(b.path("lvconf"));
    lvgl_lib.root_module.addIncludePath(lvgl_dep.path(""));
    lvgl_lib.root_module.addCSourceFiles(.{
        .root = lvgl_dep.path(""),
        .files = findLvglSources(b, b.pathJoin(&.{
            lvgl_dep.builder.root.root_dir.path orelse ".",
            lvgl_dep.builder.root.sub_path,
            "src",
        })),
        .flags = c_flags,
    });

    // C helpers: LVGL fields Zig cannot reach (bit fields) and JPEG preview
    // decoding with libjpeg (needs setjmp/longjmp for error handling).
    lvgl_lib.root_module.addCSourceFiles(.{
        .files = &.{ "src/lv_helpers.c", "src/preview.c" },
        .flags = c_flags,
    });
    lvgl_lib.root_module.linkSystemLibrary("jpeg", .{});

    // lvgl.h -> Zig
    const lvgl_c = b.addTranslateC(.{
        .root_source_file = lvgl_dep.path("lvgl.h"),
        .target = target,
        .optimize = optimize,
    });
    lvgl_c.addIncludePath(b.path("lvconf"));
    lvgl_c.addIncludePath(lvgl_dep.path(""));
    lvgl_c.defineCMacro("LV_CONF_INCLUDE_SIMPLE", null);
    const lvgl_module = lvgl_c.createModule();
    const sdl_module = sdl_dep.module("sdl3");

    // EXIF editing logic (no UI; unit tested)
    const edit_module = b.createModule(.{
        .root_source_file = b.path("src/edit.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "wexif", .module = wexif_module }},
    });

    const ui_module = b.createModule(.{
        .root_source_file = b.path("src/ui.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lvgl", .module = lvgl_module },
            .{ .name = "sdl3", .module = sdl_module },
            .{ .name = "wexif", .module = wexif_module },
            .{ .name = "edit", .module = edit_module },
        },
    });
    ui_module.addAnonymousImport("font_regular", .{ .root_source_file = b.path("assets/Montserrat-Regular.ttf") });
    ui_module.addAnonymousImport("font_semibold", .{ .root_source_file = b.path("assets/Montserrat-SemiBold.ttf") });
    // Icons: LVGL's LV_SYMBOL_* codes are Font Awesome code points
    ui_module.addAnonymousImport("font_icons", .{ .root_source_file = b.path("assets/FontAwesome-Solid-900.ttf") });

    const main_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "sdl3", .module = sdl_module },
            .{ .name = "lvgl", .module = lvgl_module },
            .{ .name = "wexif", .module = wexif_module },
            .{ .name = "edit", .module = edit_module },
            .{ .name = "ui", .module = ui_module },
        },
    });
    main_module.linkLibrary(lvgl_lib);
    main_module.linkLibrary(sdl_dep.artifact("SDL3"));

    const exe = b.addExecutable(.{ .name = "eexif", .root_module = main_module });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run the app").dependOn(&run_cmd.step);

    const edit_tests = b.addTest(.{ .root_module = edit_module });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(edit_tests).step);
}

/// Finds all .c files under LVGL's src/ directory.
fn findLvglSources(b: *std.Build, src_dir_path: []const u8) []const []const u8 {
    var dir = std.Io.Dir.cwd().openDir(b.graph.io, src_dir_path, .{ .iterate = true }) catch
        @panic("cannot open the LVGL src directory");
    defer dir.close(b.graph.io);

    var walker = dir.walk(b.graph.arena) catch @panic("OOM");
    defer walker.deinit();

    var list: std.ArrayList([]const u8) = .empty;
    while (walker.next(b.graph.io) catch @panic("cannot scan LVGL src")) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.path, ".c")) {
            list.append(b.graph.arena, b.fmt("src/{s}", .{entry.path})) catch @panic("OOM");
        }
    }
    return list.items;
}
