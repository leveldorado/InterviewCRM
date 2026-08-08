const std = @import("std");

pub const css = @embedFile("assets/app.css");
pub const htmx = @embedFile("assets/vendor/htmx.min.js");
pub const favicon = @embedFile("assets/favicon.svg");

comptime {
    @setEvalBranchQuota(100_000);
    if (htmx.len < 40_000) {
        @compileError("Vendored HTMX file appears incomplete");
    }
    if (std.mem.indexOf(u8, htmx, "HX-Request") == null) {
        @compileError("Vendored HTMX file does not contain request-header support");
    }
}

test "navigation indicator is positioned without changing header layout" {
    try std.testing.expect(std.mem.indexOf(
        u8,
        css,
        "header nav {\n  position: relative;",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        css,
        "#navigation-indicator { position: absolute;",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "left: 50%;") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        css,
        "top: 50%;",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        css,
        "transform: translate(-50%, -50%);",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "white-space: nowrap;") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "visibility: hidden;") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "opacity: 0;") != null);

    // Form-local indicators retain their existing display-based behavior.
    try std.testing.expect(std.mem.indexOf(
        u8,
        css,
        ".htmx-indicator { display: none;",
    ) != null);
}

test "orange favicon is embedded as SVG" {
    try std.testing.expect(std.mem.startsWith(u8, favicon, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, favicon, "#F47A1F") != null);
    try std.testing.expect(std.mem.indexOf(u8, favicon, "#477A45") != null);
}

test "editable properties override primary button presentation" {
    try std.testing.expect(std.mem.indexOf(
        u8,
        css,
        ".editable-property {",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        css,
        "background: transparent;",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "inset: 0;") == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        css,
        ".edit-icon {\n  position: absolute;",
    ) == null);
}
