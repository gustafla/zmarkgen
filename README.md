# Zmarkgen

[![CI](https://github.com/gustafla/zmarkgen/actions/workflows/ci.yml/badge.svg)](https://github.com/gustafla/zmarkgen/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/gustafla/zmarkgen/graph/badge.svg?token=QG5PM8TAM9)](https://codecov.io/gh/gustafla/zmarkgen)

A very simple static site generator, written in Zig with
the [commonmark](https://github.com/commonmark/cmark) library.

This tool was written primarily for the purpose of organizing my personal notes.
I do not intend to develop this into a feature-rich static site generator, for
that purpose try [zine](https://zine-ssg.io/) or [hugo](https://gohugo.io/).

## Build

This project uses the Zig build system. You need Zig 0.15.1.

To build a release binary for your native architecture and OS, run
```
zig build -Doptimize=ReleaseSafe
```
After a successful build, the `zmarkgen` binary can be found in `zig-out/bin`.

## Usage

By default the `zmarkgen` command reads all .md-files from the working directory
and generates corresponding .html files in `generated`.

You can also specify an input directory, eg. `zmarkgen doc`.

See `zmarkgen -h` for another example.
