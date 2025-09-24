const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error =
    std.mem.Allocator.Error ||
    std.fs.Dir.CopyFileError ||
    std.fs.Dir.DeleteFileError ||
    error{FileSystem};

pub fn dotdot(allocator: Allocator, count: usize) Allocator.Error![]const u8 {
    var str: [3]u8 = .{ '.', '.', undefined };
    str[str.len - 1] = std.fs.path.sep;
    const path = try allocator.alloc(u8, str.len * count);
    for (0..count) |i| {
        @memcpy(path[str.len * i ..][0..3], &str);
    }
    return path;
}

pub fn linkOut(
    allocator: Allocator,
    symlink: bool,
    subpath_in: []const u8,
    subpath_out: []const u8,
) Error!void {
    const cwd = std.fs.cwd();

    // Delete preexisting link/file
    cwd.deleteFile(subpath_out) catch |e| {
        if (e != Error.FileNotFound) return e;
    };

    if (symlink) {
        // Build varying length prefix of "../"
        const upper = try dotdot(
            allocator,
            std.mem.count(u8, subpath_out, &.{std.fs.path.sep}),
        );
        defer allocator.free(upper);

        // Append subpath_in
        const path = try std.mem.concat(allocator, u8, &.{ upper, subpath_in });
        defer allocator.free(path);

        // Create symlink
        try cwd.symLink(path, subpath_out, .{});
    } else {
        // Copy file
        try std.fs.Dir.copyFile(cwd, subpath_in, cwd, subpath_out, .{});
    }
}
