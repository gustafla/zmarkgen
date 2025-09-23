const std = @import("std");
const Writer = std.Io.Writer;

pub const IndexEntry = struct {
    path: []const u8,
    title: []const u8,
    short: ?[]const u8,
};

pub fn writeHead(context: anytype) Writer.Error!void {
    const writer = context.writer;
    try writer.writeAll("<head>\n");

    // Add charset
    try writer.print("<meta charset=\"{s}\">\n", .{context.charset});

    // Add stylesheet link
    if (context.stylesheet) |name| {
        try writer.print("<link rel=\"stylesheet\" href=\"{s}\">\n", .{name});
    }

    // Add title and optional suffix
    try writer.print("<title>{s}", .{context.title});
    if (context.title_suffix) |suffix| {
        try writer.print(" - {s}", .{suffix});
    }
    try writer.writeAll("</title>\n");

    try writer.writeAll("</head>\n");
}

pub fn writeFragment(context: anytype) Writer.Error!void {
    try context.writer.writeAll(context.html);
}

pub fn writeBody(
    context: anytype,
    innerWrite: fn (anytype) Writer.Error!void,
) Writer.Error!void {
    try context.writer.writeAll("<body>\n");
    try innerWrite(context);
    try context.writer.writeAll("</body>\n");
}

pub fn writeDocument(
    context: anytype,
    bodyWrite: fn (anytype) Writer.Error!void,
) Writer.Error!void {
    try context.writer.writeAll("<!DOCTYPE html>\n<html>\n");
    try writeHead(context);
    try writeBody(context, bodyWrite);
    try context.writer.writeAll("</html>\n");
    try context.writer.flush();
}

pub fn writeIndex(context: anytype) Writer.Error!void {
    try context.writer.print("<h1>{s}</h1>\n", .{context.title});
    for (context.index) |entry| {
        try context.writer.writeAll("<div class=\"indexEntry\">");
        try context.writer.print(
            "<a href=\"{s}\"><h2>{s}</h2></a>\n",
            .{ entry.path, entry.title },
        );
        if (entry.short) |short| {
            try context.writer.print("<p>{s}</p>\n", .{short});
        }
        try context.writer.writeAll("</div>");
    }
}

// #### Tests ####

test "html head has head tags" {
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    try writeHead(.{
        .writer = &writer.writer,
        .charset = "utf-8",
        .stylesheet = null,
        .title = "Index",
        .title_suffix = null,
    });
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
    try writeHead(.{
        .writer = &writer.writer,
        .charset = "utf-8",
        .stylesheet = null,
        .title = page,
        .title_suffix = @as(?[]const u8, site),
    });
    const string = try writer.toOwnedSlice();
    defer std.testing.allocator.free(string);
    try std.testing.expect(std.mem.containsAtLeast(u8, string, 1, "<title>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, string, 1, site));
    try std.testing.expect(std.mem.containsAtLeast(u8, string, 1, page));
    try std.testing.expect(std.mem.containsAtLeast(u8, string, 1, "</title>"));
}
