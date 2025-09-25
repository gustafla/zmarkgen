const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

title: []const u8,
sections: std.ArrayList(Section),

pub const Section = struct {
    title: ?[]const u8,
    entries: std.ArrayList(Entry),

    pub fn addEntry(
        self: *@This(),
        allocator: Allocator,
        path: []const u8,
        title: []const u8,
        snippet: ?[]const u8,
    ) Allocator.Error!void {
        try self.entries.append(allocator, .{
            .path = try allocator.dupe(u8, path),
            .title = try allocator.dupe(u8, title),
            .snippet = if (snippet) |s| try allocator.dupe(u8, s) else null,
        });
    }
};

pub const Entry = struct {
    path: []const u8,
    title: []const u8,
    snippet: ?[]const u8,
};

pub fn deinit(self: *@This(), allocator: Allocator) void {
    for (self.sections.items) |*section| {
        if (section.title) |title| {
            allocator.free(title);
        }
        for (section.entries.items) |*entry| {
            allocator.free(entry.path);
            allocator.free(entry.title);
            if (entry.snippet) |snip| {
                allocator.free(snip);
            }
        }
        section.entries.deinit(allocator);
    }
    allocator.free(self.title);
    self.sections.deinit(allocator);
}

pub fn init(
    allocator: Allocator,
    title: []const u8,
) Allocator.Error!@This() {
    return .{
        .title = try allocator.dupe(u8, title),
        .sections = .empty,
    };
}

pub fn addSection(
    self: *@This(),
    allocator: Allocator,
    title: ?[]const u8,
) Allocator.Error!usize {
    try self.sections.append(allocator, .{
        .title = if (title) |t| try allocator.dupe(u8, t) else null,
        .entries = .empty,
    });
    return self.sections.items.len - 1;
}

pub fn getSection(self: *@This(), index: usize) *Section {
    return &self.sections.items[index];
}

pub fn writeHtml(writer: *Writer, index: @This()) Writer.Error!void {
    try writer.print("<h1>{s}</h1>\n", .{index.title});
    for (index.sections.items) |section| {
        if (section.title) |title| {
            try writer.print("<h1>{s}</h1>\n", .{title});
        }
        for (section.entries.items) |entry| {
            try writer.writeAll("<div class=\"indexEntry\">");
            try writer.print(
                "<a href=\"{s}\"><h3>{s}</h3></a>\n",
                .{ entry.path, entry.title },
            );
            if (entry.snippet) |snip| {
                try writer.print("<p class=\"snippet\">{s}...</p>\n", .{snip});
            }
            try writer.writeAll("</div>");
        }
    }
}
