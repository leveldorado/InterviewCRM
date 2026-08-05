const std = @import("std");
const p = @import("processes.zig");
pub const css = @embedFile("assets/app.css");
pub const htmx = @embedFile("assets/vendor/htmx.min.js");
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
    try w.writeAll("<div class=actions><h1>Dashboard</h1></div><div class=grid><section class=panel><h2>Today</h2><p class=empty>Appointment dashboard queries are not implemented yet.</p></section><section class=panel><h2>This week</h2><p class=empty>Appointment dashboard queries are not implemented yet.</p></section></div><section class=panel><h2>Needs attention</h2><p class=empty>No processes currently need attention.</p></section><section class=panel><h2>Active processes</h2>");
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
fn salary(w: anytype, i: p.Input) !void {
    if (!i.salary_discussed) return w.writeAll("Not discussed");
    if (i.salary_min == null and i.salary_max == null) return w.writeAll("Discussed");
    if (i.currency.len > 0) {
        try escape(w, i.currency);
        try w.writeByte(' ');
    }
    if (i.salary_min) |v| try money(w, v);
    if (i.salary_min != null and i.salary_max != null) try w.writeAll("–");
    if (i.salary_max) |v| try money(w, v);
    if (i.period.len > 0) {
        try w.writeAll(" / ");
        try escape(w, i.period);
    }
}
fn money(w: anytype, v: i64) !void {
    const cents = @mod(v, 100);
    try w.print("{d}.", .{@divTrunc(v, 100)});
    if (cents < 10) try w.writeByte('0');
    try w.print("{d}", .{cents});
}
pub fn detail(w: anytype, x: p.Process) !void {
    try top(w, x.input.company_name);
    try w.print("<div class=actions><a class=secondary href=/>← Dashboard</a><a class=button href=/processes/{d}/edit>Edit process</a></div><section class=panel><h1>", .{x.id});
    try escape(w, x.input.company_name);
    try w.writeAll("</h1><h2>");
    try escape(w, x.input.position_name);
    try w.writeAll("</h2><dl class=facts>");
    const labels = [_]struct { []const u8, []const u8 }{ .{ "Status", x.status }, .{ "Source", x.input.source }, .{ "Location", x.input.location }, .{ "Work arrangement", x.input.work_arrangement }, .{ "Salary notes", x.input.salary_notes }, .{ "Created", x.created_at }, .{ "Last updated", x.updated_at } };
    for (labels) |v| {
        try w.print("<dt>{s}</dt><dd>", .{v[0]});
        try escape(w, if (v[1].len > 0) v[1] else "—");
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
    for ([_][]const u8{ "Stages", "Notes", "Appointments" }) |name| try w.print("<section class=panel><h2>{s}</h2><p class=empty>No {s} yet.</p></section>", .{ name, name });
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
    try field(w, "salary_min", "Minimum salary (smallest currency unit)", min_value, errs.salary_min, "number");
    try field(w, "salary_max", "Maximum salary (smallest currency unit)", max_value, errs.salary_max, "number");
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
