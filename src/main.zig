const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("cmark.h");
});

pub const std_options: std.Options = .{
    .log_level = if (builtin.mode == .Debug) .debug else .warn,
};

pub fn main() void {
    std.log.info("Using cmark {s}", .{c.cmark_version_string()});
}
