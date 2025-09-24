const std = @import("std");
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

const Config = @import("config.zig");
const Diagnostic = @import("diagnostic.zig");
const html = @import("html.zig");

const c = @cImport({
    @cInclude("cmark.h");
});

const Error =
    std.fs.File.OpenError ||
    std.fs.Dir.MakeError ||
    std.fs.File.StatError ||
    std.mem.Allocator.Error ||
    std.Io.Reader.Error ||
    std.Io.Writer.Error ||
    error{
        CmarkParseFailed,
        CmarkRenderFailed,
    };

const ProcessDirArgs = struct {
    recursive: bool,
    in: std.fs.Dir,
    subpath_in: []const u8,
    out: std.fs.Dir,
    subpath_out: []const u8,
};

pub fn processDir(
    allocator: Allocator,
    io_buf: []u8,
    conf: Config,
    diag: ?*Diagnostic,
    index: ?*std.ArrayList(html.IndexEntry),
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
                if (std.mem.eql(u8, entry.name, conf.out_dir)) continue;
                if (args.recursive) {
                    try processDir(allocator, io_buf, conf, diag, null, .{
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
        if (!std.mem.endsWith(u8, entry.name, ".md")) {
            continue;
        }

        // Open and read the input file
        Diagnostic.set(diag, .{ .verb = .open, .object = entry.name });
        const file_in = try dir_in.openFile(entry.name, .{});
        defer file_in.close();

        Diagnostic.set(diag, .{ .verb = .stat, .object = entry.name });
        const stat_in = try file_in.stat();

        Diagnostic.set(diag, .{ .verb = .allocate, .object = entry.name });
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
        const html_src = std.mem.span(html_ptr);

        // Open output file
        Diagnostic.set(diag, .{ .verb = .allocate, .object = "filename" });
        const path_out = try std.mem.concat(allocator, u8, &.{
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
        Diagnostic.set(diag, .{ .verb = .allocate, .object = "page title" });
        title = try allocator.dupe(u8, title); // Don't free this
        c.cmark_iter_free(iter);

        // Output HTML
        Diagnostic.set(diag, .{ .verb = .write, .object = path_out });
        try html.writeDocument([]const u8, writer, .{
            .head = .{
                .title = title,
                .title_suffix = conf.site_name,
                .charset = conf.charset,
                .stylesheet = conf.stylesheet,
            },
            .body = html_src,
        }, Writer.writeAll);

        // Record index entry
        if (index) |list| {
            Diagnostic.set(diag, .{ .verb = .allocate, .object = "index" });
            try list.append(allocator, .{
                .path = path_out,
                .short = null,
                .title = title,
            });
        }
    }
}
