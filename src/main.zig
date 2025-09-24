const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const options = @import("options");

const Config = @import("config.zig");
const Diagnostic = @import("diagnostic.zig");
const file = @import("file.zig");
const html = @import("html.zig");
const md = @import("md.zig");

const CliOptions = struct {
    recursive: bool = false,
    config_path: []const u8 = "zmarkgen.zon",
    input_dir: []const u8 = ".",

    pub fn parse() CliOptions {
        var result: @This() = .{};

        var args = std.process.args();
        _ = args.skip();
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "-h")) {
                std.log.info(
                    \\Example: {s} -c my_blog.zon
                , .{options.name});
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "-v")) {
                std.log.info("{s} v{s}", .{ options.name, options.version });
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "-r")) {
                result.recursive = true;
            } else if (std.mem.eql(u8, arg, "-c")) {
                if (args.next()) |path| {
                    result.config_path = path;
                } else {
                    std.log.err("Option -c requires a file path", .{});
                    std.process.exit(1);
                }
            } else {
                result.input_dir = arg;
                break;
            }
        }

        if (args.skip()) {
            std.log.err("Too many arguments, see usage with -h", .{});
            std.process.exit(1);
        }

        return result;
    }
};

pub fn main() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.raw_c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const opt = CliOptions.parse();

    // Load config file
    std.log.info("Loading {s}", .{opt.config_path});
    var zon_diagnostics: std.zon.parse.Diagnostics = .{};
    const conf: Config = Config.load(
        allocator,
        opt.config_path,
        &zon_diagnostics,
    ) catch |e| switch (e) {
        Config.Error.FileNotFound => def: {
            std.log.info(
                "File {s} not found, using defaults",
                .{opt.config_path},
            );
            break :def .{};
        },
        Config.Error.ParseZon => {
            std.log.err("{f}", .{zon_diagnostics});
            std.process.exit(1);
        },
        // TODO: This error can be removed if the input-output subtree problem
        // when using -r is solved properly. See other TODO comments.
        Config.Error.OutDirTooComplex => {
            std.log.err(
                \\Config field out_dir must be a relative path,
                \\and may not specify any subdirectories
                \\
            , .{});
            std.process.exit(1);
        },
        else => {
            std.log.err("Unhandled error: {any}", .{e});
            std.process.exit(1);
        },
    };

    // Run the site generator.
    var diag: Diagnostic = undefined;
    md.processDir(allocator, &diag, conf, opt.recursive, .{
        .in = opt.input_dir,
        .out = conf.out_dir,
    }) catch |e| {
        std.log.err("{f}: {t}", .{ diag, e });
        std.process.exit(1);
    };
}

// Silence debug messages in release builds.
pub const std_options: std.Options = .{
    .log_level = if (builtin.mode == .Debug) .debug else .info,
};

// Enable the compiler to find tests in all imports.
test {
    std.testing.refAllDeclsRecursive(@This());
}
