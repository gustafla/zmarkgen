const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const Config = @import("config.zig");
const Diagnostic = @import("diagnostic.zig");
const html = @import("html.zig");
const Index = @import("index.zig");
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
        if (c.cmark_node_get_type(node) != c.CMARK_NODE_HEADING) continue;

        // We found the first heading, extract its text content.
        node = c.cmark_node_first_child(node) orelse continue;
        const ptr = c.cmark_node_get_literal(node) orelse continue;
        return allocator.dupe(u8, std.mem.span(ptr));
    }

    // No heading found, use the default title.
    return allocator.dupe(u8, default_title);
}

/// Transforms lists with tickboxes (`e.g. [ ] and [X]`) in the document.
fn fixChecklists(
    document: *c.cmark_node,
) Allocator.Error!void {
    const iter = c.cmark_iter_new(document);
    defer c.cmark_iter_free(iter);

    while (c.cmark_iter_next(iter) != c.CMARK_EVENT_DONE) {
        const node_i = c.cmark_iter_get_node(iter);
        if (c.cmark_node_get_type(node_i) != c.CMARK_NODE_ITEM) continue;

        // Extract inner paragraph and text node.
        const node_p = c.cmark_node_first_child(node_i) orelse continue;
        const node_t = c.cmark_node_first_child(node_p) orelse continue;

        // Get string from node.
        const text_ptr = c.cmark_node_get_literal(node_t) orelse continue;
        const text: [:0]const u8 = std.mem.span(text_ptr);

        // Check for checkbox prefix.
        var checked: ?bool = null;
        if (std.mem.startsWith(u8, text, "[ ] ")) {
            checked = false;
        } else if (std.mem.startsWith(u8, text, "[X] ") or
            std.mem.startsWith(u8, text, "[x] "))
        {
            checked = true;
        }
        if (checked == null) continue;

        // Create raw HTML.
        const checkbox_html = if (checked.?)
            \\<input type="checkbox" checked disabled/>
        else
            \\<input type="checkbox" disabled/>
        ;

        // Create a new cmark node for the raw HTML.
        const html_node = c.cmark_node_new(c.CMARK_NODE_HTML_INLINE);
        _ = c.cmark_node_set_literal(html_node, checkbox_html.ptr);

        // Insert the new checkbox node into the AST right before the text node.
        if (c.cmark_node_insert_before(node_t, html_node) == 0) {
            @panic("cmark_node_insert_before failed");
        }

        // Update the text node to remove the "[ ] " prefix.
        const new_text = text["[X] ".len..];
        _ = c.cmark_node_set_literal(node_t, new_text.ptr);

        // Mark the list item's parent node (list node) as a checklist
        const list = c.cmark_node_parent(node_i) orelse unreachable;
        if (c.cmark_node_get_type(list) == c.CMARK_NODE_LIST) {
            _ = c.cmark_node_set_user_data(list, @ptrFromInt(1));
        }
    }

    // Wrap with a <div class="checklist">
    try wrapChecklists(document);
}

/// Finds lists that have been marked and wraps them in <div class="checklist">.
fn wrapChecklists(
    document: *c.cmark_node,
) Allocator.Error!void {
    const iter = c.cmark_iter_new(document);
    defer c.cmark_iter_free(iter);

    while (c.cmark_iter_next(iter) != c.CMARK_EVENT_DONE) {
        const node = c.cmark_iter_get_node(iter);

        const node_is_list = c.cmark_node_get_type(node) == c.CMARK_NODE_LIST;
        const user_data = c.cmark_node_get_user_data(node);

        if (!node_is_list or user_data == null) continue;

        // Create the opening <div> tag as an HTML block.
        const open_div_html = "<div class=\"checklist\">";
        const open_div_node = c.cmark_node_new(c.CMARK_NODE_HTML_BLOCK);
        _ = c.cmark_node_set_literal(open_div_node, open_div_html.ptr);

        // Insert the opening <div> before the list node.
        _ = c.cmark_node_insert_before(node, open_div_node);

        // Create and insert the closing </div> tag after the list node.
        const close_div_html = "</div>";
        const close_div_node = c.cmark_node_new(c.CMARK_NODE_HTML_BLOCK);
        _ = c.cmark_node_set_literal(close_div_node, close_div_html.ptr);
        _ = c.cmark_node_insert_after(node, close_div_node);

        // Un-mark the node so we don't process it again.
        _ = c.cmark_node_set_user_data(node, null);
    }
}

/// Transforms root-relative link hrefs in the document to relative hrefs
/// and transforms .md -suffices to .html suffices.
fn fixHrefs(
    allocator: Allocator,
    root_rel: []const u8,
    document: *c.cmark_node,
) Allocator.Error!void {
    const iter = c.cmark_iter_new(document);
    defer c.cmark_iter_free(iter);

    while (c.cmark_iter_next(iter) != c.CMARK_EVENT_DONE) {
        const node = c.cmark_iter_get_node(iter);
        if (c.cmark_node_get_type(node) != c.CMARK_NODE_LINK) continue;

        const url = c.cmark_node_get_url(node) orelse continue;
        const raw_href: []const u8 = std.mem.span(url);
        if (raw_href.len == 0) continue;
        var href = raw_href;

        // Transform .md suffix into .html
        if (std.mem.endsWith(u8, href, ".md")) {
            const htmlized = try getHtmlPath(allocator, href);
            errdefer allocator.free(htmlized);
            href = htmlized;
        }

        // Transform root-relative href
        if (std.mem.startsWith(u8, href, "/")) {
            const relativized = try std.mem.concat(allocator, u8, &.{
                root_rel, href[1..],
            });
            errdefer allocator.free(relativized);
            if (href.ptr != raw_href.ptr) allocator.free(href);
            href = relativized;
        }

        // If not transformed, omit rest of the processing
        if (href.ptr == raw_href.ptr) continue;

        // Create C string
        const href_c = try allocator.dupeZ(u8, href);
        defer allocator.free(href_c);
        allocator.free(href);

        // Set transformed href, clean up if allocations were made
        if (c.cmark_node_set_url(node, href_c) == 0) {
            @panic("cmark_node_set_url failed");
        }
    }
}

/// Processes an index list: renders and writes it as HTML.
fn processIndex(
    conf: Config,
    diag: ?*Diagnostic,
    index: Index,
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
    try html.writeDocument(Index, writer, .{
        .head = .{
            .title = index.title,
            .title_suffix = null,
            .charset = conf.charset,
            .stylesheet = conf.stylesheet,
        },
        .body = index,
    }, Index.writeHtml);
}

/// Processes a single markdown file: reads, renders, and writes it as HTML.
fn processMdFile(
    allocator: Allocator,
    conf: Config,
    diag: ?*Diagnostic,
    section: *Index.Section,
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
        c.CMARK_OPT_UNSAFE,
    ) orelse return error.CmarkParseFailed;
    defer c.cmark_node_free(document);

    // Transform root-relative link hrefs into relative.
    Diagnostic.set(diag, .{ .verb = .allocate, .object = "link href" });
    try fixHrefs(allocator, root_rel, document);

    // Make checklists prettier.
    Diagnostic.set(diag, .{ .verb = .allocate, .object = "list item" });
    try fixChecklists(document);

    // Render the document to an HTML string.
    Diagnostic.set(diag, .{ .verb = .render, .object = paths.in });
    const html_ptr = c.cmark_render_html(
        document,
        c.CMARK_OPT_UNSAFE,
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
    defer allocator.free(title);

    Diagnostic.set(diag, .{ .verb = .allocate, .object = "filename" });
    const path_out = try getHtmlPath(allocator, paths.out);
    defer allocator.free(path_out);

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
    Diagnostic.set(diag, .{ .verb = .allocate, .object = "index" });
    // Get path without output directory prefix.
    const sep = std.mem.indexOfScalar(u8, path_out, std.fs.path.sep).?;
    const href = path_out[sep + 1 ..];

    // Values of `path_out` and `title` are copied to the index.
    Diagnostic.set(diag, .{ .verb = .allocate, .object = "index entry" });
    try section.addEntry(allocator, href, title, null);
}

/// Recursively processes a directory, converting markdown files to HTML.
fn processDirRecursive(
    allocator: Allocator,
    diag: ?*Diagnostic,
    conf: Config,
    index: *Index,
    paths: Paths,
) Error!void {
    // Open input directory.
    Diagnostic.set(diag, .{ .verb = .open, .object = paths.in });
    var dir_in = try std.fs.cwd().openDir(paths.in, .{ .iterate = true });
    defer dir_in.close();

    // Create the corresponding output directory.
    Diagnostic.set(diag, .{ .verb = .create, .object = paths.out });
    std.fs.cwd().makeDir(paths.out) catch |e| {
        if (e != Error.PathAlreadyExists) return e;
    };

    // Get directory depth, create root-relative link prefix.
    Diagnostic.set(diag, .{ .verb = .allocate, .object = "relative path" });
    const depth = std.mem.count(u8, paths.out, &.{std.fs.path.sep});
    const root_rel = try file.dotdot(allocator, depth);
    defer allocator.free(root_rel);

    // Create index section.
    const slash = std.mem.indexOfScalar(u8, paths.out, std.fs.path.sep);
    const section_title = if (depth == 0) null else paths.out[slash.? + 1 ..];
    Diagnostic.set(diag, .{ .verb = .allocate, .object = "index section" });
    const section_index = try index.addSection(allocator, section_title);

    // Iterate over directory entries.
    var it = dir_in.iterate();
    while (true) {
        Diagnostic.set(diag, .{ .verb = .read, .object = paths.in });
        const entry = try it.next() orelse break;

        // Get a fresh, valid pointer to our section.
        const section = index.getSection(section_index);

        // Allocate subpaths for entry.
        Diagnostic.set(diag, .{ .verb = .allocate, .object = "paths" });
        const subpaths = try paths.join(allocator, entry.name);
        defer subpaths.deinit(allocator);

        switch (entry.kind) {
            .directory => {
                // TODO: This is a buggy workaround for when the output
                // directory is a subset of the input directory.
                // Not a proper solution.
                if (std.mem.eql(u8, entry.name, conf.out_dir)) continue;

                try processDirRecursive(
                    allocator,
                    diag,
                    conf,
                    index,
                    subpaths,
                );
            },
            .sym_link, .file => {
                std.log.debug("{s}", .{subpaths.in});
                if (std.mem.endsWith(u8, entry.name, ".md")) {
                    try processMdFile(
                        allocator,
                        conf,
                        diag,
                        section,
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
            else => {}, // Ignore block devices etc.
        }
    }
}

/// Recursively processes a directory, converting markdown files to HTML.
/// Builds an index HTML file.
pub fn processDir(
    allocator: Allocator,
    diag: ?*Diagnostic,
    conf: Config,
    paths: Paths,
) Error!void {
    // Initialize index list.
    Diagnostic.set(diag, .{ .verb = .allocate, .object = "index" });
    var index = try Index.init(allocator, conf.site_name orelse "Index");
    defer index.deinit(allocator);

    // Process the directory tree.
    try processDirRecursive(allocator, diag, conf, &index, paths);

    // Output index.
    Diagnostic.set(diag, .{ .verb = .open, .object = paths.out });
    var dir_out = try std.fs.cwd().openDir(paths.out, .{});
    defer dir_out.close();
    try processIndex(conf, diag, index, dir_out, "index.html");
}
