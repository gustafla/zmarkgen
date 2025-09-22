# Using the Zig Build System to Build Your Dependencies

The [build.zig](build.zig) file in this project doesn't depend on any external
tools like `cmake` or `git`. The release tarball from commonmark was added
directly to [build.zig.zon](build.zig.zon) via running
```
zig fetch --save https://github.com/commonmark/cmark/archive/refs/tags/0.31.1.tar.gz
```
Then, porting the CMakeLists.txt to the Zig build system was quite easy, here's
how:

### 1. Create a library

```zig
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
        // ... lines omitted for brevity
        "utf8.c",
        "xml.c",
    },
});

const cmark_lib = b.addLibrary(.{
    .linkage = .static,
    .name = "cmark",
    .root_module = cmark_mod,
});
```

The list of C source files was just copy-pasted quite directly from the cmark
tarball's `src/CMakeLists.txt`.

### 2. Fix issues

The upstream cmark build also generates some headers depending on the build
configuration. I ran a cmake build of the cmark tarball and figured out what the
header contents should be. Generating source files with the Zig build system is
easy:
```zig
const cmark_gen_headers = b.addWriteFiles();
_ = cmark_gen_headers.add("cmark_export.h",
    \\#ifndef CMARK_EXPORT_H
    \\#define CMARK_EXPORT_H
    \\#define CMARK_EXPORT
    \\#define CMARK_NO_EXPORT
    \\#endif
    \\
);
_ = cmark_gen_headers.add("cmark_version.h",
    \\#ifndef CMARK_VERSION_H
    \\#define CMARK_VERSION_H
    \\#define CMARK_VERSION ((0 << 16) | (31 << 8) | 1)
    \\#define CMARK_VERSION_STRING "0.31.1"
    \\#endif
    \\
);
cmark_mod.addIncludePath(cmark_gen_headers.getDirectory());
```

### 3. Link with your binary

```zig
exe_mod.addIncludePath(cmark.path("src"));
exe_mod.addIncludePath(cmark_gen_headers.getDirectory());
exe_mod.linkLibrary(cmark_lib);
```

### Full details

See [build.zig](build.zig) for the full details. It has version number parsing
from the source URL so that the `cmark_version.h` is generated from a single
source of truth.
