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
    verb: ?Verb,
    object: []const u8,

    const init: @This() = .{ .verb = null, .object = "" };

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

    pub fn format(self: *const @This(), w: *Writer) Writer.Error!void {
        if (self.verb) |verb| {
            try w.print("Failed to {s} {s}", .{
                @tagName(verb),
                self.object,
            });
        }
    }
};

fn processDir(
    allocator: Allocator,
    io_buf: []u8,
    config: Config,
    diag: ?*Diagnostic,
    args: ProcessDirArgs,
) Error!void {
    // Set up diagnostic writer
    var cur_verb: Diagnostic.Verb = .open;
    var cur_object: []const u8 = "";
    errdefer if (diag) |d| {
        if (d.verb == null) {
            d.* = .{
                .verb = cur_verb,
                .object = cur_object,
            };
        } // else: if diag was already set by previous call, don't overwrite
    };

    // Open input subpath for iteration
    cur_verb = .open;
    cur_object = args.subpath_in;
    var dir_in = try args.in.openDir(
        args.subpath_in,
        .{ .iterate = true },
    );
    defer dir_in.close();

    // Create output subdir
    cur_verb = .create;
    cur_object = args.subpath_out;
    args.out.makeDir(args.subpath_out) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    cur_verb = .open;
    var dir_out = try args.out.openDir(args.subpath_out, .{});
    defer dir_out.close();

    var it = dir_in.iterate();
    while (blk: {
        cur_verb = .read;
        cur_object = args.subpath_in;
        break :blk try it.next();
    }) |entry| {
        switch (entry.kind) {
            .directory => {
                // TODO: This is a buggy workaround for the situation when -r
                // is specified and the output directory happens to be a subset
                // of the input directory tree. Not a proper solution.
                if (mem.eql(u8, entry.name, config.out_dir)) continue;
                if (args.recursive) {
                    try processDir(allocator, io_buf, config, diag, .{
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
        cur_verb = .open;
        cur_object = entry.name;
        const file_in = try dir_in.openFile(entry.name, .{});
        defer file_in.close();

        cur_verb = .stat;
        const stat_in = try file_in.stat();

        cur_verb = .@"allocate buffer for";
        cur_object = entry.name;
        const md = try allocator.alloc(u8, stat_in.size);
        defer allocator.free(md);

        cur_verb = .read;
        var reader = file_in.reader(io_buf);
        try reader.interface.readSliceAll(md);

        // Parse markdown
        cur_verb = .parse;
        const document = c.cmark_parse_document(
            md.ptr,
            md.len,
            c.CMARK_OPT_DEFAULT,
        ) orelse return Error.CmarkParseFailed;
        defer c.cmark_node_free(document);

        // Render markdown
        cur_verb = .render;
        const html_ptr = c.cmark_render_html(
            document,
            c.CMARK_OPT_DEFAULT,
        ) orelse return Error.CmarkRenderFailed;
        defer std.c.free(html_ptr);
        const html = mem.span(html_ptr);

        // Open output file
        cur_verb = .@"allocate buffer for";
        cur_object = "a new filename";
        const path_out = try mem.concat(allocator, u8, &.{
            entry.name[0..(entry.name.len - ".md".len)],
            ".html",
        }); // Don't free path_out!

        cur_verb = .create;
        cur_object = path_out;
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
        c.cmark_iter_free(iter);

        // Output HTML
        cur_verb = .@"write to";
        try writer.writeAll("<!DOCTYPE html><html>");
        try writeHtmlHead(writer, config, title);
        try writer.writeAll("<body>");
        try writer.writeAll(html);
        try writer.writeAll("</body>");
        try writer.writeAll("</html>");

        try writer.flush();
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

    // Run with an IO buffer allocated on the stack
    var buf: [1024]u8 = undefined;
    var diag: Diagnostic = .init;
    processDir(allocator, &buf, config, &diag, .{
        .recursive = opt.recursive,
        .in = fs.cwd(),
        .subpath_in = opt.input_dir,
        .out = fs.cwd(),
        .subpath_out = config.out_dir,
    }) catch |e| {
        log.err("{f}: {s}", .{ diag, @errorName(e) });
        process.exit(1);
    };
}

pub const std_options: std.Options = .{
    .log_level = if (builtin.mode == .Debug) .debug else .info,
};
