const std = @import("std");
const appointments = @import("appointments.zig");
const db = @import("database.zig");
const notes = @import("notes.zig");
const migrations = @import("migrations.zig");
const processes = @import("processes.zig");
const stages = @import("stages.zig");
const view_models = @import("view_models.zig");
const dashboard_template = @import("templates/dashboard.zig");
const process_form_template = @import("templates/process_form.zig");
const process_detail_template = @import("templates/process_detail.zig");
const error_page_template = @import("templates/error_page.zig");
const stage_card_template = @import("templates/stage_card.zig");
const stage_timeline_template = @import("templates/stage_timeline.zig");

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
    return .{
        .processes = summaries,
    };
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
    database: *db.Database,
    process: processes.Process,
    form_state: view_models.TimelineFormState,
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
        .timeline = try buildStageTimelineView(
            allocator,
            database,
            process.id,
            process.current_stage_id,
            form_state,
        ),
    };
}

pub fn buildStageTimelineView(
    allocator: std.mem.Allocator,
    database: *db.Database,
    process_id: i64,
    current_stage_id: ?i64,
    form_state: view_models.TimelineFormState,
) !view_models.StageTimeline {
    const stored_stages = try stages.listForProcess(
        allocator,
        database,
        process_id,
    );
    const stage_views = try allocator.alloc(
        view_models.Stage,
        stored_stages.len,
    );
    for (stored_stages, stage_views) |stage, *stage_view| {
        stage_view.* = try buildStageCardView(
            allocator,
            database,
            stage,
            current_stage_id,
            form_state,
        );
    }
    return .{
        .process_id = process_id,
        .current_stage_id = current_stage_id,
        .stages = stage_views,
        .add_stage_action = try std.fmt.allocPrint(
            allocator,
            "/processes/{d}/stages",
            .{process_id},
        ),
        .add_stage = form_state.add_stage,
    };
}

pub fn buildStageCardView(
    allocator: std.mem.Allocator,
    database: *db.Database,
    stage: stages.Stage,
    current_stage_id: ?i64,
    form_state: view_models.TimelineFormState,
) !view_models.Stage {
    const stored_notes = try notes.listForStage(
        allocator,
        database,
        stage.process_id,
        stage.id,
    );
    const note_views = try allocator.alloc(
        view_models.StageNote,
        stored_notes.len,
    );
    for (stored_notes, note_views) |note, *note_view| {
        note_view.* = .{
            .id = note.id,
            .body = note.body,
            .edit_action = try actionUrl(allocator, "notes", note.id, "edit"),
            .delete_action = try actionUrl(allocator, "notes", note.id, "delete"),
        };
    }

    const stored_appointments = try appointments.listForStage(
        allocator,
        database,
        stage.process_id,
        stage.id,
    );
    const appointment_views = try allocator.alloc(
        view_models.StageAppointment,
        stored_appointments.len,
    );
    for (stored_appointments, appointment_views) |appointment, *appointment_view| {
        appointment_view.* = .{
            .id = appointment.id,
            .title = appointment.title,
            .time_display = try appointmentTimeDisplay(
                allocator,
                appointment.starts_at,
            ),
            .meeting_url = appointment.meeting_url,
            .contact_name = appointment.contact_name,
            .location = appointment.location,
            .preparation_note = appointment.preparation_note,
            .status = appointments.statusText(appointment.status),
            .status_label = appointmentStatusLabel(appointment.status),
            .can_cancel = appointment.status != .cancelled,
            .cancel_action = try actionUrl(
                allocator,
                "appointments",
                appointment.id,
                "cancel",
            ),
        };
    }

    const is_form_stage = form_state.stage_id == stage.id;
    const note_form: view_models.NoteForm = if (is_form_stage)
        form_state.note
    else
        .{};
    const appointment_form = if (is_form_stage)
        form_state.appointment
    else
        view_models.AppointmentForm{
            .input = .{ .title = stage.name },
        };
    const is_current = current_stage_id == stage.id;
    const article_id = try std.fmt.allocPrint(allocator, "stage-{d}", .{stage.id});
    return .{
        .id = stage.id,
        .article_id = article_id,
        .target_id = try std.fmt.allocPrint(allocator, "#{s}", .{article_id}),
        .name = stage.name,
        .position = stage.position,
        .status = stages.statusText(stage.status),
        .status_label = stageStatusLabel(stage.status),
        .marker = stageMarker(stage.status, is_current),
        .state_class = stageStateClass(stage.status, is_current),
        .is_current = is_current,
        .can_complete = is_current and
            (stage.status == .in_progress or stage.status == .scheduled),
        .can_skip = stage.status == .planned or
            (is_current and
                (stage.status == .in_progress or stage.status == .scheduled)),
        .can_reopen = stage.status == .completed or stage.status == .skipped,
        .complete_action = try actionUrl(allocator, "stages", stage.id, "complete"),
        .skip_action = try actionUrl(allocator, "stages", stage.id, "skip"),
        .reopen_action = try actionUrl(allocator, "stages", stage.id, "reopen"),
        .add_note_action = try actionUrl(allocator, "stages", stage.id, "notes"),
        .schedule_action = try actionUrl(
            allocator,
            "stages",
            stage.id,
            "appointments",
        ),
        .notes = note_views,
        .appointments = appointment_views,
        .note_form = note_form,
        .appointment_form = appointment_form,
    };
}

fn actionUrl(
    allocator: std.mem.Allocator,
    resource: []const u8,
    id: i64,
    action: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "/{s}/{d}/{s}",
        .{ resource, id, action },
    );
}

fn stageStatusLabel(status: stages.Status) []const u8 {
    return switch (status) {
        .planned => "Planned",
        .scheduled => "Scheduled",
        .in_progress => "In progress",
        .completed => "Completed",
        .skipped => "Skipped",
        .cancelled => "Cancelled",
    };
}

fn stageMarker(status: stages.Status, is_current: bool) []const u8 {
    return switch (status) {
        .completed => "✓",
        .skipped, .cancelled => "–",
        else => if (is_current) "●" else "○",
    };
}

fn stageStateClass(status: stages.Status, is_current: bool) []const u8 {
    if (is_current) return "stage-card current-stage";
    return switch (status) {
        .completed => "stage-card completed-stage",
        .skipped => "stage-card skipped-stage",
        .scheduled => "stage-card scheduled-stage",
        else => "stage-card",
    };
}

fn appointmentStatusLabel(status: appointments.Status) []const u8 {
    return switch (status) {
        .scheduled => "Scheduled",
        .completed => "Completed",
        .cancelled => "Cancelled",
    };
}

fn appointmentTimeDisplay(
    allocator: std.mem.Allocator,
    value: []const u8,
) ![]const u8 {
    if (value.len != 16) return allocator.dupe(u8, value);
    const month_number = std.fmt.parseInt(usize, value[5..7], 10) catch
        return allocator.dupe(u8, value);
    const months = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };
    if (month_number == 0 or month_number > months.len) {
        return allocator.dupe(u8, value);
    }
    return std.fmt.allocPrint(
        allocator,
        "{d} {s} {s} · {s}",
        .{
            try std.fmt.parseInt(u8, value[8..10], 10),
            months[month_number - 1],
            value[0..4],
            value[11..16],
        },
    );
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

pub fn renderDashboardFragment(
    writer: *std.Io.Writer,
    view: view_models.Dashboard,
) !void {
    try dashboard_template.DashboardFragment.render(.{view}, writer);
}

pub fn renderProcessFormPage(
    writer: *std.Io.Writer,
    view: view_models.ProcessForm,
) !void {
    try process_form_template.ProcessFormPage.render(.{view}, writer);
}

pub fn renderProcessFormNavigationFragment(
    writer: *std.Io.Writer,
    view: view_models.ProcessForm,
) !void {
    try process_form_template.ProcessFormFragment.render(.{view}, writer);
}

pub fn renderProcessFormValidationFragment(
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
    try process_detail_template.ProcessDetailFragment.render(.{view}, writer);
}

pub fn renderStageTimelineFragment(
    writer: *std.Io.Writer,
    view: view_models.StageTimeline,
) !void {
    try stage_timeline_template.StageTimeline.render(.{view}, writer);
}

pub fn renderStageCardFragment(
    writer: *std.Io.Writer,
    view: view_models.Stage,
) !void {
    try stage_card_template.StageCard.render(.{view}, writer);
}

pub fn renderErrorPage(
    writer: *std.Io.Writer,
    view: view_models.ErrorPage,
) !void {
    try error_page_template.ErrorPage.render(.{view}, writer);
}

pub fn renderErrorFragment(
    writer: *std.Io.Writer,
    view: view_models.ErrorPage,
) !void {
    try error_page_template.ErrorFragment.render(.{view}, writer);
}

fn expectSingleTitleOutsideMain(html: []const u8) !void {
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, html, "<title>"),
    );
    const title_index = std.mem.indexOf(u8, html, "<title>").?;
    const main_index = std.mem.indexOf(u8, html, "<main").?;
    const main_end_index = std.mem.indexOf(u8, html, "</main>").?;
    try std.testing.expect(title_index < main_index);
    try std.testing.expect(std.mem.indexOf(
        u8,
        html[main_index..main_end_index],
        "<title>",
    ) == null);
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
        .{
            .salary_min = "Enter a whole number.",
        },
        null,
    );
    try renderProcessFormPage(&output.writer, view);
    const html = output.written();
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"main-content\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "hx-boost=\"true\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "hx-target=\"#main-content\"") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        html,
        "hx-swap=\"innerHTML show:window:top\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        html,
        "id=\"navigation-indicator\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "/static/app.css") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "/static/vendor/htmx.min.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "&lt;script&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<script>alert") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "hx-post=\"/processes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "value=\"12x\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "&quot;422&quot;") != null);
}

test "dashboard page and navigation fragment preserve links and title" {
    const summaries = [_]view_models.ProcessSummary{
        .{
            .detail_url = "/processes/9",
            .company_name = "Acme",
            .position_name = "Engineer",
            .status = "active",
            .salary_display = "Not discussed",
            .source = "Referral",
            .updated_at = "today",
        },
    };
    const view = view_models.Dashboard{
        .processes = &summaries,
    };
    var page_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer page_output.deinit();
    try renderDashboardPage(&page_output.writer, view);
    try std.testing.expect(std.mem.indexOf(
        u8,
        page_output.written(),
        "<!DOCTYPE html>",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        page_output.written(),
        "href=\"/processes/9\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        page_output.written(),
        "href=\"/processes/new\"",
    ) != null);

    var fragment_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer fragment_output.deinit();
    try renderDashboardFragment(&fragment_output.writer, view);
    const fragment = fragment_output.written();
    try std.testing.expect(std.mem.indexOf(
        u8,
        fragment,
        "<title>Dashboard · Interview CRM</title>",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, fragment, "<h1>Dashboard</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, fragment, "<!DOCTYPE html>") == null);
    try std.testing.expect(std.mem.indexOf(u8, fragment, "<main") == null);
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
    try renderProcessFormValidationFragment(&output.writer, view);
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
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"/processes/42\"") != null);

    var navigation_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer navigation_output.deinit();
    try renderProcessFormNavigationFragment(&navigation_output.writer, view);
    try std.testing.expect(std.mem.indexOf(
        u8,
        navigation_output.written(),
        "<title>Edit process · Interview CRM</title>",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        navigation_output.written(),
        "<html",
    ) == null);
}

test "full and fragment process views remain structurally distinct" {
    var database = try db.Database.open(":memory:");
    defer database.close();
    try migrations.apply(&database);
    var process = processes.Process{
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
            .job_url = "https://example.com/job?a=1&b=2",
        },
        .status = "active",
        .created_at = "today",
        .updated_at = "today",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var insert_process = try database.prepare(
        "INSERT INTO job_processes(id,company_name,position_name,created_at,updated_at) VALUES(7,'Acme & Sons','Engineer',datetime('now'),datetime('now'))",
    );
    defer insert_process.deinit();
    _ = try insert_process.step();
    try database.begin();
    const first_stage_id = try stages.createDefaults(&database, process.id);
    try database.commit();
    _ = try notes.createForStage(
        &database,
        process.id,
        first_stage_id,
        .{ .body = "<script>alert(1)</script>\nPrepare examples" },
    );
    process.current_stage_id = first_stage_id;
    const view = try buildProcessDetail(
        arena.allocator(),
        &database,
        process,
        .{},
    );

    var page_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer page_output.deinit();
    try renderProcessDetailPage(&page_output.writer, view);
    try expectSingleTitleOutsideMain(page_output.written());

    var fragment_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer fragment_output.deinit();
    try renderProcessDetailFragment(&fragment_output.writer, view);
    const fragment = fragment_output.written();
    try std.testing.expect(std.mem.indexOf(
        u8,
        fragment,
        "<title>Acme &amp; Sons · Interview CRM</title>",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        fragment,
        "EUR 5,500–6,500 per month, gross",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        fragment,
        "Acme &amp; Sons",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        fragment,
        "<!DOCTYPE html>",
    ) == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        fragment,
        "hx-boost=\"false\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        fragment,
        "rel=\"noopener noreferrer\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        fragment,
        "id=\"stage-timeline\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, fragment, "id=\"stage-1\"") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        fragment,
        "hx-target=\"#stage-timeline\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        fragment,
        "hx-target=\"#stage-1\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        fragment,
        "&lt;script&gt;alert(1)&lt;/script&gt;",
    ) != null);
}

test "error page and fragment are distinct navigable representations" {
    const view = view_models.ErrorPage{
        .title = "Not found",
        .message = "Missing",
    };
    var page_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer page_output.deinit();
    try renderErrorPage(&page_output.writer, view);
    try expectSingleTitleOutsideMain(page_output.written());
    try std.testing.expect(std.mem.indexOf(
        u8,
        page_output.written(),
        "<!DOCTYPE html>",
    ) != null);

    var fragment_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer fragment_output.deinit();
    try renderErrorFragment(&fragment_output.writer, view);
    const fragment = fragment_output.written();
    try std.testing.expect(std.mem.indexOf(
        u8,
        fragment,
        "<title>Not found · Interview CRM</title>",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, fragment, "href=\"/\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fragment, "<html") == null);
}
