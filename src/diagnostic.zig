const std = @import("std");
const Writer = std.Io.Writer;

verb: Verb,
object: []const u8,

const Verb = enum {
    open,
    create,
    stat,
    read,
    write,
    parse,
    render,
    allocate,
};

pub fn format(self: @This(), w: *Writer) Writer.Error!void {
    try w.print("Failed to {[verb]t} {[object]s}", self);
}

pub fn set(self: ?*@This(), val: @This()) void {
    if (self) |diag| {
        diag.* = val;
    }
}
