const processes = @import("processes.zig");

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
};

pub const ErrorPage = struct {
    title: []const u8,
    message: []const u8,
};
