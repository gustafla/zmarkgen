const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const Config = @import("config.zig");
const Diagnostic = @import("diagnostic.zig");
const html = @import("html.zig");
const file = @import("file.zig");

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
    file.Error ||
    error{
        CmarkParseFailed,
        CmarkRenderFailed,
    };

const Paths = struct {
    in: []const u8,
    out: []const u8,

    /// Appends `subpath` to `in` and `out`.
    pub fn join(
        self: @This(),
        allocator: Allocator,
        subpath: []const u8,
    ) Allocator.Error!Paths {
        return .{
            .in = try std.fs.path.join(
                allocator,
                &.{ self.in, subpath },
            ),
            .out = try std.fs.path.join(
                allocator,
                &.{ self.out, subpath },
            ),
        };
    }

    /// Frees `in` and `out`.
    pub fn deinit(self: @This(), allocator: Allocator) void {
        allocator.free(self.in);
        allocator.free(self.out);
    }
};

/// Derives an ".html" path from a ".md" path.
fn getHtmlPath(
    allocator: Allocator,
    md_path: []const u8,
) Allocator.Error![]const u8 {
    const html_extension = ".html";

    // We cannot use std.fs.path.stem(md_path),
    // because it would only return the basename, not a full (sub)path.
    const last_dot = std.mem.lastIndexOfScalar(u8, md_path, '.') orelse {
        return md_path;
    };
    if (last_dot == 0) return md_path;
    const path = md_path[0..last_dot];

    return std.mem.concat(allocator, u8, &.{ path, html_extension });
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

/// Processes an index list: renders and writes it as HTML.
fn processIndex(
    conf: Config,
    diag: ?*Diagnostic,
    index: []const html.IndexEntry,
    dir_out: std.fs.Dir,
    filename: []const u8,
) Error!void {
    // Allocate a small IO buffer on the stack.
    var buf: [1024]u8 = undefined;

    // Create the index file.
    Diagnostic.set(diag, .{ .verb = .create, .object = filename });
    const index_out = try dir_out.createFile(filename, .{ .truncate = true });
    defer index_out.close();
    var index_writer = index_out.writer(&buf);
    const writer = &index_writer.interface;

    // Write index HTML.
    Diagnostic.set(diag, .{ .verb = .write, .object = filename });
    const title = conf.site_name orelse "Index";
    try html.writeDocument(html.Index, writer, .{
        .head = .{
            .title = title,
            .title_suffix = null,
            .charset = conf.charset,
            .stylesheet = conf.stylesheet,
        },
        .body = .{
            .title = title,
            .items = index,
        },
    }, html.writeIndex);
}

/// Processes a single markdown file: reads, renders, and writes it as HTML.
fn processMdFile(
    allocator: Allocator,
    conf: Config,
    diag: ?*Diagnostic,
    index: ?*std.ArrayList(html.IndexEntry),
    root_rel: []const u8,
    paths: Paths,
) Error!void {
    // Allocate a small IO buffer on the stack.
    var io_buf: [1024]u8 = undefined;

    // Open the input markdown file.
    Diagnostic.set(diag, .{ .verb = .open, .object = paths.in });
    const file_in = try std.fs.cwd().openFile(paths.in, .{});
    defer file_in.close();
    var file_in_reader = file_in.reader(&io_buf);
    const reader = &file_in_reader.interface;

    // Stat the input file to allocate the right amount of memory.
    Diagnostic.set(diag, .{ .verb = .stat, .object = paths.in });
    const stat_in = try file_in.stat();

    // Read the input markdown file.
    Diagnostic.set(diag, .{ .verb = .read, .object = paths.in });
    const md_content = try reader.readAlloc(allocator, stat_in.size);
    defer allocator.free(md_content);

    // Parse markdown content into a cmark document.
    Diagnostic.set(diag, .{ .verb = .parse, .object = paths.in });
    const document = c.cmark_parse_document(
        md_content.ptr,
        md_content.len,
        c.CMARK_OPT_DEFAULT,
    ) orelse return error.CmarkParseFailed;
    defer c.cmark_node_free(document);

    // Render the document to an HTML string.
    Diagnostic.set(diag, .{ .verb = .render, .object = paths.in });
    const html_ptr = c.cmark_render_html(
        document,
        c.CMARK_OPT_DEFAULT,
    ) orelse return error.CmarkRenderFailed;
    defer std.c.free(html_ptr);
    const html_body = std.mem.span(html_ptr);

    // Extract title and generate the output path.
    // These are allocated and must be freed if not added to the index.
    Diagnostic.set(diag, .{ .verb = .allocate, .object = "page title" });
    const title = try extractTitle(
        allocator,
        document,
        std.fs.path.basename(paths.in),
    );
    errdefer allocator.free(title);

    Diagnostic.set(diag, .{ .verb = .allocate, .object = "filename" });
    const path_out = try getHtmlPath(allocator, paths.out);
    errdefer allocator.free(path_out);

    // Create the output file.
    Diagnostic.set(diag, .{ .verb = .create, .object = path_out });
    const file_out = try std.fs.cwd().createFile(
        path_out,
        .{ .truncate = true },
    );
    defer file_out.close();
    var file_out_writer = file_out.writer(&io_buf);
    const writer = &file_out_writer.interface;

    // Create stylesheet link
    Diagnostic.set(diag, .{ .verb = .allocate, .object = "relative path" });
    const stylesheet = if (conf.stylesheet) |href|
        try std.mem.concat(allocator, u8, &.{ root_rel, href })
    else
        null;
    defer if (stylesheet) |href| allocator.free(href);

    // Write the complete HTML document.
    Diagnostic.set(diag, .{ .verb = .write, .object = path_out });
    try html.writeDocument([]const u8, writer, .{
        .head = .{
            .title = title,
            .title_suffix = conf.site_name,
            .charset = conf.charset,
            .stylesheet = stylesheet,
        },
        .body = html_body,
    }, Writer.writeAll);
    try writer.flush();

    // Record entry in the index if provided.
    if (index) |list| {
        Diagnostic.set(diag, .{ .verb = .allocate, .object = "index" });
        // Get path without output directory prefix.
        const sep = std.mem.indexOfScalar(u8, path_out, std.fs.path.sep).?;
        const href = path_out[sep + 1 ..];

        // Ownership of `path_out` and `title` is transferred to the list.
        try list.append(allocator, .{
            .path = href,
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
fn processDirRecursive(
    allocator: Allocator,
    diag: ?*Diagnostic,
    conf: Config,
    index: ?*std.ArrayList(html.IndexEntry),
    allow_recursion: bool,
    paths: Paths,
) Error!void {
    // Open input directory.
    Diagnostic.set(diag, .{ .verb = .open, .object = paths.in });
    var dir_in = try std.fs.cwd().openDir(paths.in, .{ .iterate = true });
    defer dir_in.close();

    // Create and the corresponding output directory.
    Diagnostic.set(diag, .{ .verb = .create, .object = paths.out });
    std.fs.cwd().makeDir(paths.out) catch |e| {
        if (e != Error.PathAlreadyExists) return e;
    };

    // Iterate over directory entries.
    var it = dir_in.iterate();
    while (true) {
        Diagnostic.set(diag, .{ .verb = .read, .object = paths.in });
        const entry = try it.next() orelse break;

        // Allocate subpaths for entry
        Diagnostic.set(diag, .{ .verb = .allocate, .object = "paths" });
        const subpaths = try paths.join(allocator, entry.name);
        defer subpaths.deinit(allocator);

        // Get directory depth, create root-relative link prefix
        Diagnostic.set(diag, .{ .verb = .allocate, .object = "relative path" });
        const depth = std.mem.count(u8, paths.out, &.{std.fs.path.sep});
        const root_rel = try file.dotdot(allocator, depth);
        defer allocator.free(root_rel);

        switch (entry.kind) {
            .directory => {
                // TODO: This is a buggy workaround for when the output
                // directory is a subset of the input directory.
                // Not a proper solution.
                if (std.mem.eql(u8, entry.name, conf.out_dir)) continue;

                if (allow_recursion) {
                    try processDirRecursive(
                        allocator,
                        diag,
                        conf,
                        index,
                        allow_recursion,
                        subpaths,
                    );
                }
            },
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".md")) {
                    try processMdFile(
                        allocator,
                        conf,
                        diag,
                        index,
                        root_rel,
                        subpaths,
                    );
                } else {
                    Diagnostic.set(diag, .{
                        .verb = .copy,
                        .object = subpaths.in,
                    });
                    try file.linkOut(
                        allocator,
                        conf.symlink,
                        subpaths.in,
                        subpaths.out,
                    );
                }
            },
            else => {}, // Ignore symlinks, block devices, etc.
        }
    }
}

/// Recursively processes a directory, converting markdown files to HTML.
/// Builds an index HTML file.
pub fn processDir(
    allocator: Allocator,
    diag: ?*Diagnostic,
    conf: Config,
    recursive: bool,
    paths: Paths,
) Error!void {
    // Initialize index list.
    var index: std.ArrayList(html.IndexEntry) = .empty;
    defer index.deinit(allocator);

    // Process the directory tree.
    try processDirRecursive(allocator, diag, conf, &index, recursive, paths);

    // Output index.
    Diagnostic.set(diag, .{ .verb = .open, .object = paths.out });
    var dir_out = try std.fs.cwd().openDir(paths.out, .{});
    defer dir_out.close();
    try processIndex(conf, diag, index.items, dir_out, "index.html");
}
