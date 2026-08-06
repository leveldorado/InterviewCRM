const std = @import("std");
const p = @import("processes.zig");
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
pub fn escape(w: anytype, s: []const u8) !void {
    for (s) |ch| switch (ch) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '\"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&#39;"),
        else => try w.writeByte(ch),
    };
}
fn top(w: anytype, title: []const u8) !void {
    try w.writeAll("<!doctype html><html lang=en><head><meta charset=utf-8><meta name=viewport content=\"width=device-width,initial-scale=1\"><title>");
    try escape(w, title);
    try w.writeAll(" · Interview CRM</title><link rel=stylesheet href=/static/app.css><script defer src=/static/vendor/htmx.min.js></script></head><body><header><nav><a href=/><strong>Interview CRM</strong></a><a class=button href=/processes/new>Add job process</a></nav></header><main>");
}
fn bottom(w: anytype) !void {
    try w.writeAll("</main></body></html>");
}
pub fn errorPage(w: anytype, status: []const u8, message: []const u8) !void {
    try top(w, status);
    try w.print("<div class=panel><h1>{s}</h1><p>", .{status});
    try escape(w, message);
    try w.writeAll("</p><a href=/>Back to dashboard</a></div>");
    try bottom(w);
}
pub fn dashboard(w: anytype, items: []const p.Process) !void {
    try top(w, "Dashboard");
    try w.writeAll("<div class=actions><h1>Dashboard</h1></div><div class=grid><section class=panel><h2>Today</h2><p class=empty>Today appointment tracking will be added in a later release.</p></section><section class=panel><h2>This week</h2><p class=empty>This-week appointment tracking will be added in a later release.</p></section></div><section class=panel><h2>Needs attention</h2><p class=empty>Needs-attention tracking will be added in a later release.</p></section><section class=panel><h2>Active processes</h2>");
    if (items.len == 0) try w.writeAll("<p class=empty>No active processes yet. Add one to begin tracking your search.</p>") else {
        try w.writeAll("<div class=table-wrap><table><thead><tr><th>Company</th><th>Position</th><th>Status</th><th>Salary</th><th>Source</th><th>Last updated</th></tr></thead><tbody>");
        for (items) |x| {
            try w.print("<tr><td><a href=/processes/{d}>", .{x.id});
            try escape(w, x.input.company_name);
            try w.writeAll("</a></td><td>");
            try escape(w, x.input.position_name);
            try w.writeAll("</td><td><span class=badge>");
            try escape(w, x.status);
            try w.writeAll("</span></td><td>");
            try salary(w, x.input);
            try w.writeAll("</td><td>");
            try escape(w, x.input.source);
            try w.writeAll("</td><td>");
            try escape(w, x.updated_at);
            try w.writeAll("</td></tr>");
        }
        try w.writeAll("</tbody></table></div>");
    }
    try w.writeAll("</section>");
    try bottom(w);
}
pub const SalaryDisplay = struct {
    discussed: bool,
    minimum: ?i64,
    maximum: ?i64,
    currency: ?[]const u8,
    period: ?[]const u8,
    salary_type: ?[]const u8,
};

fn salary(w: anytype, input: p.Input) !void {
    return renderSalary(w, .{
        .discussed = input.salary_discussed,
        .minimum = input.salary_min,
        .maximum = input.salary_max,
        .currency = nonEmpty(input.currency),
        .period = nonEmpty(input.period),
        .salary_type = nonEmpty(input.salary_type),
    });
}

pub fn renderSalary(w: anytype, display: SalaryDisplay) !void {
    if (!display.discussed) return w.writeAll("Not discussed");
    if (display.minimum == null and display.maximum == null) {
        return w.writeAll("Salary discussed; range not disclosed");
    }
    if (display.currency) |currency| {
        try escape(w, currency);
        try w.writeByte(' ');
    }
    if (display.minimum) |minimum| try money(w, minimum);
    if (display.minimum != null and display.maximum != null) try w.writeAll("–");
    if (display.maximum) |maximum| try money(w, maximum);
    if (display.period) |period| {
        try w.writeAll(" per ");
        try escape(w, period);
    }
    try w.writeAll(", ");
    try escape(w, display.salary_type orelse "unknown type");
}

fn nonEmpty(value: []const u8) ?[]const u8 {
    return if (value.len == 0) null else value;
}

fn money(w: anytype, value: i64) !void {
    var buffer: [32]u8 = undefined;
    const digits = try std.fmt.bufPrint(&buffer, "{d}", .{value});
    for (digits, 0..) |digit, index| {
        const remaining = digits.len - index;
        try w.writeByte(digit);
        if (remaining > 1 and (remaining - 1) % 3 == 0) try w.writeByte(',');
    }
}
pub fn detail(w: anytype, x: p.Process) !void {
    try top(w, x.input.company_name);
    try w.print("<div class=actions><a class=secondary href=/>← Dashboard</a><a class=button href=/processes/{d}/edit>Edit process</a></div><section class=panel><h1>", .{x.id});
    try escape(w, x.input.company_name);
    try w.writeAll("</h1><h2>");
    try escape(w, x.input.position_name);
    try w.writeAll("</h2><dl class=facts>");
    const LabelValue = struct {
        label: []const u8,
        value: []const u8,
    };
    const labels = [_]LabelValue{
        .{ .label = "Status", .value = x.status },
        .{ .label = "Source", .value = x.input.source },
        .{ .label = "Location", .value = x.input.location },
        .{ .label = "Work arrangement", .value = x.input.work_arrangement },
        .{ .label = "Salary notes", .value = x.input.salary_notes },
        .{ .label = "Created", .value = x.created_at },
        .{ .label = "Last updated", .value = x.updated_at },
    };
    for (labels) |v| {
        try w.print("<dt>{s}</dt><dd>", .{v.label});
        try escape(w, if (v.value.len > 0) v.value else "—");
        try w.writeAll("</dd>");
    }
    try w.writeAll("<dt>Salary</dt><dd>");
    try salary(w, x.input);
    try w.writeAll("</dd><dt>Job URL</dt><dd>");
    if (x.input.job_url.len > 0) {
        try w.writeAll("<a rel=noopener href=\"");
        try escape(w, x.input.job_url);
        try w.writeAll("\">");
        try escape(w, x.input.job_url);
        try w.writeAll("</a>");
    } else try w.writeAll("—");
    try w.writeAll("</dd></dl></section>");
    for ([_][]const u8{ "Stage timeline", "Notes", "Appointment list" }) |name| {
        try w.print(
            "<section class=panel><h2>{s}</h2><p class=empty>{s} will be added in a later release.</p></section>",
            .{ name, name },
        );
    }
    try bottom(w);
}
fn field(w: anytype, name: []const u8, label: []const u8, value: []const u8, err: ?[]const u8, kind: []const u8) !void {
    try w.print("<div class=field><label for={s}>{s}</label><input id={s} name={s} type={s} value=\"", .{ name, label, name, name, kind });
    try escape(w, value);
    try w.writeByte('"');
    if (err) |e| {
        try w.print(" aria-describedby={s}-error class=field-error><div id={s}-error class=error>", .{ name, name });
        try escape(w, e);
        try w.writeAll("</div>");
    } else try w.writeByte('>');
    try w.writeAll("</div>");
}

fn salaryField(
    w: anytype,
    name: []const u8,
    label: []const u8,
    value: []const u8,
    validation_error: ?[]const u8,
) !void {
    try w.print(
        "<div class=field><label for={s}>{s}</label><input id={s} name={s} type=text inputmode=numeric value=\"",
        .{ name, label, name, name },
    );
    try escape(w, value);
    try w.writeByte('"');
    if (validation_error) |message| {
        try w.print(
            " aria-describedby={s}-error class=field-error><div id={s}-error class=error>",
            .{ name, name },
        );
        try escape(w, message);
        try w.writeAll("</div>");
    } else try w.writeByte('>');
    try w.writeAll("</div>");
}
pub fn form(w: anytype, input: p.Input, errs: p.Errors, id: ?i64, fragment: bool) !void {
    if (!fragment) try top(w, if (id == null) "Add job process" else "Edit process");
    try w.writeAll("<section id=process-form class=panel><h1>");
    try w.writeAll(if (id == null) "Add job process" else "Edit process");
    try w.writeAll("</h1><form method=post hx-target=#process-form hx-swap=outerHTML action=");
    if (id) |v| try w.print("/processes/{d}/edit", .{v}) else try w.writeAll("/processes");
    try w.writeAll(">");
    try field(w, "company_name", "Company name", input.company_name, errs.company, "text");
    try field(w, "position_name", "Position name", input.position_name, errs.position, "text");
    try field(w, "job_url", "Job URL", input.job_url, errs.url, "url");
    try field(w, "source", "Source", input.source, null, "text");
    try field(w, "location", "Location", input.location, null, "text");
    try field(w, "work_arrangement", "Work arrangement", input.work_arrangement, null, "text");
    try w.writeAll("<div class=field><label class=check><input name=salary_discussed type=checkbox value=1");
    if (input.salary_discussed) try w.writeAll(" checked");
    try w.writeAll("> Salary discussed</label></div>");
    var min: [32]u8 = undefined;
    var max: [32]u8 = undefined;
    const min_value = if (input.salary_min_text.len > 0) input.salary_min_text else if (input.salary_min) |v| try std.fmt.bufPrint(&min, "{d}", .{v}) else "";
    const max_value = if (input.salary_max_text.len > 0) input.salary_max_text else if (input.salary_max) |v| try std.fmt.bufPrint(&max, "{d}", .{v}) else "";
    try salaryField(w, "salary_min", "Minimum salary", min_value, errs.salary_min);
    try salaryField(w, "salary_max", "Maximum salary", max_value, errs.salary_max);
    try field(w, "currency", "Currency code", input.currency, null, "text");
    try field(w, "period", "Salary period", input.period, null, "text");
    try field(w, "salary_type", "Salary type", input.salary_type, null, "text");
    try w.writeAll("<div class=field><label for=salary_notes>Salary notes</label><textarea id=salary_notes name=salary_notes rows=4>");
    try escape(w, input.salary_notes);
    try w.writeAll("</textarea></div><div class=actions><button type=submit>Save process</button><a class=secondary href=/ >Cancel</a></div></form></section>");
    if (!fragment) try bottom(w);
}
test "escapes HTML" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try escape(&out.writer, "<script>&\"");
    try std.testing.expectEqualStrings("&lt;script&gt;&amp;&quot;", out.written());
}

test "salary display includes complete stored information without empty separators" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try renderSalary(&output.writer, .{
        .discussed = true,
        .minimum = 5500,
        .maximum = 6500,
        .currency = "EUR",
        .period = "month",
        .salary_type = "gross",
    });
    try std.testing.expectEqualStrings(
        "EUR 5,500–6,500 per month, gross",
        output.written(),
    );
}

test "salary form preserves invalid raw text in text inputs" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try form(&output.writer, .{
        .salary_min_text = "12x",
        .salary_max_text = "wrong",
    }, .{
        .salary_min = "Enter a whole number.",
        .salary_max = "Enter a whole number.",
    }, null, true);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output.written(),
        "name=salary_min type=text inputmode=numeric value=\"12x\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output.written(),
        "name=salary_max type=text inputmode=numeric value=\"wrong\"",
    ) != null);
}
