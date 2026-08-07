const std = @import("std");
const db = @import("database.zig");
const stages = @import("stages.zig");

pub const Status = enum {
    scheduled,
    completed,
    cancelled,
};

pub const Appointment = struct {
    id: i64,
    process_id: i64,
    stage_id: ?i64,
    title: []const u8,
    starts_at: []const u8,
    ends_at: ?[]const u8,
    meeting_url: ?[]const u8,
    contact_name: ?[]const u8,
    location: ?[]const u8,
    preparation_note: ?[]const u8,
    status: Status,
    created_at: []const u8,
    updated_at: []const u8,
};

pub const Input = struct {
    title: []const u8 = "",
    starts_at: []const u8 = "",
    ends_at: []const u8 = "",
    meeting_url: []const u8 = "",
    contact_name: []const u8 = "",
    location: []const u8 = "",
    preparation_note: []const u8 = "",
};

pub const Errors = struct {
    title: ?[]const u8 = null,
    starts_at: ?[]const u8 = null,
    ends_at: ?[]const u8 = null,
    meeting_url: ?[]const u8 = null,

    pub fn any(errors: Errors) bool {
        return errors.title != null or
            errors.starts_at != null or
            errors.ends_at != null or
            errors.meeting_url != null;
    }
};

pub fn validate(input: Input) Errors {
    var errors = Errors{};
    if (std.mem.trim(u8, input.title, " \t\r\n").len == 0) {
        errors.title = "Title is required.";
    }
    if (!isLocalDateTime(input.starts_at)) {
        errors.starts_at = "Enter a valid local date and time.";
    }
    if (input.ends_at.len > 0 and !isLocalDateTime(input.ends_at)) {
        errors.ends_at = "Enter a valid local date and time.";
    } else if (input.ends_at.len > 0 and
        isLocalDateTime(input.starts_at) and
        std.mem.order(u8, input.ends_at, input.starts_at) == .lt)
    {
        errors.ends_at = "End must not be earlier than start.";
    }
    if (input.meeting_url.len > 0 and
        !std.mem.startsWith(u8, input.meeting_url, "http://") and
        !std.mem.startsWith(u8, input.meeting_url, "https://"))
    {
        errors.meeting_url = "Use an HTTP or HTTPS URL.";
    }
    return errors;
}

pub fn listForStage(
    allocator: std.mem.Allocator,
    database: *db.Database,
    process_id: i64,
    stage_id: i64,
) ![]Appointment {
    var statement = try database.prepare(
        "SELECT id,process_id,stage_id,title,starts_at,ends_at,meeting_url,contact_name,location,preparation_note,status,created_at,updated_at FROM appointments WHERE process_id=? AND stage_id=? ORDER BY starts_at,id",
    );
    defer statement.deinit();
    try statement.int(1, process_id);
    try statement.int(2, stage_id);
    var result: std.ArrayList(Appointment) = .empty;
    while (try statement.step()) {
        try result.append(allocator, try read(allocator, &statement));
    }
    return result.toOwnedSlice(allocator);
}

pub fn create(
    allocator: std.mem.Allocator,
    database: *db.Database,
    stage_id: i64,
    input: Input,
) !i64 {
    if (validate(input).any()) return error.InvalidInput;
    try database.begin();
    errdefer database.rollback() catch {};
    const stage = (try stages.get(allocator, database, stage_id)) orelse
        return error.NotFound;

    var statement = try database.prepare(
        "INSERT INTO appointments(process_id,stage_id,title,starts_at,ends_at,meeting_url,contact_name,location,preparation_note,status,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,'scheduled',datetime('now'),datetime('now'))",
    );
    defer statement.deinit();
    try statement.int(1, stage.process_id);
    try statement.int(2, stage_id);
    try statement.text(3, std.mem.trim(u8, input.title, " \t\r\n"));
    try statement.text(4, input.starts_at);
    try statement.text(5, nullable(input.ends_at));
    try statement.text(6, nullable(input.meeting_url));
    try statement.text(7, nullable(input.contact_name));
    try statement.text(8, nullable(input.location));
    try statement.text(9, nullable(input.preparation_note));
    _ = try statement.step();
    const appointment_id = database.lastId();

    var schedule_stage = try database.prepare(
        "UPDATE stages SET status='scheduled',updated_at=datetime('now') WHERE id=? AND status='in_progress' AND id=(SELECT current_stage_id FROM job_processes WHERE id=?)",
    );
    defer schedule_stage.deinit();
    try schedule_stage.int(1, stage_id);
    try schedule_stage.int(2, stage.process_id);
    _ = try schedule_stage.step();

    const display_time = try allocator.dupe(u8, input.starts_at);
    if (display_time.len > 10) display_time[10] = ' ';
    const description = try std.fmt.allocPrint(
        allocator,
        "Scheduled {s} for {s}",
        .{ stage.name, display_time },
    );
    try addActivity(
        database,
        stage.process_id,
        "appointment_scheduled",
        description,
    );
    try database.commit();
    return appointment_id;
}

pub fn cancel(
    allocator: std.mem.Allocator,
    database: *db.Database,
    appointment_id: i64,
) !i64 {
    try database.begin();
    errdefer database.rollback() catch {};
    const appointment = (try get(allocator, database, appointment_id)) orelse
        return error.NotFound;
    if (appointment.status != .scheduled) return error.InvalidTransition;

    var statement = try database.prepare(
        "UPDATE appointments SET status='cancelled',updated_at=datetime('now') WHERE id=?",
    );
    defer statement.deinit();
    try statement.int(1, appointment_id);
    _ = try statement.step();
    const description = try std.fmt.allocPrint(
        allocator,
        "Cancelled interview: {s}",
        .{appointment.title},
    );
    try addActivity(
        database,
        appointment.process_id,
        "appointment_cancelled",
        description,
    );
    try database.commit();
    return appointment.process_id;
}

pub fn get(
    allocator: std.mem.Allocator,
    database: *db.Database,
    appointment_id: i64,
) !?Appointment {
    var statement = try database.prepare(
        "SELECT id,process_id,stage_id,title,starts_at,ends_at,meeting_url,contact_name,location,preparation_note,status,created_at,updated_at FROM appointments WHERE id=?",
    );
    defer statement.deinit();
    try statement.int(1, appointment_id);
    if (!try statement.step()) return null;
    return try read(allocator, &statement);
}

pub fn statusText(status: Status) []const u8 {
    return switch (status) {
        .scheduled => "scheduled",
        .completed => "completed",
        .cancelled => "cancelled",
    };
}

fn parseStatus(value: []const u8) !Status {
    inline for (std.meta.tags(Status)) |status| {
        if (std.mem.eql(u8, value, statusText(status))) return status;
    }
    return error.UnknownAppointmentStatus;
}

fn isLocalDateTime(value: []const u8) bool {
    if (value.len != 16 or value[10] != 'T' or value[13] != ':') return false;
    for (value, 0..) |character, index| {
        if (index == 4 or index == 7 or index == 10 or index == 13) continue;
        if (!std.ascii.isDigit(character)) return false;
    }
    const year = std.fmt.parseInt(u16, value[0..4], 10) catch return false;
    const month = std.fmt.parseInt(u8, value[5..7], 10) catch return false;
    const day = std.fmt.parseInt(u8, value[8..10], 10) catch return false;
    const hour = std.fmt.parseInt(u8, value[11..13], 10) catch return false;
    const minute = std.fmt.parseInt(u8, value[14..16], 10) catch return false;
    if (month < 1 or month > 12 or hour > 23 or minute > 59) return false;
    const days = [_]u8{
        31,
        if (isLeapYear(year)) 29 else 28,
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    };
    return day >= 1 and day <= days[month - 1];
}

fn isLeapYear(year: u16) bool {
    return year % 400 == 0 or (year % 4 == 0 and year % 100 != 0);
}

fn nullable(value: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

fn addActivity(
    database: *db.Database,
    process_id: i64,
    activity_type: []const u8,
    description: []const u8,
) !void {
    var statement = try database.prepare(
        "INSERT INTO activity_log(process_id,activity_type,description,created_at) VALUES(?,?,?,datetime('now'))",
    );
    defer statement.deinit();
    try statement.int(1, process_id);
    try statement.text(2, activity_type);
    try statement.text(3, description);
    _ = try statement.step();
}

fn read(
    allocator: std.mem.Allocator,
    statement: *db.Statement,
) !Appointment {
    return .{
        .id = statement.colInt(0),
        .process_id = statement.colInt(1),
        .stage_id = statement.colOptionalInt(2),
        .title = try allocator.dupe(u8, statement.colText(3)),
        .starts_at = try allocator.dupe(u8, statement.colText(4)),
        .ends_at = try dupeOptional(allocator, statement.colOptionalText(5)),
        .meeting_url = try dupeOptional(allocator, statement.colOptionalText(6)),
        .contact_name = try dupeOptional(allocator, statement.colOptionalText(7)),
        .location = try dupeOptional(allocator, statement.colOptionalText(8)),
        .preparation_note = try dupeOptional(allocator, statement.colOptionalText(9)),
        .status = try parseStatus(statement.colText(10)),
        .created_at = try allocator.dupe(u8, statement.colText(11)),
        .updated_at = try allocator.dupe(u8, statement.colText(12)),
    };
}

fn dupeOptional(
    allocator: std.mem.Allocator,
    value: ?[]const u8,
) !?[]const u8 {
    return if (value) |text| try allocator.dupe(u8, text) else null;
}

test "appointment validation covers local times ranges and URLs" {
    try std.testing.expect(validate(.{}).starts_at != null);
    try std.testing.expect(validate(.{
        .title = "Interview",
        .starts_at = "2026-99-12T15:30",
    }).starts_at != null);
    try std.testing.expect(validate(.{
        .title = "Interview",
        .starts_at = "2026-08-12T15:30",
        .ends_at = "2026-08-12T14:30",
    }).ends_at != null);
    try std.testing.expect(validate(.{
        .title = "Interview",
        .starts_at = "2026-08-12T15:30",
        .meeting_url = "ftp://example.com",
    }).meeting_url != null);
}
