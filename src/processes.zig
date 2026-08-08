const std = @import("std");
const compensations = @import("compensations.zig");
const db = @import("database.zig");
const stages = @import("stages.zig");

pub const Input = struct {
    company_name: []const u8 = "",
    position_name: []const u8 = "",
    job_url: []const u8 = "",
    company_summary: []const u8 = "",
    applied_at: []const u8 = "",
    source_id: ?i64 = null,
    source_name: []const u8 = "",
    location: []const u8 = "",
    work_arrangement: []const u8 = "",
    interest_rating: ?i64 = null,
    money_rating: ?i64 = null,
    growth_rating: ?i64 = null,
    interest_rating_invalid: bool = false,
    money_rating_invalid: bool = false,
    growth_rating_invalid: bool = false,
    advertised: compensations.Input = .{ .kind = .advertised },
    discussed: compensations.Input = .{ .kind = .discussed },
};

pub const Errors = struct {
    company: ?[]const u8 = null,
    position: ?[]const u8 = null,
    url: ?[]const u8 = null,
    applied_at: ?[]const u8 = null,
    interest_rating: ?[]const u8 = null,
    money_rating: ?[]const u8 = null,
    growth_rating: ?[]const u8 = null,
    advertised: compensations.Errors = .{},
    discussed: compensations.Errors = .{},

    pub fn any(errors: Errors) bool {
        return errors.company != null or errors.position != null or
            errors.url != null or errors.applied_at != null or
            errors.interest_rating != null or errors.money_rating != null or
            errors.growth_rating != null or errors.advertised.any() or
            errors.discussed.any();
    }
};

pub const Process = struct {
    id: i64,
    input: Input,
    status: []const u8,
    current_stage_id: ?i64 = null,
    created_at: []const u8,
    updated_at: []const u8,
};

pub fn validate(input: Input) Errors {
    var errors = Errors{};
    if (std.mem.trim(u8, input.company_name, " \t\r\n").len == 0) {
        errors.company = "Company is required.";
    }
    if (std.mem.trim(u8, input.position_name, " \t\r\n").len == 0) {
        errors.position = "Position is required.";
    }
    if (input.job_url.len > 0 and
        !std.mem.startsWith(u8, input.job_url, "http://") and
        !std.mem.startsWith(u8, input.job_url, "https://"))
    {
        errors.url = "Use an HTTP or HTTPS URL.";
    }
    if (!isDate(input.applied_at)) {
        errors.applied_at = "Enter an application date.";
    }
    validateRating(
        input.interest_rating,
        input.interest_rating_invalid,
        &errors.interest_rating,
    );
    validateRating(
        input.money_rating,
        input.money_rating_invalid,
        &errors.money_rating,
    );
    validateRating(
        input.growth_rating,
        input.growth_rating_invalid,
        &errors.growth_rating,
    );
    errors.advertised = compensations.validate(input.advertised);
    errors.discussed = compensations.validate(input.discussed);
    return errors;
}

pub fn create(database: *db.Database, input: Input) !i64 {
    if (validate(input).any()) return error.InvalidInput;
    try database.begin();
    errdefer database.rollback() catch {};

    var statement = try database.prepare(
        \\INSERT INTO job_processes(
        \\ company_name,position_name,job_url,company_summary,applied_at,
        \\ source_id,location,work_arrangement,interest_rating,money_rating,
        \\ growth_rating,created_at,updated_at
        \\) VALUES(?,?,?,?,?,?,?,?,?,?,?,datetime('now'),datetime('now'))
    );
    defer statement.deinit();
    try bind(&statement, input);
    _ = try statement.step();
    const process_id = database.lastId();

    try persistCompensation(database, process_id, input.advertised);
    try persistCompensation(database, process_id, input.discussed);
    _ = try stages.createApplied(database, process_id, input.applied_at);
    try addActivity(database, process_id, "process_created", "Job process created");
    try database.commit();
    return process_id;
}

pub fn update(database: *db.Database, id: i64, input: Input) !void {
    if (validate(input).any()) return error.InvalidInput;
    try database.begin();
    errdefer database.rollback() catch {};

    var statement = try database.prepare(
        \\UPDATE job_processes SET
        \\ company_name=?,position_name=?,job_url=?,company_summary=?,applied_at=?,
        \\ source_id=?,location=?,work_arrangement=?,interest_rating=?,money_rating=?,
        \\ growth_rating=?,updated_at=datetime('now') WHERE id=?
    );
    defer statement.deinit();
    try bind(&statement, input);
    try statement.int(12, id);
    _ = try statement.step();
    if (database.changes() == 0) return error.NotFound;

    try persistCompensation(database, id, input.advertised);
    try persistCompensation(database, id, input.discussed);
    try addActivity(database, id, "process_updated", "Job process updated");
    try database.commit();
}

pub fn delete(database: *db.Database, id: i64) !void {
    var statement = try database.prepare("DELETE FROM job_processes WHERE id=?");
    defer statement.deinit();
    try statement.int(1, id);
    _ = try statement.step();
    if (database.changes() == 0) return error.NotFound;
}

pub fn updateRatings(
    database: *db.Database,
    id: i64,
    input: Input,
) !void {
    var errors = Errors{};
    validateRating(
        input.interest_rating,
        input.interest_rating_invalid,
        &errors.interest_rating,
    );
    validateRating(
        input.money_rating,
        input.money_rating_invalid,
        &errors.money_rating,
    );
    validateRating(
        input.growth_rating,
        input.growth_rating_invalid,
        &errors.growth_rating,
    );
    if (errors.interest_rating != null or errors.money_rating != null or
        errors.growth_rating != null)
    {
        return error.InvalidInput;
    }
    var statement = try database.prepare(
        \\UPDATE job_processes SET interest_rating=?,money_rating=?,growth_rating=?,
        \\ updated_at=datetime('now') WHERE id=?
    );
    defer statement.deinit();
    try statement.int(1, input.interest_rating);
    try statement.int(2, input.money_rating);
    try statement.int(3, input.growth_rating);
    try statement.int(4, id);
    _ = try statement.step();
    if (database.changes() == 0) return error.NotFound;
}

pub fn get(
    allocator: std.mem.Allocator,
    database: *db.Database,
    id: i64,
) !?Process {
    var statement = try database.prepare(
        \\SELECT p.id,p.company_name,p.position_name,p.job_url,p.company_summary,
        \\ p.applied_at,p.source_id,COALESCE(s.name,''),p.location,
        \\ p.work_arrangement,p.interest_rating,p.money_rating,p.growth_rating,
        \\ p.status,p.current_stage_id,p.created_at,p.updated_at
        \\FROM job_processes p LEFT JOIN sources s ON s.id=p.source_id
        \\WHERE p.id=?
    );
    defer statement.deinit();
    try statement.int(1, id);
    if (!try statement.step()) return null;
    var process = try read(allocator, &statement);
    try loadCompensations(allocator, database, &process);
    return process;
}

pub fn list(
    allocator: std.mem.Allocator,
    database: *db.Database,
) ![]Process {
    var statement = try database.prepare(
        \\SELECT p.id,p.company_name,p.position_name,p.job_url,p.company_summary,
        \\ p.applied_at,p.source_id,COALESCE(s.name,''),p.location,
        \\ p.work_arrangement,p.interest_rating,p.money_rating,p.growth_rating,
        \\ p.status,p.current_stage_id,p.created_at,p.updated_at
        \\FROM job_processes p LEFT JOIN sources s ON s.id=p.source_id
        \\WHERE p.status IN ('active','offer_received') ORDER BY p.updated_at DESC
    );
    defer statement.deinit();
    var result: std.ArrayList(Process) = .empty;
    while (try statement.step()) {
        var process = try read(allocator, &statement);
        try loadCompensations(allocator, database, &process);
        try result.append(allocator, process);
    }
    return result.toOwnedSlice(allocator);
}

fn bind(statement: *db.Statement, input: Input) !void {
    try statement.text(1, input.company_name);
    try statement.text(2, input.position_name);
    try statement.text(3, nullable(input.job_url));
    try statement.text(4, nullable(input.company_summary));
    try statement.text(5, input.applied_at);
    try statement.int(6, input.source_id);
    try statement.text(7, nullable(input.location));
    try statement.text(8, nullable(input.work_arrangement));
    try statement.int(9, input.interest_rating);
    try statement.int(10, input.money_rating);
    try statement.int(11, input.growth_rating);
}

fn persistCompensation(
    database: *db.Database,
    process_id: i64,
    value: compensations.Input,
) !void {
    var input = value;
    input.process_id = process_id;
    if (compensations.isEmpty(input)) {
        try compensations.delete(database, process_id, input.kind);
    } else {
        try compensations.upsert(database, input);
    }
}

fn loadCompensations(
    allocator: std.mem.Allocator,
    database: *db.Database,
    process: *Process,
) !void {
    if (try compensations.getForProcess(
        allocator,
        database,
        process.id,
        .advertised,
    )) |value| {
        process.input.advertised = compensationInput(value);
    }
    if (try compensations.getForProcess(
        allocator,
        database,
        process.id,
        .discussed,
    )) |value| {
        process.input.discussed = compensationInput(value);
    }
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

fn read(
    allocator: std.mem.Allocator,
    statement: *db.Statement,
) !Process {
    return .{
        .id = statement.colInt(0),
        .input = .{
            .company_name = try allocator.dupe(u8, statement.colText(1)),
            .position_name = try allocator.dupe(u8, statement.colText(2)),
            .job_url = try allocator.dupe(u8, statement.colText(3)),
            .company_summary = try allocator.dupe(u8, statement.colText(4)),
            .applied_at = try allocator.dupe(u8, statement.colText(5)),
            .source_id = statement.colOptionalInt(6),
            .source_name = try allocator.dupe(u8, statement.colText(7)),
            .location = try allocator.dupe(u8, statement.colText(8)),
            .work_arrangement = try allocator.dupe(u8, statement.colText(9)),
            .interest_rating = statement.colOptionalInt(10),
            .money_rating = statement.colOptionalInt(11),
            .growth_rating = statement.colOptionalInt(12),
        },
        .status = try allocator.dupe(u8, statement.colText(13)),
        .current_stage_id = statement.colOptionalInt(14),
        .created_at = try allocator.dupe(u8, statement.colText(15)),
        .updated_at = try allocator.dupe(u8, statement.colText(16)),
    };
}

fn validateRating(value: ?i64, invalid: bool, target: *?[]const u8) void {
    if (invalid or (value != null and (value.? < 1 or value.? > 5))) {
        target.* = "Choose a rating from 1 to 5.";
    }
}

fn isDate(value: []const u8) bool {
    if (value.len != 10 or value[4] != '-' or value[7] != '-') return false;
    _ = std.fmt.parseInt(u16, value[0..4], 10) catch return false;
    const month = std.fmt.parseInt(u8, value[5..7], 10) catch return false;
    const day = std.fmt.parseInt(u8, value[8..10], 10) catch return false;
    return month >= 1 and month <= 12 and day >= 1 and day <= 31;
}

fn nullable(value: []const u8) ?[]const u8 {
    return if (value.len == 0) null else value;
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

test "ratings and application date validation" {
    const required = Input{
        .company_name = "Acme",
        .position_name = "Engineer",
        .applied_at = "2026-08-08",
    };
    try std.testing.expect(!validate(required).any());
    try std.testing.expect(!validate(.{
        .company_name = "Acme",
        .position_name = "Engineer",
        .applied_at = "2026-08-08",
        .interest_rating = 1,
        .money_rating = 5,
    }).any());
    try std.testing.expect(validate(.{
        .company_name = "Acme",
        .position_name = "Engineer",
        .applied_at = "2026-08-08",
        .interest_rating = 0,
    }).interest_rating != null);
    try std.testing.expect(validate(.{
        .company_name = "Acme",
        .position_name = "Engineer",
        .applied_at = "2026-08-08",
        .growth_rating = 6,
    }).growth_rating != null);
}
