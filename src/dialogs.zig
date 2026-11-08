//! Native open dialogs through zenity. The dialog runs on a worker thread so
//! the window keeps redrawing; the UI polls for the result from a timer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Kind = enum { open_file, open_folder };

pub const Result = struct {
    kind: Kind,
    /// Selected path, or null if the dialog was cancelled.
    path: ?[:0]u8,
    /// Set if zenity could not be started.
    failed: bool = false,
};

var gpa: Allocator = undefined;
var io: Io = undefined;
var thread: ?std.Thread = null;
var done: std.atomic.Value(bool) = .init(false);
var result: Result = undefined;
var start_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
var start_dir: []const u8 = "";

pub fn init(allocator: Allocator, io_: Io) void {
    gpa = allocator;
    io = io_;
}

/// Waits for an open dialog to be closed by the user.
pub fn deinit() void {
    if (thread) |t| {
        t.join();
        thread = null;
        if (result.path) |p| gpa.free(p);
    }
}

pub fn busy() bool {
    return thread != null;
}

/// Opens a dialog unless one is already open. `dir` is where it starts.
pub fn start(kind: Kind, dir: ?[]const u8) void {
    if (thread != null) return;
    start_dir = if (dir) |d| std.fmt.bufPrint(&start_dir_buf, "{s}/", .{d}) catch "" else "";
    done.store(false, .release);
    result = .{ .kind = kind, .path = null };
    thread = std.Thread.spawn(.{}, worker, .{kind}) catch {
        result.failed = true;
        done.store(true, .release);
        return;
    };
}

/// Returns the result once the dialog is closed. Caller owns `path`.
pub fn poll() ?Result {
    if (!done.load(.acquire)) return null;
    if (thread) |t| t.join();
    thread = null;
    done.store(false, .release);
    return result;
}

fn worker(kind: Kind) void {
    var filename_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const filename = std.fmt.bufPrint(&filename_buf, "--filename={s}", .{start_dir}) catch "--filename=";
    const argv: []const []const u8 = switch (kind) {
        .open_file => &.{
            "zenity",
            "--file-selection",
            "--title=Open a photo",
            filename,
            "--file-filter=JPEG images | *.jpg *.jpeg *.JPG *.JPEG *.Jpg",
            "--file-filter=All files | *",
        },
        .open_folder => &.{
            "zenity",
            "--file-selection",
            "--directory",
            "--title=Open a folder of photos",
            filename,
        },
    };
    const run = std.process.run(gpa, io, .{ .argv = argv }) catch {
        result.failed = true;
        done.store(true, .release);
        return;
    };
    defer gpa.free(run.stdout);
    defer gpa.free(run.stderr);

    const ok = switch (run.term) {
        .exited => |code| code == 0,
        else => false,
    };
    const path = std.mem.trimEnd(u8, run.stdout, "\r\n");
    if (ok and path.len > 0) result.path = gpa.dupeSentinel(u8, path, 0) catch null;
    done.store(true, .release);
}
