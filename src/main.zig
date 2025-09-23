const std = @import("std");
const fs = std.fs;
const log = std.log;
const mem = std.mem;
const process = std.process;
const zon = std.zon;
const Allocator = mem.Allocator;
const Writer = std.Io.Writer;
const builtin = @import("builtin");

const options = @import("options");

const c = @cImport({
    @cInclude("cmark.h");
});

const CliOptions = struct {
    recursive: bool = false,
    config_path: []const u8 = "zmarkgen.zon",
    input_dir: []const u8 = ".",

    pub fn parse() CliOptions {
        var result: @This() = .{};

        var args = process.args();
        _ = args.skip();
        while (args.next()) |arg| {
            if (mem.eql(u8, arg, "-h")) {
                log.info(
                    \\Example: {s} -c my_blog.zon
                , .{options.name});
                process.exit(0);
            } else if (mem.eql(u8, arg, "-v")) {
                log.info("{s} v{s}", .{ options.name, options.version });
                process.exit(0);
            } else if (mem.eql(u8, arg, "-r")) {
                result.recursive = true;
            } else if (mem.eql(u8, arg, "-c")) {
                if (args.next()) |path| {
                    result.config_path = path;
                } else {
                    log.err("Option -c requires a file path", .{});
                    process.exit(1);
                }
            } else {
                result.input_dir = arg;
                break;
            }
        }

        if (args.skip()) {
            log.err("Too many arguments, see usage with -h", .{});
            process.exit(1);
        }

        return result;
    }
};

const ConfigLoadError =
    fs.File.StatError ||
    fs.File.OpenError ||
    mem.Allocator.Error ||
    std.Io.Reader.Error ||
    error{ ParseZon, OutDirTooComplex };

const Config = struct {
    out_dir: []const u8 = "generated",
    charset: []const u8 = "utf-8",
    symlink: bool = true,
    stylesheet: ?[]const u8 = null,
    site_name: ?[]const u8 = null,

    pub fn load(
        allocator: Allocator,
        path: []const u8,
        diagnostics: ?*zon.parse.Diagnostics,
    ) ConfigLoadError!Config {
        const file = try fs.cwd().openFile(path, .{});
        defer file.close();

        var rbuf: [1024]u8 = undefined;
        var reader = file.reader(&rbuf);

        const stat = try file.stat();
        const buf = try allocator.allocSentinel(u8, stat.size, 0);
        try reader.interface.readSliceAll(buf);

        const config = try zon.parse.fromSlice(
            @This(),
            allocator,
            buf,
            diagnostics,
            .{},
        );
        if (mem.containsAtLeastScalar(u8, config.out_dir, 1, fs.path.sep)) {
            return ConfigLoadError.OutDirTooComplex;
        }
        return config;
    }
};

fn writeHtmlHead(
    writer: *Writer,
    config: Config,
    title: []const u8,
) Writer.Error!void {
    try writer.writeAll("<head>\n");

    // Add charset
    try writer.print("<meta charset=\"{s}\">\n", .{config.charset});

    // Add stylesheet link
    if (config.stylesheet) |name| {
        try writer.print("<link rel=\"stylesheet\" href=\"{s}\">\n", .{name});
    }

    // Add title and optional site name
    try writer.print("<title>{s}", .{title});
    if (config.site_name) |site| {
        try writer.print(" - {s}", .{site});
    }
    try writer.writeAll("</title>\n");

    try writer.writeAll("</head>\n");
}

const IndexEntry = struct {
    path: []const u8,
    title: []const u8,
    short: ?[]const u8,
};

fn writeIndex(
    writer: *Writer,
    index: []const IndexEntry,
    title: []const u8,
) Writer.Error!void {
    try writer.print("<h1>{s}</h1>\n", .{title});
    for (index) |entry| {
        try writer.writeAll("<div class=\"indexEntry\">");
        try writer.print(
            "<a href=\"{s}\"><h2>{s}</h2></a>\n",
            .{ entry.path, entry.title },
        );
        if (entry.short) |short| {
            try writer.print("<p>{s}</p>\n", .{short});
        }
        try writer.writeAll("</div>");
    }
}

const Error =
    fs.File.OpenError ||
    fs.Dir.MakeError ||
    fs.File.StatError ||
    mem.Allocator.Error ||
    std.Io.Reader.Error ||
    std.Io.Writer.Error ||
    error{
        CmarkParseFailed,
        CmarkRenderFailed,
    };

const ProcessDirArgs = struct {
    recursive: bool,
    in: fs.Dir,
    subpath_in: []const u8,
    out: fs.Dir,
    subpath_out: []const u8,
};

const Diagnostic = struct {
    verb: Verb,
    object: []const u8,

    const Verb = enum {
        open,
        create,
        stat,
        read,
        @"write to",
        parse,
        render,
        @"allocate buffer for",
    };

    pub fn format(self: @This(), w: *Writer) Writer.Error!void {
        try w.print("Failed to {[verb]t} {[object]s}", self);
    }

    pub fn set(self: ?*@This(), val: Diagnostic) void {
        if (self) |diag| {
            diag.* = val;
        }
    }
};

fn processDir(
    allocator: Allocator,
    io_buf: []u8,
    config: Config,
    diag: ?*Diagnostic,
    index: ?*std.ArrayList(IndexEntry),
    args: ProcessDirArgs,
) Error!void {
    // Open input subpath for iteration
    Diagnostic.set(diag, .{ .verb = .open, .object = args.subpath_in });
    var dir_in = try args.in.openDir(
        args.subpath_in,
        .{ .iterate = true },
    );
    defer dir_in.close();

    // Create output subdir
    Diagnostic.set(diag, .{ .verb = .create, .object = args.subpath_out });
    args.out.makeDir(args.subpath_out) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    Diagnostic.set(diag, .{ .verb = .open, .object = args.subpath_out });
    var dir_out = try args.out.openDir(args.subpath_out, .{});
    defer dir_out.close();

    var it = dir_in.iterate();
    while (blk: {
        Diagnostic.set(diag, .{ .verb = .read, .object = args.subpath_in });
        break :blk try it.next();
    }) |entry| {
        switch (entry.kind) {
            .directory => {
                // TODO: This is a buggy workaround for the situation when -r
                // is specified and the output directory happens to be a subset
                // of the input directory tree. Not a proper solution.
                if (mem.eql(u8, entry.name, config.out_dir)) continue;
                if (args.recursive) {
                    try processDir(allocator, io_buf, config, diag, null, .{
                        .recursive = args.recursive,
                        .in = dir_in,
                        .subpath_in = entry.name,
                        .out = dir_out,
                        .subpath_out = entry.name,
                    });
                }
                continue;
            },
            .file => {},
            else => continue,
        }

        // Skip non-markdown files, TODO: copy or link them to dir_out
        if (!mem.endsWith(u8, entry.name, ".md")) {
            continue;
        }

        // Open and read the input file
        Diagnostic.set(diag, .{ .verb = .open, .object = entry.name });
        const file_in = try dir_in.openFile(entry.name, .{});
        defer file_in.close();

        Diagnostic.set(diag, .{ .verb = .stat, .object = entry.name });
        const stat_in = try file_in.stat();

        Diagnostic.set(diag, .{
            .verb = .@"allocate buffer for",
            .object = entry.name,
        });
        const md = try allocator.alloc(u8, stat_in.size);
        defer allocator.free(md);

        Diagnostic.set(diag, .{ .verb = .read, .object = entry.name });
        var reader = file_in.reader(io_buf);
        try reader.interface.readSliceAll(md);

        // Parse markdown
        Diagnostic.set(diag, .{ .verb = .parse, .object = entry.name });
        const document = c.cmark_parse_document(
            md.ptr,
            md.len,
            c.CMARK_OPT_DEFAULT,
        ) orelse return Error.CmarkParseFailed;
        defer c.cmark_node_free(document);

        // Render markdown
        Diagnostic.set(diag, .{ .verb = .render, .object = entry.name });
        const html_ptr = c.cmark_render_html(
            document,
            c.CMARK_OPT_DEFAULT,
        ) orelse return Error.CmarkRenderFailed;
        defer std.c.free(html_ptr);
        const html = mem.span(html_ptr);

        // Open output file
        Diagnostic.set(diag, .{
            .verb = .@"allocate buffer for",
            .object = "a new filename",
        });
        const path_out = try mem.concat(allocator, u8, &.{
            entry.name[0..(entry.name.len - ".md".len)],
            ".html",
        }); // Don't free path_out!

        Diagnostic.set(diag, .{ .verb = .create, .object = path_out });
        const file_out = try dir_out.createFile(
            path_out,
            .{ .truncate = true },
        );
        defer file_out.close();

        // Initialize writer, reusing buf is okay
        var file_writer = file_out.writer(io_buf);
        const writer = &file_writer.interface;

        // Get title from the first heading in document
        var title: []const u8 = entry.name;
        const iter = c.cmark_iter_new(document);
        while (c.cmark_iter_next(iter) != c.CMARK_EVENT_DONE) {
            var node = c.cmark_iter_get_node(iter);
            const node_type = c.cmark_node_get_type(node);
            if (node_type == c.CMARK_NODE_NONE) break;
            if (node_type == c.CMARK_NODE_HEADING) {
                node = c.cmark_node_first_child(node) orelse continue;
                const ptr = c.cmark_node_get_literal(node) orelse continue;
                title = std.mem.span(ptr);
                break;
            }
        }
        Diagnostic.set(diag, .{
            .verb = .@"allocate buffer for",
            .object = "page title",
        });
        title = try allocator.dupe(u8, title); // Don't free this
        c.cmark_iter_free(iter);

        // Output HTML
        Diagnostic.set(diag, .{ .verb = .@"write to", .object = path_out });
        try writer.writeAll("<!DOCTYPE html>\n<html>\n");
        try writeHtmlHead(writer, config, title);
        try writer.writeAll("<body>\n");
        try writer.writeAll(html);
        try writer.writeAll("</body>\n");
        try writer.writeAll("</html>\n");

        try writer.flush();

        // Record index entry
        if (index) |list| {
            Diagnostic.set(diag, .{
                .verb = .@"allocate buffer for",
                .object = "index entry",
            });
            try list.append(allocator, .{
                .path = path_out,
                .short = null,
                .title = title,
            });
        }
    }
}

const LinkFileError =
    mem.Allocator.Error ||
    fs.Dir.CopyFileError ||
    error{FileSystem};

pub fn linkFileOut(
    allocator: Allocator,
    symlink: bool,
    path_in: []const u8,
    dir_in: fs.Dir,
    dir_out: fs.Dir,
    filename: []const u8,
) LinkFileError!void {
    dir_out.deleteFile(filename) catch |e| switch (e) {
        fs.Dir.DeleteFileError.FileNotFound => {},
        else => return e,
    };
    if (symlink) {
        const target_path = try std.fs.path.join(
            allocator,
            &.{ "..", path_in, filename },
        );
        try dir_out.symLink(target_path, filename, .{});
    } else {
        try dir_in.copyFile(filename, dir_out, filename, .{});
    }
}

pub fn main() void {
    log.debug("Using cmark {s}", .{c.cmark_version_string()});
    var arena = std.heap.ArenaAllocator.init(std.heap.raw_c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const opt = CliOptions.parse();

    // Load config file
    log.info("Loading {s}", .{opt.config_path});
    var zon_diagnostics: zon.parse.Diagnostics = .{};
    const config: Config = Config.load(
        allocator,
        opt.config_path,
        &zon_diagnostics,
    ) catch |e| switch (e) {
        ConfigLoadError.FileNotFound => def: {
            log.info(
                "File {s} not found, using defaults",
                .{opt.config_path},
            );
            break :def .{};
        },
        ConfigLoadError.ParseZon => {
            log.err("{f}", .{zon_diagnostics});
            process.exit(1);
        },
        // TODO: This error can be removed if the input-output subtree problem
        // when using -r is solved properly. See other TODO comments.
        ConfigLoadError.OutDirTooComplex => {
            log.err(
                \\Config field out_dir must be a relative path,
                \\and may not specify any subdirectories
                \\
            , .{});
            process.exit(1);
        },
        else => {
            log.err("Unhandled error: {any}", .{e});
            process.exit(1);
        },
    };

    // Run cmark conversions with an IO buffer allocated on the stack
    var buf: [1024]u8 = undefined;
    var diag: Diagnostic = undefined;
    var index: std.ArrayList(IndexEntry) = .empty;
    processDir(allocator, &buf, config, &diag, &index, .{
        .recursive = opt.recursive,
        .in = fs.cwd(),
        .subpath_in = opt.input_dir,
        .out = fs.cwd(),
        .subpath_out = config.out_dir,
    }) catch |e| {
        log.err("{f}: {t}", .{ diag, e });
        process.exit(1);
    };

    // Output stylesheet etc.
    diag.verb = .open;
    diag.object = config.out_dir;
    var dir_out = fs.cwd().openDir(config.out_dir, .{}) catch |e| {
        log.err("{f}: {t}", .{ diag, e });
        process.exit(1);
    };
    defer dir_out.close();
    diag.object = opt.input_dir;
    var dir_in = fs.cwd().openDir(opt.input_dir, .{}) catch |e| {
        log.err("{f}: {t}", .{ diag, e });
        process.exit(1);
    };
    defer dir_in.close();

    if (config.stylesheet) |stylesheet| {
        diag.verb = .create;
        diag.object = stylesheet;
        linkFileOut(
            allocator,
            config.symlink,
            opt.input_dir,
            dir_in,
            dir_out,
            stylesheet,
        ) catch |e| {
            log.err("{f}: {t}", .{ diag, e });
            process.exit(1);
        };
    }

    // Output index
    diag.verb = .create;
    diag.object = "index.html";
    const index_out = dir_out.createFile(diag.object, .{ .truncate = true }) catch |e| {
        log.err("{f}: {t}", .{ diag, e });
        process.exit(1);
    };
    defer index_out.close();
    var index_writer = index_out.writer(&buf);
    const writer = &index_writer.interface;

    // TODO: Deduplicate this code
    diag.verb = .@"write to";
    _ = blk: {
        writer.writeAll("<!DOCTYPE html>\n<html>\n") catch |e| break :blk e;
        writeHtmlHead(writer, config, "Index") catch |e| break :blk e;
        writer.writeAll("<body>\n") catch |e| break :blk e;
        writeIndex(writer, index.items, config.site_name orelse "Index") catch |e| break :blk e;
        writer.writeAll("</body>\n") catch |e| break :blk e;
        writer.writeAll("</html>\n") catch |e| break :blk e;
        writer.flush() catch |e| break :blk e;
    } catch |e| {
        log.err("{f}: {t}", .{ diag, e });
        process.exit(1);
    };
}

pub const std_options: std.Options = .{
    .log_level = if (builtin.mode == .Debug) .debug else .info,
};

// #### Tests ####

test "html head has head tags" {
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    try writeHtmlHead(&writer.writer, .{}, "");
    const string = try writer.toOwnedSlice();
    defer std.testing.allocator.free(string);
    try std.testing.expect(std.mem.containsAtLeast(u8, string, 1, "<head>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string, 1, "</head>"));
}

test "html head has full title with site name" {
    const site = "Zig Adventures";
    const page = "Day 1";

    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    try writeHtmlHead(&writer.writer, .{ .site_name = site }, page);
    const string = try writer.toOwnedSlice();
    defer std.testing.allocator.free(string);
    try std.testing.expect(std.mem.containsAtLeast(u8, string, 1, "<title>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string, 1, site));
    try std.testing.expect(std.mem.containsAtLeast(u8, string, 1, page));
    try std.testing.expect(std.mem.containsAtLeast(u8, string, 1, "</title>"));
}
