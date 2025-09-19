# Zmarkgen

A very simple, quick-and-dirty static site generator, written in Zig with cmark.

I made this for organizing my personal notes.

## Usage

By default the `zmarkgen` command reads all .md-files from the working directory
and generates corresponding .html files in `generated`.

You can also specify an input directory, eg. `zmarkgen doc`.

See `zmarkgen -h` for another example.

