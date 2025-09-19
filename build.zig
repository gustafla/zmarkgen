const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize == .ReleaseSmall,
    });

    const exe = b.addExecutable(.{
        .name = "zmarkgen",
        .root_module = exe_mod,
    });
    exe.linkLibC();
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
