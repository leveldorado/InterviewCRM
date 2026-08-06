const std = @import("std");
const processes = @import("processes.zig");
const view_models = @import("view_models.zig");
const dashboard_template = @import("templates/dashboard.zig");
const process_form_template = @import("templates/process_form.zig");
const process_detail_template = @import("templates/process_detail.zig");
const error_page_template = @import("templates/error_page.zig");

pub fn buildDashboard(
    allocator: std.mem.Allocator,
    stored_processes: []const processes.Process,
) !view_models.Dashboard {
    const summaries = try allocator.alloc(
        view_models.ProcessSummary,
        stored_processes.len,
    );
    for (stored_processes, summaries) |process, *summary| {
        summary.* = .{
            .detail_url = try std.fmt.allocPrint(
                allocator,
                "/processes/{d}",
                .{process.id},
            ),
            .company_name = process.input.company_name,
            .position_name = process.input.position_name,
            .status = process.status,
            .salary_display = try buildSalaryDisplay(allocator, process.input),
            .source = process.input.source,
            .updated_at = process.updated_at,
        };
    }
    return .{ .processes = summaries };
}

pub fn buildProcessForm(
    allocator: std.mem.Allocator,
    input: processes.Input,
    errors: processes.Errors,
    process_id: ?i64,
) !view_models.ProcessForm {
    const editing = process_id != null;
    const action = if (process_id) |id|
        try std.fmt.allocPrint(allocator, "/processes/{d}/edit", .{id})
    else
        "/processes";
    const cancel_url = if (process_id) |id|
        try std.fmt.allocPrint(allocator, "/processes/{d}", .{id})
    else
        "/";
    return .{
        .title = if (editing) "Edit process" else "Add job process",
        .action = action,
        .cancel_url = cancel_url,
        .input = input,
        .errors = errors,
        .salary_min_value = try salaryInputValue(
            allocator,
            input.salary_min_text,
            input.salary_min,
        ),
        .salary_max_value = try salaryInputValue(
            allocator,
            input.salary_max_text,
            input.salary_max,
        ),
    };
}

pub fn buildProcessDetail(
    allocator: std.mem.Allocator,
    process: processes.Process,
) !view_models.ProcessDetail {
    return .{
        .id = process.id,
        .title = process.input.company_name,
        .edit_url = try std.fmt.allocPrint(
            allocator,
            "/processes/{d}/edit",
            .{process.id},
        ),
        .company_name = process.input.company_name,
        .position_name = process.input.position_name,
        .status = process.status,
        .source = process.input.source,
        .location = process.input.location,
        .work_arrangement = process.input.work_arrangement,
        .salary_display = try buildSalaryDisplay(allocator, process.input),
        .salary_notes = process.input.salary_notes,
        .job_url = if (process.input.job_url.len > 0)
            process.input.job_url
        else
            null,
        .created_at = process.created_at,
        .updated_at = process.updated_at,
    };
}

pub fn buildSalaryDisplay(
    allocator: std.mem.Allocator,
    input: processes.Input,
) ![]const u8 {
    if (!input.salary_discussed) return "Not discussed";
    const has_no_range = input.salary_min == null and input.salary_max == null;
    if (has_no_range) return "Salary discussed; range not disclosed";

    var output: std.Io.Writer.Allocating = .init(allocator);
    if (input.currency.len > 0) {
        try output.writer.print("{s} ", .{input.currency});
    }
    if (input.salary_min) |minimum| try writeAmount(&output.writer, minimum);
    if (input.salary_min != null and input.salary_max != null) {
        try output.writer.writeAll("–");
    }
    if (input.salary_max) |maximum| try writeAmount(&output.writer, maximum);
    if (input.period.len > 0) {
        try output.writer.print(" per {s}", .{input.period});
    }
    try output.writer.print(", {s}", .{
        if (input.salary_type.len > 0) input.salary_type else "unknown type",
    });
    return output.toOwnedSlice();
}

fn writeAmount(writer: *std.Io.Writer, amount: i64) !void {
    var buffer: [32]u8 = undefined;
    const digits = try std.fmt.bufPrint(&buffer, "{d}", .{amount});
    for (digits, 0..) |digit, index| {
        const remaining = digits.len - index;
        try writer.writeByte(digit);
        if (remaining > 1 and (remaining - 1) % 3 == 0) {
            try writer.writeByte(',');
        }
    }
}

fn salaryInputValue(
    allocator: std.mem.Allocator,
    raw_value: []const u8,
    parsed_value: ?i64,
) ![]const u8 {
    if (raw_value.len > 0) return raw_value;
    if (parsed_value) |value| {
        return std.fmt.allocPrint(allocator, "{d}", .{value});
    }
    return "";
}

pub fn renderDashboardPage(
    writer: *std.Io.Writer,
    view: view_models.Dashboard,
) !void {
    try dashboard_template.DashboardPage.render(.{view}, writer);
}

pub fn renderProcessFormPage(
    writer: *std.Io.Writer,
    view: view_models.ProcessForm,
) !void {
    try process_form_template.ProcessFormPage.render(.{view}, writer);
}

pub fn renderProcessFormFragment(
    writer: *std.Io.Writer,
    view: view_models.ProcessForm,
) !void {
    try process_form_template.ProcessForm.render(.{view}, writer);
}

pub fn renderProcessDetailPage(
    writer: *std.Io.Writer,
    view: view_models.ProcessDetail,
) !void {
    try process_detail_template.ProcessDetailPage.render(.{view}, writer);
}

pub fn renderProcessDetailFragment(
    writer: *std.Io.Writer,
    view: view_models.ProcessDetail,
) !void {
    try process_detail_template.ProcessDetailContent.render(.{view}, writer);
}

pub fn renderErrorPage(
    writer: *std.Io.Writer,
    view: view_models.ErrorPage,
) !void {
    try error_page_template.ErrorPage.render(.{view}, writer);
}

test "layout and form contain HTMX behavior and escape user input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const view = try buildProcessForm(
        arena.allocator(),
        .{
            .company_name = "<script>alert(\"x\")</script>",
            .salary_min_text = "12x",
        },
        .{ .salary_min = "Enter a whole number." },
        null,
    );
    try renderProcessFormPage(&output.writer, view);
    const html = output.written();
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"main-content\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "/static/app.css") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "/static/vendor/htmx.min.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "&lt;script&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<script>alert") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "hx-post=\"/processes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "value=\"12x\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "&quot;422&quot;") != null);
}

test "edit form uses one prepared action for HTML and HTMX" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const view = try buildProcessForm(
        arena.allocator(),
        .{},
        .{},
        42,
    );
    try renderProcessFormFragment(&output.writer, view);
    const html = output.written();
    try std.testing.expect(std.mem.indexOf(
        u8,
        html,
        "action=\"/processes/42/edit\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        html,
        "hx-post=\"/processes/42/edit\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<!DOCTYPE html>") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<html") == null);
}

test "full and fragment process views remain structurally distinct" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const process = processes.Process{
        .id = 7,
        .input = .{
            .company_name = "Acme & Sons",
            .position_name = "Engineer",
            .salary_discussed = true,
            .salary_min = 5500,
            .salary_max = 6500,
            .currency = "EUR",
            .period = "month",
            .salary_type = "gross",
        },
        .status = "active",
        .created_at = "today",
        .updated_at = "today",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const view = try buildProcessDetail(arena.allocator(), process);
    try renderProcessDetailFragment(&output.writer, view);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output.written(),
        "EUR 5,500–6,500 per month, gross",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output.written(),
        "Acme &amp; Sons",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output.written(),
        "<!DOCTYPE html>",
    ) == null);
}
