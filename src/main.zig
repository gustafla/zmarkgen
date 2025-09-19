const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
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
    charset: []const u8 = "utf-8",
    site_name: ?[]const u8 = null,

    pub fn load(
        allocator: Allocator,
        path: []const u8,
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

const Args = struct {
    recursive: bool = false,
    config_path: []const u8 = "zmarkgen.zon",

    pub fn parse() Args {
        var result: @This() = .{};

        var args = std.process.args();
        _ = args.skip();
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "-h")) {
                std.log.info(
                    \\Example: zmarkgen -r -c doc/zmarkgen.zon -- README.md doc/
                , .{});
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "-r")) {
                result.recursive = true;
            } else if (std.mem.eql(u8, arg, "-c")) {
                if (args.next()) |path| {
                    result.config_path = path;
                } else {
                    std.log.err("Option -c requires a file path", .{});
                    std.process.exit(1);
                }
            } else if (std.mem.eql(u8, arg, "--")) {
                break;
            } else {
                std.log.err("Unrecognized argument: {s}", .{arg});
                std.process.exit(1);
            }
        }

        return result;
    }
};

fn htmlHead(
    writer: *Writer,
    config: Config,
    title: []const u8,
) Writer.Error!void {
    try writer.writeAll("<head>");

    // Add charset
    try writer.print("<meta charset=\"{s}\">", .{config.charset});

    // Add title and optional site name
    try writer.print("<title>{s}", .{title});
    if (config.site_name) |site| {
        try writer.print(" - {s}", .{site});
    }
    try writer.writeAll("</title>");

    try writer.writeAll("</head>");
}

pub fn main() void {
    std.log.debug("Using cmark {s}", .{c.cmark_version_string()});
    var arena = std.heap.ArenaAllocator.init(std.heap.raw_c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = Args.parse();

    // Load config file
    std.log.info("Loading {s}", .{args.config_path});
    var zon_diagnostics: std.zon.parse.Diagnostics = .{};
    const config: Config = Config.load(
        allocator,
        args.config_path,
        &zon_diagnostics,
    ) catch |e| switch (e) {
        error.FileNotFound => def: {
            std.log.info(
                "File {s} not found, using defaults",
                .{args.config_path},
            );
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

    // Process sources

}

pub const std_options: std.Options = .{
    .log_level = if (builtin.mode == .Debug) .debug else .info,
};
