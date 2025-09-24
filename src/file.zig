const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error =
    std.mem.Allocator.Error ||
    std.fs.Dir.CopyFileError ||
    std.fs.Dir.DeleteFileError ||
    error{FileSystem};

pub const Source = union(enum) {
    symlink: struct { path_in: []const u8 },
    copy: struct { dir_in: std.fs.Dir },
};

pub fn linkOut(
    allocator: Allocator,
    source: Source,
    dir_out: std.fs.Dir,
    filename: []const u8,
) Error!void {
    dir_out.deleteFile(filename) catch |e| {
        if (e != Error.FileNotFound) return e;
    };
    switch (source) {
        .symlink => |ln| {
            const target_path = try std.fs.path.join(
                allocator,
                &.{ "..", ln.path_in, filename },
            );
            defer allocator.free(target_path);
            try dir_out.symLink(target_path, filename, .{});
        },
        .copy => |cp| {
            try cp.dir_in.copyFile(filename, dir_out, filename, .{});
        },
    }
}
