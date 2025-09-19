const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("cmark.h");
});

const ConfigLoadError =
    std.fs.File.StatError ||
    std.fs.File.OpenError ||
    std.mem.Allocator.Error ||
    std.Io.Reader.Error ||
    error{ParseZon};

const Config = struct {
    out_dir: []const u8 = "generated",

    pub const path = "zmarkgen.zon";

    pub fn load(
        allocator: Allocator,
        diagnostics: ?*std.zon.parse.Diagnostics,
    ) ConfigLoadError!Config {
        const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
        defer file.close();

        var rbuf: [1024]u8 = undefined;
        var reader = file.reader(&rbuf);

        const stat = try file.stat();
        const buf = try allocator.allocSentinel(u8, stat.size, 0);
        try reader.interface.readSliceAll(buf);

        return try std.zon.parse.fromSlice(
            @This(),
            allocator,
            buf,
            diagnostics,
            .{},
        );
    }
};

pub fn main() void {
    std.log.info("Using cmark {s}", .{c.cmark_version_string()});
    var arena = std.heap.ArenaAllocator.init(std.heap.raw_c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Load config file
    std.log.info("Loading {s}", .{Config.path});
    var zon_diagnostics: std.zon.parse.Diagnostics = .{};
    const config: Config = Config.load(
        allocator,
        &zon_diagnostics,
    ) catch |e| switch (e) {
        error.FileNotFound => def: {
            std.log.info("File {s} not found, using defaults", .{Config.path});
            break :def .{};
        },
        error.ParseZon => {
            std.log.err("{f}", .{zon_diagnostics});
            std.process.exit(1);
        },
        else => {
            std.log.err("Unhandled error: {any}", .{e});
            std.process.exit(1);
        },
    };
    _ = config;
}

pub const std_options: std.Options = .{
    .log_level = if (builtin.mode == .Debug) .debug else .warn,
};
