# Configuration

`zmarkgen` reads either `zmarkgen.zon` or any file containing valid
[.zon-syntax](https://ziglang.org/documentation/master/#toc-import)
specified by the `-c` flag.

## Example

See also [repository's configuration](../zmarkgen.zon).

```zig
.{
    // The name of the output directory. Default: "generated".
    .out_dir = "my-epic-site"

    // The <meta charset=...> -tag to add to HTML header. Default: "utf-8".
    // Note that zmarkgen doesn't convert text encoding.
    //.charset =
    // ^ Note that fields can be omitted to use defaults

    // Use symlink to source files where applicable,
    // instead of copying to out_dir. Default: true.
    .symlink = false,

    // Add a stylesheet file and corresponding <link> -tag in the HTML header.
    // Default: null
    .stylesheet = "epic.css",

    // Suffix a site name to generated <title> tags, e.g. "Page 1 - Site Name".
    // Default: null
    .site_name = "My Epic Site",
}
```
