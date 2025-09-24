const std = @import("std");
const Writer = std.Io.Writer;
const Error = Writer.Error;

pub const Head = struct {
    charset: []const u8,
    stylesheet: ?[]const u8,
    title: []const u8,
    title_suffix: ?[]const u8,
};

pub fn Document(comptime Body: type) type {
    return struct {
        head: Head,
        body: Body,
    };
}

pub fn writeHead(writer: *Writer, head: Head) Error!void {
    try writer.writeAll("<head>\n");

    // Add charset
    try writer.print("<meta charset=\"{s}\">\n", .{head.charset});

    // Add stylesheet link
    if (head.stylesheet) |name| {
        try writer.print("<link rel=\"stylesheet\" href=\"{s}\">\n", .{name});
    }

    // Add title and optional suffix
    try writer.print("<title>{s}", .{head.title});
    if (head.title_suffix) |suffix| {
        try writer.print(" - {s}", .{suffix});
    }
    try writer.writeAll("</title>\n");

    try writer.writeAll("</head>\n");
}

pub fn writeBody(
    comptime Body: type,
    writer: *Writer,
    body: Body,
    innerWrite: fn (*Writer, Body) Error!void,
) Error!void {
    try writer.writeAll("<body>\n");
    try innerWrite(writer, body);
    try writer.writeAll("</body>\n");
}

pub fn writeDocument(
    comptime Body: type,
    writer: *Writer,
    document: Document(Body),
    bodyWrite: fn (*Writer, Body) Error!void,
) Error!void {
    try writer.writeAll("<!DOCTYPE html>\n<html>\n");
    try writeHead(writer, document.head);
    try writeBody(Body, writer, document.body, bodyWrite);
    try writer.writeAll("</html>\n");
    try writer.flush();
}

// #### Tests ####

test "html head has head tags" {
    var writer = Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    try writeHead(&writer.writer, .{
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

    var writer = Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    try writeHead(&writer.writer, .{
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
