const std = @import("std");
const appointments = @import("appointments.zig");
const compensations = @import("compensations.zig");
const db = @import("database.zig");
const migrations = @import("migrations.zig");
const notes = @import("notes.zig");
const processes = @import("processes.zig");
const questions = @import("questions.zig");
const sources = @import("sources.zig");
const stages = @import("stages.zig");
const view_models = @import("view_models.zig");
const company_questions_template = @import("templates/company_questions.zig");
const compensation_template = @import("templates/compensation.zig");
const dashboard_template = @import("templates/dashboard.zig");
const error_page_template = @import("templates/error_page.zig");
const process_detail_template = @import("templates/process_detail.zig");
const process_form_template = @import("templates/process_form.zig");
const source_field_template = @import("templates/source_field.zig");
const stage_card_template = @import("templates/stage_card.zig");
const stage_timeline_template = @import("templates/stage_timeline.zig");

pub fn buildDashboard(
    allocator: std.mem.Allocator,
    database: *db.Database,
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
            .current_stage = try currentStageName(
                allocator,
                database,
                process.current_stage_id,
            ),
            .source = process.input.source_name,
            .interest = try ratingDisplay(allocator, process.input.interest_rating, "★"),
            .money = try ratingDisplay(allocator, process.input.money_rating, "$"),
            .growth = try ratingDisplay(allocator, process.input.growth_rating, "★"),
            .applied_at = process.input.applied_at,
            .updated_at = process.updated_at,
        };
    }
    return .{ .processes = summaries };
}

pub fn buildProcessForm(
    allocator: std.mem.Allocator,
    database: *db.Database,
    input: processes.Input,
    errors: processes.Errors,
    process_id: ?i64,
) !view_models.ProcessForm {
    const editing = process_id != null;
    return .{
        .title = if (editing) "Edit process" else "Add job process",
        .action = if (process_id) |id|
            try std.fmt.allocPrint(allocator, "/processes/{d}/edit", .{id})
        else
            "/processes",
        .cancel_url = if (process_id) |id|
            try std.fmt.allocPrint(allocator, "/processes/{d}", .{id})
        else
            "/",
        .input = input,
        .errors = errors,
        .source_field = try buildSourceField(
            allocator,
            database,
            input.source_id,
            "",
            null,
        ),
        .is_editing = editing,
    };
}

pub fn buildSourceField(
    allocator: std.mem.Allocator,
    database: *db.Database,
    selected_id: ?i64,
    new_source: []const u8,
    error_message: ?[]const u8,
) !view_models.SourceField {
    const stored = try sources.list(allocator, database);
    const options = try allocator.alloc(view_models.SourceOption, stored.len);
    for (stored, options) |source, *option| {
        option.* = .{
            .id = source.id,
            .id_value = try std.fmt.allocPrint(allocator, "{d}", .{source.id}),
            .name = source.name,
            .selected = selected_id == source.id,
        };
    }
    return .{
        .options = options,
        .new_source = new_source,
        .error_message = error_message,
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
        .delete_url = try std.fmt.allocPrint(
            allocator,
            "/processes/{d}/delete",
            .{process.id},
        ),
        .company_name = process.input.company_name,
        .position_name = process.input.position_name,
        .status = process.status,
        .source = process.input.source_name,
        .location = process.input.location,
        .work_arrangement = process.input.work_arrangement,
        .company_summary = try buildCompanySummarySection(
            allocator,
            process.id,
            process.input.company_summary,
            false,
            null,
        ),
        .applied_at = process.input.applied_at,
        .interest = try ratingDisplay(allocator, process.input.interest_rating, "★"),
        .money = try ratingDisplay(allocator, process.input.money_rating, "$"),
        .growth = try ratingDisplay(allocator, process.input.growth_rating, "★"),
        .job_url = if (process.input.job_url.len > 0)
            process.input.job_url
        else
            null,
        .updated_at = process.updated_at,
        .compensation = try buildCompensationSection(
            allocator,
            database,
            process.id,
            null,
            .{},
        ),
        .ratings = try buildRatingsSection(allocator, process, .{}, false),
        .timeline = try buildStageTimelineView(
            allocator,
            database,
            process.id,
            process.current_stage_id,
            form_state,
        ),
        .company_questions = try buildQuestionSection(
            allocator,
            database,
            process.id,
            null,
            .company,
            .{},
        ),
    };
}

pub fn buildRatingsSection(
    allocator: std.mem.Allocator,
    process: processes.Process,
    errors: processes.Errors,
    editing: bool,
) !view_models.RatingsSection {
    return .{
        .action = try std.fmt.allocPrint(
            allocator,
            "/processes/{d}/ratings",
            .{process.id},
        ),
        .edit_url = try std.fmt.allocPrint(
            allocator,
            "/processes/{d}/ratings/edit",
            .{process.id},
        ),
        .editing = editing,
        .interest = try ratingLabel(allocator, process.input.interest_rating),
        .money = try ratingLabel(allocator, process.input.money_rating),
        .growth = try ratingLabel(allocator, process.input.growth_rating),
        .interest_value = try optionalIntValue(
            allocator,
            process.input.interest_rating,
        ),
        .money_value = try optionalIntValue(
            allocator,
            process.input.money_rating,
        ),
        .growth_value = try optionalIntValue(
            allocator,
            process.input.growth_rating,
        ),
        .errors = errors,
    };
}

pub fn buildCompanySummarySection(
    allocator: std.mem.Allocator,
    process_id: i64,
    summary: []const u8,
    editing: bool,
    error_message: ?[]const u8,
) !view_models.CompanySummarySection {
    const action = try std.fmt.allocPrint(
        allocator,
        "/processes/{d}/company-summary",
        .{process_id},
    );
    return .{
        .action = action,
        .edit_url = try std.fmt.allocPrint(
            allocator,
            "/processes/{d}/company-summary/edit",
            .{process_id},
        ),
        .summary = summary,
        .editing = editing,
        .error_message = error_message,
    };
}

pub fn buildCompensationSection(
    allocator: std.mem.Allocator,
    database: *db.Database,
    process_id: i64,
    error_kind: ?compensations.Kind,
    submitted: compensations.Input,
) !view_models.CompensationSection {
    const kinds = [_]compensations.Kind{ .advertised, .discussed, .offer };
    const snapshots = try allocator.alloc(
        view_models.CompensationSnapshot,
        kinds.len,
    );
    for (kinds, snapshots) |kind, *snapshot| {
        const stored = try compensations.getForProcess(
            allocator,
            database,
            process_id,
            kind,
        );
        var input = if (stored) |value| compensationInput(value) else compensations.Input{ .process_id = process_id, .kind = kind };
        var errors = compensations.Errors{};
        if (error_kind == kind) {
            input = submitted;
            errors = compensations.validate(submitted);
        }
        snapshot.* = .{
            .region_id = try std.fmt.allocPrint(allocator, "compensation-{s}", .{compensations.kindText(kind)}),
            .target_id = try std.fmt.allocPrint(allocator, "#compensation-{s}", .{compensations.kindText(kind)}),
            .edit_action = try std.fmt.allocPrint(allocator, "/processes/{d}/compensations/{s}/edit", .{ process_id, compensations.kindText(kind) }),
            .kind = compensations.kindText(kind),
            .label = switch (kind) {
                .advertised => "Advertised",
                .discussed => "Discussed",
                .offer => "Offer",
            },
            .display = if (stored) |value|
                try compensationDisplay(allocator, value)
            else if (kind == .offer)
                "Not received"
            else
                "Not recorded",
            .notes = if (stored) |value| value.notes else null,
            .action = try std.fmt.allocPrint(
                allocator,
                "/processes/{d}/compensations/{s}",
                .{ process_id, compensations.kindText(kind) },
            ),
            .form = try buildCompensationForm(allocator, input, errors),
            .show_confirmed = kind == .discussed,
        };
    }
    return .{ .snapshots = snapshots };
}

pub fn buildStageTimelineView(
    allocator: std.mem.Allocator,
    database: *db.Database,
    process_id: i64,
    current_stage_id: ?i64,
    form_state: view_models.TimelineFormState,
) !view_models.StageTimeline {
    const stored = try stages.listForProcess(allocator, database, process_id);
    const stage_views = try allocator.alloc(view_models.Stage, stored.len);
    for (stored, stage_views) |stage, *stage_view| {
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
        const edit_state = form_state.edit_note;
        const editing = if (edit_state) |state|
            state.note_id == note.id
        else
            false;
        note_view.* = .{
            .id = note.id,
            .body = note.body,
            .editor_url = try actionUrl(allocator, "notes", note.id, "edit"),
            .display_url = try std.fmt.allocPrint(allocator, "/notes/{d}", .{note.id}),
            .edit_action = try actionUrl(allocator, "notes", note.id, "edit"),
            .delete_action = try actionUrl(allocator, "notes", note.id, "delete"),
            .edit_body = if (editing) edit_state.?.body else note.body,
            .edit_error = if (editing) edit_state.?.error_message else null,
            .editing = editing,
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
    for (stored_appointments, appointment_views) |appointment, *view| {
        view.* = .{
            .id = appointment.id,
            .title = appointment.title,
            .time_display = appointment.starts_at,
            .meeting_url = appointment.meeting_url,
            .contact_name = appointment.contact_name,
            .location = appointment.location,
            .preparation_note = appointment.preparation_note,
            .status = appointments.statusText(appointment.status),
            .status_label = appointmentStatusLabel(appointment.status),
            .can_cancel = appointment.status == .scheduled,
            .cancel_action = try actionUrl(
                allocator,
                "appointments",
                appointment.id,
                "cancel",
            ),
        };
    }

    const learning = try buildQuestionViews(
        allocator,
        try questions.listForStage(
            allocator,
            database,
            stage.process_id,
            stage.id,
            .learning,
        ),
    );
    const is_form_stage = form_state.stage_id == stage.id;
    const is_current = current_stage_id == stage.id;
    const article_id = try std.fmt.allocPrint(allocator, "stage-{d}", .{stage.id});
    return .{
        .id = stage.id,
        .article_id = article_id,
        .target_id = try std.fmt.allocPrint(allocator, "#{s}", .{article_id}),
        .name = stage.name,
        .kind = stages.kindText(stage.kind),
        .position = stage.position,
        .status = stages.statusText(stage.status),
        .status_label = stageStatusLabel(stage.status),
        .started_at = stage.started_at,
        .outcome = if (stage.outcome) |value| stages.outcomeText(value) else null,
        .outcome_reason = stage.outcome_reason,
        .marker = stageMarker(stage.status, is_current),
        .state_class = stageStateClass(stage.status, is_current),
        .is_current = is_current,
        .can_set_outcome = is_current and
            (stage.status == .in_progress or stage.status == .scheduled),
        .is_offer = stage.kind == .offer,
        .compensation = try buildContextCompensation(
            allocator,
            database,
            stage,
            form_state,
        ),
        .can_skip = stage.status == .planned or
            (is_current and
                (stage.status == .in_progress or stage.status == .scheduled)),
        .can_reopen = stage.status == .completed or stage.status == .skipped,
        .outcome_action = try actionUrl(allocator, "stages", stage.id, "outcome"),
        .skip_action = try actionUrl(allocator, "stages", stage.id, "skip"),
        .reopen_action = try actionUrl(allocator, "stages", stage.id, "reopen"),
        .outcome_form = if (is_form_stage) form_state.outcome else .{},
        .add_note_action = try actionUrl(allocator, "stages", stage.id, "notes"),
        .schedule_action = try actionUrl(allocator, "stages", stage.id, "appointments"),
        .notes = note_views,
        .appointments = appointment_views,
        .show_interviews = stage.kind != .applied,
        .learning_questions = learning,
        .show_learning_questions = stage.kind == .technical or
            stage.kind == .system_design or stage.kind == .custom or
            learning.len > 0,
        .add_learning_question_action = try actionUrl(
            allocator,
            "stages",
            stage.id,
            "questions/learning",
        ),
        .learning_question_form = if (is_form_stage)
            form_state.learning_question
        else
            .{},
        .add_note_form = if (is_form_stage) form_state.add_note else .{},
        .appointment_form = if (is_form_stage)
            form_state.appointment
        else
            .{
                .input = .{
                    .title = stage.name,
                },
            },
    };
}

fn buildContextCompensation(
    allocator: std.mem.Allocator,
    database: *db.Database,
    stage: stages.Stage,
    form_state: view_models.TimelineFormState,
) !?view_models.CompensationSnapshot {
    const kind = switch (stage.kind) {
        .applied => compensations.Kind.advertised,
        .hr => compensations.Kind.discussed,
        .offer => compensations.Kind.offer,
        else => return null,
    };
    const stored = try compensations.getForProcess(
        allocator,
        database,
        stage.process_id,
        kind,
    );
    const has_error = form_state.stage_id == stage.id and
        form_state.compensation_kind == kind;
    const input = if (has_error)
        form_state.compensation_input
    else if (stored) |value|
        compensationInput(value)
    else
        compensations.Input{
            .process_id = stage.process_id,
            .kind = kind,
        };
    return .{
        .region_id = try std.fmt.allocPrint(allocator, "compensation-{s}", .{compensations.kindText(kind)}),
        .target_id = try std.fmt.allocPrint(allocator, "#compensation-{s}", .{compensations.kindText(kind)}),
        .edit_action = try std.fmt.allocPrint(allocator, "/processes/{d}/compensations/{s}/edit", .{ stage.process_id, compensations.kindText(kind) }),
        .kind = compensations.kindText(kind),
        .label = switch (kind) {
            .advertised => "Salary in job posting",
            .discussed => "Salary discussed",
            .offer => "Offer",
        },
        .display = if (stored) |value|
            try compensationDisplay(allocator, value)
        else if (kind == .offer)
            "Not received"
        else
            "Not recorded",
        .notes = if (stored) |value| value.notes else null,
        .action = try std.fmt.allocPrint(
            allocator,
            "/processes/{d}/compensations/{s}",
            .{ stage.process_id, compensations.kindText(kind) },
        ),
        .form = try buildCompensationForm(
            allocator,
            input,
            if (has_error) form_state.compensation_errors else .{},
        ),
        .show_confirmed = kind == .discussed,
        .editing = form_state.editing_compensation == kind,
    };
}

pub fn buildQuestionSection(
    allocator: std.mem.Allocator,
    database: *db.Database,
    process_id: i64,
    stage_id: ?i64,
    kind: questions.Kind,
    form: view_models.QuestionForm,
) !view_models.QuestionSection {
    const stored = if (stage_id) |id|
        try questions.listForStage(allocator, database, process_id, id, kind)
    else
        try questions.listForProcess(allocator, database, process_id, kind);
    return .{
        .process_id = process_id,
        .questions = try buildQuestionViews(allocator, stored),
        .add_action = if (stage_id) |id|
            try std.fmt.allocPrint(
                allocator,
                "/stages/{d}/questions/learning",
                .{id},
            )
        else
            try std.fmt.allocPrint(
                allocator,
                "/processes/{d}/questions/company",
                .{process_id},
            ),
        .question_value = form.question,
        .answer_value = form.answer,
        .error_message = form.error_message,
    };
}

fn buildQuestionViews(
    allocator: std.mem.Allocator,
    stored: []const questions.Question,
) ![]view_models.Question {
    const result = try allocator.alloc(view_models.Question, stored.len);
    for (stored, result) |question, *view| {
        view.* = .{
            .id = question.id,
            .question = question.question,
            .answer = question.answer,
            .edit_action = try actionUrl(allocator, "questions", question.id, "edit"),
            .delete_action = try actionUrl(allocator, "questions", question.id, "delete"),
        };
    }
    return result;
}

fn buildCompensationForm(
    allocator: std.mem.Allocator,
    input: compensations.Input,
    errors: compensations.Errors,
) !view_models.CompensationForm {
    return .{
        .input = input,
        .errors = errors,
        .minimum_value = try amountValue(
            allocator,
            input.amount_min_text,
            input.amount_min,
        ),
        .maximum_value = try amountValue(
            allocator,
            input.amount_max_text,
            input.amount_max,
        ),
    };
}

fn compensationInput(value: compensations.Compensation) compensations.Input {
    return .{
        .process_id = value.process_id,
        .kind = value.kind,
        .amount_min = value.amount_min,
        .amount_max = value.amount_max,
        .currency = value.currency orelse "",
        .period = value.period orelse "",
        .salary_type = value.salary_type orelse "",
        .confirmed = value.confirmed,
        .notes = value.notes orelse "",
    };
}

pub fn compensationDisplay(
    allocator: std.mem.Allocator,
    value: compensations.Compensation,
) ![]const u8 {
    if (value.amount_min == null and value.amount_max == null) {
        return if (value.confirmed) "Discussed · confirmed" else "Recorded";
    }
    var output: std.Io.Writer.Allocating = .init(allocator);
    if (value.currency) |currency| try output.writer.print("{s} ", .{currency});
    if (value.amount_min) |amount| try writeAmount(&output.writer, amount);
    if (value.amount_min != null and value.amount_max != null) {
        try output.writer.writeAll("–");
    }
    if (value.amount_max) |amount| try writeAmount(&output.writer, amount);
    if (value.period) |period| try output.writer.print(" / {s}", .{period});
    if (value.salary_type) |salary_type| {
        try output.writer.print(" · {s}", .{salary_type});
    }
    if (value.confirmed) try output.writer.writeAll(" · confirmed");
    return output.toOwnedSlice();
}

fn ratingDisplay(
    allocator: std.mem.Allocator,
    rating: ?i64,
    symbol: []const u8,
) ![]const u8 {
    const value = rating orelse return "—";
    var output: std.Io.Writer.Allocating = .init(allocator);
    var index: i64 = 0;
    while (index < value) : (index += 1) try output.writer.writeAll(symbol);
    return output.toOwnedSlice();
}

fn ratingLabel(
    allocator: std.mem.Allocator,
    rating: ?i64,
) ![]const u8 {
    const value = rating orelse return "Not rated";
    var output: std.Io.Writer.Allocating = .init(allocator);
    var index: i64 = 0;
    while (index < 5) : (index += 1) {
        try output.writer.writeAll(if (index < value) "★" else "☆");
    }
    return output.toOwnedSlice();
}

fn currentStageName(
    allocator: std.mem.Allocator,
    database: *db.Database,
    stage_id: ?i64,
) ![]const u8 {
    const id = stage_id orelse return "Add next stage";
    const stage = (try stages.get(allocator, database, id)) orelse return "—";
    return stage.name;
}

fn optionalIntValue(allocator: std.mem.Allocator, value: ?i64) ![]const u8 {
    return if (value) |number|
        std.fmt.allocPrint(allocator, "{d}", .{number})
    else
        "";
}

fn amountValue(
    allocator: std.mem.Allocator,
    raw: []const u8,
    parsed: ?i64,
) ![]const u8 {
    if (raw.len > 0) return raw;
    return optionalIntValue(allocator, parsed);
}

fn writeAmount(writer: *std.Io.Writer, amount: i64) !void {
    var buffer: [32]u8 = undefined;
    const digits = try std.fmt.bufPrint(&buffer, "{d}", .{amount});
    for (digits, 0..) |digit, index| {
        const remaining = digits.len - index;
        try writer.writeByte(digit);
        if (remaining > 1 and (remaining - 1) % 3 == 0) try writer.writeByte(',');
    }
}

fn actionUrl(
    allocator: std.mem.Allocator,
    resource: []const u8,
    id: i64,
    action: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(allocator, "/{s}/{d}/{s}", .{ resource, id, action });
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

pub fn renderDashboardPage(writer: *std.Io.Writer, view: view_models.Dashboard) !void {
    try dashboard_template.DashboardPage.render(.{view}, writer);
}
pub fn renderDashboardFragment(writer: *std.Io.Writer, view: view_models.Dashboard) !void {
    try dashboard_template.DashboardFragment.render(.{view}, writer);
}
pub fn renderProcessFormPage(writer: *std.Io.Writer, view: view_models.ProcessForm) !void {
    try process_form_template.ProcessFormPage.render(.{view}, writer);
}
pub fn renderProcessFormNavigationFragment(writer: *std.Io.Writer, view: view_models.ProcessForm) !void {
    try process_form_template.ProcessFormFragment.render(.{view}, writer);
}
pub fn renderProcessFormValidationFragment(writer: *std.Io.Writer, view: view_models.ProcessForm) !void {
    try process_form_template.ProcessForm.render(.{view}, writer);
}
pub fn renderProcessDetailPage(writer: *std.Io.Writer, view: view_models.ProcessDetail) !void {
    try process_detail_template.ProcessDetailPage.render(.{view}, writer);
}
pub fn renderProcessDetailFragment(writer: *std.Io.Writer, view: view_models.ProcessDetail) !void {
    try process_detail_template.ProcessDetailFragment.render(.{view}, writer);
}
pub fn renderRatingsFragment(
    writer: *std.Io.Writer,
    view: view_models.RatingsSection,
) !void {
    try process_detail_template.RatingsSection.render(.{view}, writer);
}
pub fn renderCompanySummaryFragment(writer: *std.Io.Writer, view: view_models.CompanySummarySection) !void {
    try process_detail_template.CompanySummarySection.render(.{view}, writer);
}
pub fn renderStageTimelineFragment(writer: *std.Io.Writer, view: view_models.StageTimeline) !void {
    try stage_timeline_template.StageTimeline.render(.{view}, writer);
}
pub fn renderStageCardFragment(writer: *std.Io.Writer, view: view_models.Stage) !void {
    try stage_card_template.StageCard.render(.{view}, writer);
}
pub fn renderSourceFieldFragment(writer: *std.Io.Writer, view: view_models.SourceField) !void {
    try source_field_template.SourceField.render(.{view}, writer);
}
pub fn renderCompensationFragment(writer: *std.Io.Writer, view: view_models.CompensationSection) !void {
    try compensation_template.CompensationSection.render(.{view}, writer);
}
pub fn renderCompensationEditorFragment(writer: *std.Io.Writer, view: view_models.CompensationSnapshot) !void {
    try compensation_template.CompensationEditor.render(.{view}, writer);
}
pub fn renderCompanyQuestionsFragment(writer: *std.Io.Writer, view: view_models.QuestionSection) !void {
    try company_questions_template.CompanyQuestions.render(.{view}, writer);
}
pub fn renderErrorPage(writer: *std.Io.Writer, view: view_models.ErrorPage) !void {
    try error_page_template.ErrorPage.render(.{view}, writer);
}
pub fn renderErrorFragment(writer: *std.Io.Writer, view: view_models.ErrorPage) !void {
    try error_page_template.ErrorFragment.render(.{view}, writer);
}

test "new process form is deliberately small" {
    var database = try db.Database.open(":memory:");
    defer database.close();
    try migrations.apply(&database);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const view = try buildProcessForm(
        arena.allocator(),
        &database,
        .{ .applied_at = "2026-08-08" },
        .{},
        null,
    );
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try renderProcessFormValidationFragment(&output.writer, view);
    const html = output.written();
    for ([_][]const u8{
        "Company name",
        "Position",
        "Job posting URL",
        "Source",
        "Application date",
        "About the company",
    }) |required| {
        try std.testing.expect(std.mem.indexOf(u8, html, required) != null);
    }
    for ([_][]const u8{
        "<legend>Job</legend>",
        "My rating",
        "Salary in job posting",
        "Salary discussed",
        "Location",
        "Work arrangement",
    }) |absent| {
        try std.testing.expect(std.mem.indexOf(u8, html, absent) == null);
    }
}

test "ratings and company summary preserve stable inline-edit regions" {
    var database = try db.Database.open(":memory:");
    defer database.close();
    try migrations.apply(&database);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const process_id = try processes.create(&database, .{
        .company_name = "Acme",
        .position_name = "Engineer",
        .company_summary = "Original",
        .applied_at = "2026-08-08",
    });
    const process = (try processes.get(arena.allocator(), &database, process_id)).?;
    const ratings = try buildRatingsSection(arena.allocator(), process, .{}, false);
    const summary = try buildCompanySummarySection(arena.allocator(), process_id, "Original", false, null);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try renderRatingsFragment(&output.writer, ratings);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "hx-get=\"/processes/1/ratings/edit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "class=\"editable-property ratings-display\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "id=\"process-ratings\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "<svg") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "@PencilIcon") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "&lt;svg") == null);
    const ratings_editor = try buildRatingsSection(
        arena.allocator(),
        process,
        .{},
        true,
    );
    var editor_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer editor_output.deinit();
    try renderRatingsFragment(&editor_output.writer, ratings_editor);
    try std.testing.expect(std.mem.indexOf(
        u8,
        editor_output.written(),
        "<select name=\"interest_rating\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        editor_output.written(),
        "@components",
    ) == null);
    var summary_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer summary_output.deinit();
    try renderCompanySummaryFragment(&summary_output.writer, summary);
    try std.testing.expect(std.mem.indexOf(u8, summary_output.written(), "id=\"company-summary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary_output.written(), "class=\"editable-property company-summary-display\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary_output.written(), "hx-swap=\"outerHTML\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary_output.written(), "<svg") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary_output.written(), "Job posting") == null);
}

test "compensation editors appear only in their stage contexts" {
    var database = try db.Database.open(":memory:");
    defer database.close();
    try migrations.apply(&database);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const process_id = try processes.create(&database, .{
        .company_name = "Acme",
        .position_name = "Engineer",
        .applied_at = "2026-08-08",
    });
    _ = try stages.add(allocator, &database, process_id, .hr, "");
    _ = try stages.add(allocator, &database, process_id, .technical, "");
    _ = try stages.add(allocator, &database, process_id, .offer, "");
    const stored = try stages.listForProcess(allocator, &database, process_id);
    _ = try notes.createForStage(
        &database,
        process_id,
        stored[0].id,
        .{ .body = "Recruiter shared the team size." },
    );
    const current_stage_id = stored[0].id;
    for (stored) |stage| {
        const view = try buildStageCardView(
            allocator,
            &database,
            stage,
            current_stage_id,
            .{},
        );
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        try renderStageCardFragment(&output.writer, view);
        const html = output.written();
        switch (stage.kind) {
            .applied => try std.testing.expect(
                std.mem.indexOf(u8, html, "Salary in job posting") != null,
            ),
            .hr => {
                try std.testing.expect(
                    std.mem.indexOf(u8, html, "Salary discussed") != null,
                );
                try std.testing.expect(
                    std.mem.indexOf(u8, html, "Confirmed") != null,
                );
            },
            .offer => try std.testing.expect(
                std.mem.indexOf(u8, html, "Offer") != null,
            ),
            .technical => try std.testing.expect(
                std.mem.indexOf(u8, html, "Edit salary") == null,
            ),
            else => {},
        }
        if (stage.kind == .applied) {
            try std.testing.expect(
                std.mem.indexOf(u8, html, "class=\"editable-property compensation-display\"") != null,
            );
            try std.testing.expect(
                std.mem.indexOf(u8, html, "hx-get=\"/processes/1/compensations/advertised/edit\"") != null,
            );
            try std.testing.expect(
                std.mem.indexOf(u8, html, "hx-target=\"#compensation-advertised\"") != null,
            );
            try std.testing.expect(std.mem.indexOf(u8, html, "<svg") != null);
            try std.testing.expect(std.mem.indexOf(u8, html, "Edit salary") == null);
            try std.testing.expect(
                std.mem.indexOf(u8, html, "class=\"editable-property note-edit-surface\"") != null,
            );
            try std.testing.expect(
                std.mem.indexOf(u8, html, ">Recruiter shared the team size.</span>") != null,
            );
        }
    }
}
