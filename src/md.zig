const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

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

/// Derives an ".html" path from a ".md" path.
fn getHtmlPath(
    allocator: Allocator,
    md_path: []const u8,
) Allocator.Error![]const u8 {
    const html_extension = ".html";
    const base_name = std.fs.path.stem(md_path);
    return std.mem.concat(allocator, u8, &.{ base_name, html_extension });
}

/// Extracts the title from the first heading node in the document.
/// Falls back to the provided default_title if no H1 is found.
/// The returned slice is allocated and must be freed by the caller.
fn extractTitle(
    allocator: Allocator,
    document: *c.cmark_node,
    default_title: []const u8,
) Allocator.Error![]const u8 {
    const iter = c.cmark_iter_new(document);
    defer c.cmark_iter_free(iter);

    while (c.cmark_iter_next(iter) != c.CMARK_EVENT_DONE) {
        var node = c.cmark_iter_get_node(iter);
        if (c.cmark_node_get_type(node) == c.CMARK_NODE_HEADING) {
            // We found the first heading, extract its text content.
            node = c.cmark_node_first_child(node) orelse continue;
            const ptr = c.cmark_node_get_literal(node) orelse continue;
            return allocator.dupe(u8, std.mem.span(ptr));
        }
    }

    // No heading found, use the default title.
    return allocator.dupe(u8, default_title);
}

/// Processes a single markdown file: reads, renders, and writes it as HTML.
fn processFile(
    allocator: Allocator,
    conf: Config,
    diag: ?*Diagnostic,
    index: ?*std.ArrayList(html.IndexEntry),
    dir_in: std.fs.Dir,
    dir_out: std.fs.Dir,
    entry_name: []const u8,
) Error!void {
    // Allocate a small IO buffer on the stack.
    var io_buf: [1024]u8 = undefined;

    // Open the input markdown file.
    Diagnostic.set(diag, .{ .verb = .open, .object = entry_name });
    const file_in = try dir_in.openFile(entry_name, .{});
    defer file_in.close();
    var file_in_reader = file_in.reader(&io_buf);
    const reader = &file_in_reader.interface;

    // Stat the input file to allocate the right amount of memory.
    Diagnostic.set(diag, .{ .verb = .stat, .object = entry_name });
    const stat_in = try file_in.stat();

    // Read the input markdown file.
    Diagnostic.set(diag, .{ .verb = .read, .object = entry_name });
    const md_content = try reader.readAlloc(allocator, stat_in.size);
    defer allocator.free(md_content);

    // Parse markdown content into a cmark document.
    Diagnostic.set(diag, .{ .verb = .parse, .object = entry_name });
    const document = c.cmark_parse_document(
        md_content.ptr,
        md_content.len,
        c.CMARK_OPT_DEFAULT,
    ) orelse return error.CmarkParseFailed;
    defer c.cmark_node_free(document);

    // Render the document to an HTML string.
    Diagnostic.set(diag, .{ .verb = .render, .object = entry_name });
    const html_ptr = c.cmark_render_html(
        document,
        c.CMARK_OPT_DEFAULT,
    ) orelse return error.CmarkRenderFailed;
    defer std.c.free(html_ptr);
    const html_body = std.mem.span(html_ptr);

    // Extract title and generate the output path.
    // These are allocated and must be freed if not added to the index.
    Diagnostic.set(diag, .{ .verb = .allocate, .object = "page title" });
    const title = try extractTitle(allocator, document, entry_name);
    errdefer allocator.free(title);

    Diagnostic.set(diag, .{ .verb = .allocate, .object = "filename" });
    const path_out = try getHtmlPath(allocator, entry_name);
    errdefer allocator.free(path_out);

    // Create the output file
    Diagnostic.set(diag, .{ .verb = .create, .object = path_out });
    const file_out = try dir_out.createFile(path_out, .{ .truncate = true });
    defer file_out.close();
    var file_out_writer = file_out.writer(&io_buf);
    const writer = &file_out_writer.interface;

    // Write the complete HTML document
    Diagnostic.set(diag, .{ .verb = .write, .object = path_out });
    try html.writeDocument([]const u8, writer, .{
        .head = .{
            .title = title,
            .title_suffix = conf.site_name,
            .charset = conf.charset,
            .stylesheet = conf.stylesheet,
        },
        .body = html_body,
    }, Writer.writeAll);
    try writer.flush();

    // Record entry in the index if provided.
    if (index) |list| {
        Diagnostic.set(diag, .{ .verb = .allocate, .object = "index" });
        // Ownership of `path_out` and `title` is transferred to the list.
        try list.append(allocator, .{
            .path = path_out,
            .short = null,
            .title = title,
        });
    } else {
        // If there's no index, we are responsible for freeing the memory.
        allocator.free(path_out);
        allocator.free(title);
    }
}

/// Recursively processes a directory, converting markdown files to HTML.
pub fn processDir(
    allocator: Allocator,
    conf: Config,
    diag: ?*Diagnostic,
    index: ?*std.ArrayList(html.IndexEntry),
    args: ProcessDirArgs,
) Error!void {
    // Open input directory.
    Diagnostic.set(diag, .{ .verb = .open, .object = args.subpath_in });
    var dir_in = try args.in.openDir(args.subpath_in, .{ .iterate = true });
    defer dir_in.close();

    // Create and open the corresponding output directory.
    Diagnostic.set(diag, .{ .verb = .create, .object = args.subpath_out });
    args.out.makeDir(args.subpath_out) catch |e| {
        if (e != Error.PathAlreadyExists) return e;
    };

    Diagnostic.set(diag, .{ .verb = .open, .object = args.subpath_out });
    var dir_out = try args.out.openDir(args.subpath_out, .{});
    defer dir_out.close();

    // Iterate over directory entries.
    var it = dir_in.iterate();
    while (true) {
        Diagnostic.set(diag, .{ .verb = .read, .object = args.subpath_in });
        const entry = try it.next() orelse break;

        switch (entry.kind) {
            .directory => {
                // TODO: This is a buggy workaround for when the output
                // directory is a subset of the input directory.
                // Not a proper solution.
                if (std.mem.eql(u8, entry.name, conf.out_dir)) continue;

                if (args.recursive) {
                    try processDir(allocator, conf, diag, null, .{
                        .recursive = args.recursive,
                        .in = dir_in,
                        .subpath_in = entry.name,
                        .out = dir_out,
                        .subpath_out = entry.name,
                    });
                }
            },
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".md")) {
                    try processFile(
                        allocator,
                        conf,
                        diag,
                        index,
                        dir_in,
                        dir_out,
                        entry.name,
                    );
                }
                // TODO: copy or link non-markdown files to dir_out.
            },
            else => {}, // Ignore symlinks, block devices, etc.
        }
    }
}
