const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const zon = std.zon;
const Allocator = mem.Allocator;

out_dir: []const u8 = "generated",
charset: []const u8 = "utf-8",
symlink: bool = true,
stylesheet: ?[]const u8 = null,
site_name: ?[]const u8 = null,
snippet_max_len: u32 = 256,

pub const Error =
    fs.File.StatError ||
    fs.File.OpenError ||
    mem.Allocator.Error ||
    std.Io.Reader.Error ||
    error{ ParseZon, OutDirTooComplex };

pub fn load(
    allocator: Allocator,
    path: []const u8,
    diagnostics: ?*zon.parse.Diagnostics,
) Error!@This() {
    const file = try fs.cwd().openFile(path, .{});
    defer file.close();

    var rbuf: [1024]u8 = undefined;
    var reader = file.reader(&rbuf);

    const stat = try file.stat();
    const buf = try allocator.allocSentinel(u8, stat.size, 0);
    defer allocator.free(buf);
    try reader.interface.readSliceAll(buf);

    const conf = try zon.parse.fromSlice(
        @This(),
        allocator,
        buf,
        diagnostics,
        .{},
    );
    if (mem.containsAtLeastScalar(u8, conf.out_dir, 1, fs.path.sep)) {
        return Error.OutDirTooComplex;
    }
    return conf;
}
