const std = @import("std");
const Allocator = std.mem.Allocator;
const zon = @import("build.zig.zon");

fn allMatch(comptime T: type, slice: []const T, pred: fn (T) bool) bool {
    for (slice) |elem| {
        if (!pred(elem)) return false;
    }
    return true;
}

fn cmarkVersionHeader(gpa: Allocator) []const u8 {
    var buf = std.ArrayList(u8).empty;
    const url = zon.dependencies.cmark.url;
    var start = std.mem.lastIndexOfScalar(u8, url, '/').? + 1;
    var len = std.mem.indexOfScalar(u8, url[start..], '.').?;
    const major = url[start..][0..len];

    start += len + 1;
    len = std.mem.indexOfScalar(u8, url[start..], '.').?;
    const minor = url[start..][0..len];

    start += len + 1;
    len = std.mem.indexOfScalar(u8, url[start..], '.').?;
    const patch = url[start..][0..len];

    std.debug.assert(allMatch(u8, major, std.ascii.isDigit));
    std.debug.assert(allMatch(u8, minor, std.ascii.isDigit));
    std.debug.assert(allMatch(u8, patch, std.ascii.isDigit));

    buf.print(gpa,
        \\#ifndef CMARK_VERSION_H
        \\#define CMARK_VERSION_H
        \\#define CMARK_VERSION (({[major]s} << 16) | ({[minor]s} << 8) | {[patch]s})
        \\#define CMARK_VERSION_STRING "{[major]s}.{[minor]s}.{[patch]s}"
        \\#endif
        \\
    , .{
        .major = major,
        .minor = minor,
        .patch = patch,
    }) catch @panic("OOM");
    return buf.items;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Gather some fields from build.zig.zon
    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);
    options.addOption([]const u8, "name", @tagName(zon.name));

    // Markdown renderer library: cmark
    const cmark = b.dependency("cmark", .{});
    const cmark_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = optimize == .ReleaseSmall,
    });

    const cmark_gen_headers = b.addWriteFiles();
    _ = cmark_gen_headers.add("cmark_export.h",
        \\#ifndef CMARK_EXPORT_H
        \\#define CMARK_EXPORT_H
        \\#define CMARK_EXPORT
        \\#define CMARK_NO_EXPORT
        \\#endif
        \\
    );
    _ = cmark_gen_headers.add(
        "cmark_version.h",
        cmarkVersionHeader(b.allocator),
    );
    cmark_mod.addIncludePath(cmark_gen_headers.getDirectory());
    cmark_mod.addCSourceFiles(.{
        .root = cmark.path("src"),
        .files = &.{
            "blocks.c",
            "buffer.c",
            "cmark.c",
            "cmark_ctype.c",
            "commonmark.c",
            "houdini_href_e.c",
            "houdini_html_e.c",
            "houdini_html_u.c",
            "html.c",
            "inlines.c",
            "iterator.c",
            "latex.c",
            "man.c",
            "node.c",
            "references.c",
            "render.c",
            "scanners.c",
            //"scanners.re",
            "utf8.c",
            "xml.c",
        },
    });

    const cmark_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "cmark",
        .root_module = cmark_mod,
    });

    // Main executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize == .ReleaseSmall,
        .link_libc = true,
    });

    exe_mod.addIncludePath(cmark.path("src"));
    exe_mod.addIncludePath(cmark_gen_headers.getDirectory());
    exe_mod.linkLibrary(cmark_lib);
    exe_mod.addOptions("options", options);

    const exe = b.addExecutable(.{
        .name = "zmarkgen",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // Run step
    const exe_run = b.addRunArtifact(exe);
    exe_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        exe_run.addArgs(args);
    }
    const run_step = b.step("run", "Run the generator");
    run_step.dependOn(&exe_run.step);

    // Linting step
    const fmt_step = b.step("fmt", "Check formatting");
    const fmt = b.addFmt(.{
        .paths = &.{
            "src/",
            "build.zig",
            "build.zig.zon",
        },
        .check = true,
    });
    fmt_step.dependOn(&fmt.step);
}
