const appointments = @import("appointments.zig");
const compensations = @import("compensations.zig");
const processes = @import("processes.zig");

pub const ProcessSummary = struct {
    detail_url: []const u8,
    company_name: []const u8,
    position_name: []const u8,
    status: []const u8,
    current_stage: []const u8,
    source: []const u8,
    interest: []const u8,
    money: []const u8,
    growth: []const u8,
    applied_at: []const u8,
    updated_at: []const u8,
};

pub const Dashboard = struct {
    processes: []const ProcessSummary,
};

pub const SourceOption = struct {
    id: i64,
    id_value: []const u8,
    name: []const u8,
    selected: bool,
};

pub const SourceField = struct {
    options: []const SourceOption,
    new_source: []const u8 = "",
    error_message: ?[]const u8 = null,
};

pub const CompensationForm = struct {
    input: compensations.Input,
    errors: compensations.Errors = .{},
    minimum_value: []const u8,
    maximum_value: []const u8,
};

pub const ProcessForm = struct {
    title: []const u8,
    action: []const u8,
    cancel_url: []const u8,
    input: processes.Input,
    errors: processes.Errors,
    source_field: SourceField,
    interest_value: []const u8,
    money_value: []const u8,
    growth_value: []const u8,
    advertised: CompensationForm,
    discussed: CompensationForm,
};

pub const CompensationSnapshot = struct {
    kind: []const u8,
    label: []const u8,
    display: []const u8,
    notes: ?[]const u8,
    action: []const u8,
    form: CompensationForm,
    show_confirmed: bool,
};

pub const CompensationSection = struct {
    snapshots: []const CompensationSnapshot,
};

pub const Question = struct {
    id: i64,
    question: []const u8,
    answer: ?[]const u8,
    edit_action: []const u8,
    delete_action: []const u8,
};

pub const QuestionSection = struct {
    process_id: i64,
    questions: []const Question,
    add_action: []const u8,
    question_value: []const u8 = "",
    answer_value: []const u8 = "",
    error_message: ?[]const u8 = null,
};

pub const ProcessDetail = struct {
    id: i64,
    title: []const u8,
    edit_url: []const u8,
    delete_url: []const u8,
    company_name: []const u8,
    position_name: []const u8,
    status: []const u8,
    source: []const u8,
    location: []const u8,
    work_arrangement: []const u8,
    company_summary: []const u8,
    applied_at: []const u8,
    interest: []const u8,
    money: []const u8,
    growth: []const u8,
    job_url: ?[]const u8,
    updated_at: []const u8,
    compensation: CompensationSection,
    timeline: StageTimeline,
    company_questions: QuestionSection,
};

pub const AddStageForm = struct {
    kind: []const u8 = "hr",
    name: []const u8 = "",
    error_message: ?[]const u8 = null,
};

pub const OutcomeForm = struct {
    outcome: []const u8 = "",
    reason: []const u8 = "",
    error_message: ?[]const u8 = null,
};

pub const QuestionForm = struct {
    question: []const u8 = "",
    answer: []const u8 = "",
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
    outcome: OutcomeForm = .{},
    learning_question: QuestionForm = .{},
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
    kind: []const u8,
    position: i64,
    status: []const u8,
    status_label: []const u8,
    outcome: ?[]const u8,
    outcome_reason: ?[]const u8,
    marker: []const u8,
    state_class: []const u8,
    is_current: bool,
    can_set_outcome: bool,
    is_offer: bool,
    offer_compensation: ?CompensationSnapshot,
    can_skip: bool,
    can_reopen: bool,
    outcome_action: []const u8,
    skip_action: []const u8,
    reopen_action: []const u8,
    outcome_form: OutcomeForm,
    add_note_action: []const u8,
    schedule_action: []const u8,
    notes: []const StageNote,
    appointments: []const StageAppointment,
    learning_questions: []const Question,
    show_learning_questions: bool,
    add_learning_question_action: []const u8,
    learning_question_form: QuestionForm,
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
