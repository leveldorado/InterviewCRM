const std = @import("std");

pub const css = @embedFile("assets/app.css");
pub const htmx = @embedFile("assets/vendor/htmx.min.js");

comptime {
    @setEvalBranchQuota(100_000);
    if (htmx.len < 40_000) {
        @compileError("Vendored HTMX file appears incomplete");
    }
    if (std.mem.indexOf(u8, htmx, "HX-Request") == null) {
        @compileError("Vendored HTMX file does not contain request-header support");
    }
}
