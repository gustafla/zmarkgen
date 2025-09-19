const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Markdown renderer library: cmark
    const cmark = b.dependency("cmark", .{});
    const cmark_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = optimize == .ReleaseSmall,
    });

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
    exe_mod.linkLibrary(cmark_lib);

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
}
