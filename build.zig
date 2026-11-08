const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // EXIF reading and writing
    const wexif_module = b.dependency("wexif", .{ .target = target, .optimize = optimize }).module("wexif");

    // EXIF editing logic (no UI; unit tested)
    const edit_module = b.createModule(.{
        .root_source_file = b.path("src/edit.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "wexif", .module = wexif_module }},
    });

    const edit_tests = b.addTest(.{ .root_module = edit_module });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(edit_tests).step);
}
