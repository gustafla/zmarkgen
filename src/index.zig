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
        short: ?[]const u8,
    ) Allocator.Error!*Entry {
        const entry = try self.entries.addOne(allocator);
        entry.* = .{
            .path = try allocator.dupe(u8, path),
            .title = try allocator.dupe(u8, title),
            .short = if (short) |s| try allocator.dupe(u8, s) else null,
        };
        return entry;
    }
};

pub const Entry = struct {
    path: []const u8,
    title: []const u8,
    short: ?[]const u8,
};

pub fn deinit(self: *@This(), allocator: Allocator) void {
    for (self.sections.items) |*section| {
        if (section.title) |title| {
            allocator.free(title);
        }
        for (section.entries.items) |*entry| {
            allocator.free(entry.path);
            allocator.free(entry.title);
            if (entry.short) |short| {
                allocator.free(short);
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
) Allocator.Error!*Section {
    const section = try self.sections.addOne(allocator);
    section.* = .{
        .title = if (title) |t| try allocator.dupe(u8, t) else null,
        .entries = .empty,
    };
    return section;
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
            if (entry.short) |short| {
                try writer.print("<p>{s}</p>\n", .{short});
            }
            try writer.writeAll("</div>");
        }
    }
}
