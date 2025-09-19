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
        const file = try std.fs.cwd().openFile(path, .{});
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

const CliOptions = struct {
    recursive: bool = false,
    config_path: []const u8 = "zmarkgen.zon",
    input_dir: []const u8 = ".",

    pub fn parse() CliOptions {
        var result: @This() = .{};

        var args = std.process.args();
        _ = args.skip();
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "-h")) {
                std.log.info(
                    \\Example: zmarkgen -r -c doc/zmarkgen.zon doc
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
            } else {
                result.input_dir = arg;
                break;
            }
        }

        if (args.skip()) {
            std.log.err("Too many arguments, see usage with -h", .{});
            std.process.exit(1);
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

fn processDir(
    allocator: Allocator,
    opt: CliOptions,
    config: Config,
    in: std.fs.Dir,
    subpath_in: []const u8,
    out: std.fs.Dir,
    subpath_out: []const u8,
) void {
    var buf: [1024]u8 = undefined;

    // Open input subpath for iteration
    var dir_in = in.openDir(
        subpath_in,
        .{ .iterate = true },
    ) catch |e| {
        std.log.err("Cannot open {s}: {s}", .{ subpath_in, @errorName(e) });
        std.process.exit(1);
    };
    defer dir_in.close();

    // Create output subdir
    out.makeDir(subpath_out) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => {
            std.log.err("Cannot create directory: {s}", .{@errorName(e)});
            std.process.exit(1);
        },
    };
    var dir_out = out.openDir(subpath_out, .{}) catch |e| {
        std.log.err("Cannot open {s}: {s}", .{ subpath_out, @errorName(e) });
        std.process.exit(1);
    };
    defer dir_out.close();

    var it = dir_in.iterate();
    while (it.next() catch |e| {
        std.log.err("{s}", .{@errorName(e)});
        std.process.exit(1);
    }) |entry| {
        switch (entry.kind) {
            .directory => {
                if (opt.recursive) {
                    processDir(
                        allocator,
                        opt,
                        config,
                        dir_in,
                        entry.name,
                        dir_out,
                        entry.name,
                    );
                } else {
                    std.log.info(
                        "Skipping directory {s}, use -r to recurse",
                        .{entry.name},
                    );
                }
                continue;
            },
            .file => {},
            else => continue,
        }

        // Skip non-markdown files, TODO: copy or link them to dir_out
        if (!std.mem.endsWith(u8, entry.name, ".md")) {
            continue;
        }

        // Open and read the input file
        const file_in = dir_in.openFile(entry.name, .{}) catch |e| {
            std.log.err("Cannot open {s}: {s}", .{ entry.name, @errorName(e) });
            std.process.exit(1);
        };
        defer file_in.close();
        const stat_in = file_in.stat() catch |e| {
            std.log.err("Cannot stat {s}: {s}", .{ entry.name, @errorName(e) });
            std.process.exit(1);
        };
        const md = allocator.alloc(u8, stat_in.size) catch {
            std.log.err("Memory allocation failed", .{});
            std.process.exit(1);
        };
        defer allocator.free(md);
        var reader = file_in.reader(&buf);
        reader.interface.readSliceAll(md) catch |e| {
            std.log.err("Cannot read {s}: {s}", .{ entry.name, @errorName(e) });
            std.process.exit(1);
        };

        // Parse markdown
        const document = c.cmark_parse_document(
            md.ptr,
            md.len,
            c.CMARK_OPT_DEFAULT,
        ) orelse {
            std.log.err("Failed to parse {s}", .{entry.name});
            std.process.exit(1);
        };
        defer c.cmark_node_free(document);

        // Open output file
        const path_out = std.mem.concat(allocator, u8, &.{
            entry.name[0..(entry.name.len - ".md".len)],
            ".html",
        }) catch {
            std.log.err("Memory allocation failed", .{});
            std.process.exit(1);
        };
        const file_out = dir_out.createFile(
            path_out,
            .{ .truncate = true },
        ) catch |e| {
            std.log.err(
                "Cannot create {s}: {s}",
                .{ entry.name, @errorName(e) },
            );
            std.process.exit(1);
        };
        defer file_out.close();
        allocator.free(path_out);

        // Initialize writer, reusing buf is okay
        var file_writer = file_out.writer(&buf);
        const writer = &file_writer.interface;

        // Output HTML, TODO: fix error handling plz
        writer.writeAll("<!DOCTYPE html><html>") catch unreachable;
        htmlHead(writer, config, "asdf") catch unreachable;
        writer.writeAll("<body>") catch unreachable;
        const html_ptr = c.cmark_render_html(document, c.CMARK_OPT_DEFAULT);
        if (html_ptr == null) {
            std.log.err("cmark_render_html returned null", .{});
            std.process.exit(1);
        }
        defer std.c.free(html_ptr);
        const html = std.mem.span(html_ptr);
        writer.writeAll(html) catch unreachable;
        writer.writeAll("</body>") catch unreachable;
        writer.writeAll("</html>") catch unreachable;

        writer.flush() catch unreachable;
    }
}

pub fn main() void {
    std.log.debug("Using cmark {s}", .{c.cmark_version_string()});
    var arena = std.heap.ArenaAllocator.init(std.heap.raw_c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const opt = CliOptions.parse();

    // Load config file
    std.log.info("Loading {s}", .{opt.config_path});
    var zon_diagnostics: std.zon.parse.Diagnostics = .{};
    const config: Config = Config.load(
        allocator,
        opt.config_path,
        &zon_diagnostics,
    ) catch |e| switch (e) {
        error.FileNotFound => def: {
            std.log.info(
                "File {s} not found, using defaults",
                .{opt.config_path},
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

    // Run
    processDir(
        allocator,
        opt,
        config,
        std.fs.cwd(),
        opt.input_dir,
        std.fs.cwd(),
        config.out_dir,
    );
}

pub const std_options: std.Options = .{
    .log_level = if (builtin.mode == .Debug) .debug else .info,
};
