const processes = @import("processes.zig");
const appointments = @import("appointments.zig");

pub const ProcessSummary = struct {
    detail_url: []const u8,
    company_name: []const u8,
    position_name: []const u8,
    status: []const u8,
    salary_display: []const u8,
    source: []const u8,
    updated_at: []const u8,
};

pub const Dashboard = struct {
    processes: []const ProcessSummary,
};

pub const ProcessForm = struct {
    title: []const u8,
    action: []const u8,
    cancel_url: []const u8,
    input: processes.Input,
    errors: processes.Errors,
    salary_min_value: []const u8,
    salary_max_value: []const u8,
};

pub const ProcessDetail = struct {
    id: i64,
    title: []const u8,
    edit_url: []const u8,
    company_name: []const u8,
    position_name: []const u8,
    status: []const u8,
    source: []const u8,
    location: []const u8,
    work_arrangement: []const u8,
    salary_display: []const u8,
    salary_notes: []const u8,
    job_url: ?[]const u8,
    created_at: []const u8,
    updated_at: []const u8,
    timeline: StageTimeline,
};

pub const AddStageForm = struct {
    name: []const u8 = "",
    error_message: ?[]const u8 = null,
};

pub const NoteForm = struct {
    body: []const u8 = "",
    error_message: ?[]const u8 = null,
};

pub const NoteEditForm = struct {
    note_id: i64,
    body: []const u8,
    error_message: ?[]const u8 = null,
};

pub const AppointmentForm = struct {
    input: appointments.Input = .{},
    errors: appointments.Errors = .{},
};

pub const TimelineFormState = struct {
    add_stage: AddStageForm = .{},
    stage_id: ?i64 = null,
    add_note: NoteForm = .{},
    edit_note: ?NoteEditForm = null,
    appointment: AppointmentForm = .{},
};

pub const StageNote = struct {
    id: i64,
    body: []const u8,
    edit_action: []const u8,
    delete_action: []const u8,
    edit_body: []const u8,
    edit_error: ?[]const u8,
    editing_with_error: bool,
};

pub const StageAppointment = struct {
    id: i64,
    title: []const u8,
    time_display: []const u8,
    meeting_url: ?[]const u8,
    contact_name: ?[]const u8,
    location: ?[]const u8,
    preparation_note: ?[]const u8,
    status: []const u8,
    status_label: []const u8,
    can_cancel: bool,
    cancel_action: []const u8,
};

pub const Stage = struct {
    id: i64,
    article_id: []const u8,
    target_id: []const u8,
    name: []const u8,
    position: i64,
    status: []const u8,
    status_label: []const u8,
    marker: []const u8,
    state_class: []const u8,
    is_current: bool,
    can_complete: bool,
    can_skip: bool,
    can_reopen: bool,
    complete_action: []const u8,
    skip_action: []const u8,
    reopen_action: []const u8,
    add_note_action: []const u8,
    schedule_action: []const u8,
    notes: []const StageNote,
    appointments: []const StageAppointment,
    add_note_form: NoteForm,
    appointment_form: AppointmentForm,
};

pub const StageTimeline = struct {
    process_id: i64,
    current_stage_id: ?i64,
    stages: []const Stage,
    add_stage_action: []const u8,
    add_stage: AddStageForm,
};

pub const ErrorPage = struct {
    title: []const u8,
    message: []const u8,
};
