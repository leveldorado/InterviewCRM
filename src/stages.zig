const std = @import("std");
const db = @import("database.zig");

pub const Status = enum {
    planned,
    scheduled,
    in_progress,
    completed,
    skipped,
    cancelled,
};

pub const Kind = enum {
    applied,
    hr,
    technical,
    system_design,
    cultural_fit,
    cto,
    offer,
    custom,
};

pub const Outcome = enum {
    next_step,
    rejected,
    withdrawn,
    accepted,
    declined,
};

pub const Stage = struct {
    id: i64,
    process_id: i64,
    name: []const u8,
    kind: Kind,
    position: i64,
    status: Status,
    outcome: ?Outcome,
    outcome_reason: ?[]const u8,
    started_at: ?[]const u8,
    completed_at: ?[]const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

pub const Template = struct {
    kind: Kind,
    name: []const u8,
};

pub const templates = [_]Template{
    .{
        .kind = .hr,
        .name = "HR Interview",
    },
    .{
        .kind = .technical,
        .name = "Technical Interview",
    },
    .{
        .kind = .system_design,
        .name = "System Design Interview",
    },
    .{
        .kind = .cultural_fit,
        .name = "Cultural Fit",
    },
    .{
        .kind = .cto,
        .name = "CTO Interview",
    },
    .{
        .kind = .offer,
        .name = "Offer",
    },
    .{
        .kind = .custom,
        .name = "Custom",
    },
};

pub fn statusText(status: Status) []const u8 {
    return @tagName(status);
}

pub fn kindText(kind: Kind) []const u8 {
    return @tagName(kind);
}

pub fn outcomeText(outcome: Outcome) []const u8 {
    return @tagName(outcome);
}

pub fn parseStatus(value: []const u8) !Status {
    inline for (std.meta.tags(Status)) |item| {
        if (std.mem.eql(u8, value, @tagName(item))) return item;
    }
    return error.UnknownStageStatus;
}

pub fn parseKind(value: []const u8) !Kind {
    inline for (std.meta.tags(Kind)) |item| {
        if (std.mem.eql(u8, value, @tagName(item))) return item;
    }
    return error.UnknownStageKind;
}

pub fn parseOutcome(value: []const u8) !Outcome {
    inline for (std.meta.tags(Outcome)) |item| {
        if (std.mem.eql(u8, value, @tagName(item))) return item;
    }
    return error.UnknownStageOutcome;
}

pub fn outcomeAllowed(kind: Kind, outcome: Outcome) bool {
    return switch (kind) {
        .offer => outcome == .accepted or outcome == .declined or
            outcome == .withdrawn,
        else => outcome == .next_step or outcome == .rejected or
            outcome == .withdrawn,
    };
}

pub fn createApplied(
    database: *db.Database,
    process_id: i64,
    applied_at: []const u8,
) !i64 {
    var insert = try database.prepare(
        \\INSERT INTO stages(
        \\ process_id,name,kind,position,status,started_at,created_at,updated_at
        \\) VALUES(?,'Applied','applied',1,'in_progress',?,datetime('now'),datetime('now'))
    );
    defer insert.deinit();
    try insert.int(1, process_id);
    try insert.text(2, applied_at);
    _ = try insert.step();
    const stage_id = database.lastId();

    var update = try database.prepare(
        "UPDATE job_processes SET current_stage_id=? WHERE id=?",
    );
    defer update.deinit();
    try update.int(1, stage_id);
    try update.int(2, process_id);
    _ = try update.step();
    if (database.changes() == 0) return error.NotFound;
    return stage_id;
}

pub fn listForProcess(
    allocator: std.mem.Allocator,
    database: *db.Database,
    process_id: i64,
) ![]Stage {
    var statement = try database.prepare(
        \\SELECT id,process_id,name,kind,position,status,outcome,outcome_reason,
        \\ started_at,completed_at,created_at,updated_at
        \\FROM stages WHERE process_id=? ORDER BY position,id
    );
    defer statement.deinit();
    try statement.int(1, process_id);
    var result: std.ArrayList(Stage) = .empty;
    while (try statement.step()) {
        try result.append(allocator, try read(allocator, &statement));
    }
    return result.toOwnedSlice(allocator);
}

pub fn get(
    allocator: std.mem.Allocator,
    database: *db.Database,
    stage_id: i64,
) !?Stage {
    var statement = try database.prepare(
        \\SELECT id,process_id,name,kind,position,status,outcome,outcome_reason,
        \\ started_at,completed_at,created_at,updated_at
        \\FROM stages WHERE id=?
    );
    defer statement.deinit();
    try statement.int(1, stage_id);
    if (!try statement.step()) return null;
    return try read(allocator, &statement);
}

pub fn add(
    allocator: std.mem.Allocator,
    database: *db.Database,
    process_id: i64,
    kind: Kind,
    submitted_name: []const u8,
) !i64 {
    if (kind == .applied) return error.InvalidStageKind;
    const name = if (kind == .custom)
        std.mem.trim(u8, submitted_name, " \t\r\n")
    else
        nameForKind(kind);
    if (name.len == 0 or name.len > 120) return error.InvalidStageName;

    try database.begin();
    errdefer database.rollback() catch {};
    const current_stage_id = try processCurrentStage(database, process_id);
    const status: Status = if (current_stage_id == null)
        .in_progress
    else
        .planned;

    var insert = try database.prepare(
        \\INSERT INTO stages(
        \\ process_id,name,kind,position,status,started_at,created_at,updated_at
        \\) SELECT ?,?,?,COALESCE(MAX(position),0)+1,?,
        \\ CASE WHEN ?='in_progress' THEN datetime('now') ELSE NULL END,
        \\ datetime('now'),datetime('now') FROM stages WHERE process_id=?
    );
    defer insert.deinit();
    try insert.int(1, process_id);
    try insert.text(2, name);
    try insert.text(3, kindText(kind));
    try insert.text(4, statusText(status));
    try insert.text(5, statusText(status));
    try insert.int(6, process_id);
    _ = try insert.step();
    const stage_id = database.lastId();

    if (current_stage_id == null) {
        try setCurrent(database, process_id, stage_id, kind);
    }
    const description = try std.fmt.allocPrint(
        allocator,
        "Added stage: {s}",
        .{name},
    );
    try addActivity(database, process_id, "stage_added", description);
    try database.commit();
    return stage_id;
}

pub fn addCustom(
    allocator: std.mem.Allocator,
    database: *db.Database,
    process_id: i64,
    name: []const u8,
) !i64 {
    return add(allocator, database, process_id, .custom, name);
}

pub fn setOutcome(
    allocator: std.mem.Allocator,
    database: *db.Database,
    stage_id: i64,
    outcome: Outcome,
    reason_value: []const u8,
) !i64 {
    try database.begin();
    errdefer database.rollback() catch {};
    const stage = (try get(allocator, database, stage_id)) orelse
        return error.NotFound;
    const current_stage_id = try processCurrentStage(database, stage.process_id);
    if (current_stage_id != stage.id or
        (stage.status != .in_progress and stage.status != .scheduled) or
        !outcomeAllowed(stage.kind, outcome))
    {
        return error.InvalidTransition;
    }

    const reason = std.mem.trim(u8, reason_value, " \t\r\n");
    var update_stage = try database.prepare(
        \\UPDATE stages SET status='completed',outcome=?,outcome_reason=?,
        \\ completed_at=datetime('now'),updated_at=datetime('now') WHERE id=?
    );
    defer update_stage.deinit();
    try update_stage.text(1, outcomeText(outcome));
    try update_stage.text(2, nullable(reason));
    try update_stage.int(3, stage.id);
    _ = try update_stage.step();

    switch (outcome) {
        .next_step => try advance(database, stage),
        .rejected => try closeProcess(
            database,
            stage.process_id,
            "rejected",
            nullable(reason),
        ),
        .withdrawn => try closeProcess(
            database,
            stage.process_id,
            "withdrawn",
            nullable(reason),
        ),
        .accepted => try closeProcess(
            database,
            stage.process_id,
            "accepted",
            null,
        ),
        .declined => try closeProcess(
            database,
            stage.process_id,
            "declined",
            nullable(reason),
        ),
    }

    const description = try outcomeActivity(allocator, stage, outcome);
    try addActivity(database, stage.process_id, "stage_outcome", description);
    try database.commit();
    return stage.process_id;
}

pub fn skip(
    allocator: std.mem.Allocator,
    database: *db.Database,
    stage_id: i64,
) !i64 {
    try database.begin();
    errdefer database.rollback() catch {};
    const stage = (try get(allocator, database, stage_id)) orelse
        return error.NotFound;
    const current_stage_id = try processCurrentStage(database, stage.process_id);
    const allowed = stage.status == .planned or
        (current_stage_id == stage.id and
            (stage.status == .in_progress or stage.status == .scheduled));
    if (!allowed) return error.InvalidTransition;

    var statement = try database.prepare(
        "UPDATE stages SET status='skipped',completed_at=datetime('now'),updated_at=datetime('now') WHERE id=?",
    );
    defer statement.deinit();
    try statement.int(1, stage.id);
    _ = try statement.step();
    if (current_stage_id == stage.id) try advance(database, stage);
    const description = try std.fmt.allocPrint(
        allocator,
        "Skipped stage: {s}",
        .{stage.name},
    );
    try addActivity(database, stage.process_id, "stage_skipped", description);
    try database.commit();
    return stage.process_id;
}

pub fn reopen(
    allocator: std.mem.Allocator,
    database: *db.Database,
    stage_id: i64,
) !i64 {
    try database.begin();
    errdefer database.rollback() catch {};
    const stage = (try get(allocator, database, stage_id)) orelse
        return error.NotFound;
    if (stage.status != .completed and stage.status != .skipped) {
        return error.InvalidTransition;
    }

    var update_stage = try database.prepare(
        \\UPDATE stages SET status='in_progress',outcome=NULL,outcome_reason=NULL,
        \\ completed_at=NULL,started_at=COALESCE(started_at,datetime('now')),
        \\ updated_at=datetime('now') WHERE id=?
    );
    defer update_stage.deinit();
    try update_stage.int(1, stage.id);
    _ = try update_stage.step();

    var update_process = try database.prepare(
        \\UPDATE job_processes SET current_stage_id=?,status=?,closed_at=NULL,
        \\ closure_reason_text=NULL,closure_reason_code=NULL,
        \\ updated_at=datetime('now') WHERE id=?
    );
    defer update_process.deinit();
    try update_process.int(1, stage.id);
    try update_process.text(2, if (stage.kind == .offer) "offer_received" else "active");
    try update_process.int(3, stage.process_id);
    _ = try update_process.step();

    const description = try std.fmt.allocPrint(
        allocator,
        "Reopened stage: {s}",
        .{stage.name},
    );
    try addActivity(database, stage.process_id, "stage_reopened", description);
    try database.commit();
    return stage.process_id;
}

// Kept as a domain compatibility wrapper. The primary UI is outcome-based.
pub fn complete(
    allocator: std.mem.Allocator,
    database: *db.Database,
    stage_id: i64,
) !i64 {
    return setOutcome(allocator, database, stage_id, .next_step, "");
}

fn advance(database: *db.Database, stage: Stage) !void {
    var next_statement = try database.prepare(
        \\SELECT id,status,kind FROM stages
        \\WHERE process_id=? AND position>? AND status NOT IN ('completed','skipped','cancelled')
        \\ORDER BY position,id LIMIT 1
    );
    defer next_statement.deinit();
    try next_statement.int(1, stage.process_id);
    try next_statement.int(2, stage.position);
    if (!try next_statement.step()) {
        return setCurrent(database, stage.process_id, null, null);
    }
    const next_id = next_statement.colInt(0);
    const next_status = try parseStatus(next_statement.colText(1));
    const next_kind = try parseKind(next_statement.colText(2));
    if (next_status == .planned) {
        var activate = try database.prepare(
            \\UPDATE stages SET status='in_progress',
            \\ started_at=COALESCE(started_at,datetime('now')),
            \\ updated_at=datetime('now') WHERE id=?
        );
        defer activate.deinit();
        try activate.int(1, next_id);
        _ = try activate.step();
    }
    try setCurrent(database, stage.process_id, next_id, next_kind);
}

fn setCurrent(
    database: *db.Database,
    process_id: i64,
    stage_id: ?i64,
    kind: ?Kind,
) !void {
    var statement = try database.prepare(
        "UPDATE job_processes SET current_stage_id=?,status=?,updated_at=datetime('now') WHERE id=?",
    );
    defer statement.deinit();
    try statement.int(1, stage_id);
    try statement.text(2, if (kind == .offer) "offer_received" else "active");
    try statement.int(3, process_id);
    _ = try statement.step();
    if (database.changes() == 0) return error.NotFound;
}

fn closeProcess(
    database: *db.Database,
    process_id: i64,
    status: []const u8,
    reason: ?[]const u8,
) !void {
    var statement = try database.prepare(
        \\UPDATE job_processes SET status=?,current_stage_id=NULL,closed_at=datetime('now'),
        \\ closure_reason_text=?,updated_at=datetime('now') WHERE id=?
    );
    defer statement.deinit();
    try statement.text(1, status);
    try statement.text(2, reason);
    try statement.int(3, process_id);
    _ = try statement.step();
}

fn processCurrentStage(database: *db.Database, process_id: i64) !?i64 {
    var statement = try database.prepare(
        "SELECT current_stage_id FROM job_processes WHERE id=?",
    );
    defer statement.deinit();
    try statement.int(1, process_id);
    if (!try statement.step()) return error.NotFound;
    return statement.colOptionalInt(0);
}

fn nameForKind(kind: Kind) []const u8 {
    return switch (kind) {
        .applied => "Applied",
        .hr => "HR Interview",
        .technical => "Technical Interview",
        .system_design => "System Design Interview",
        .cultural_fit => "Cultural Fit",
        .cto => "CTO Interview",
        .offer => "Offer",
        .custom => "Custom",
    };
}

fn outcomeActivity(
    allocator: std.mem.Allocator,
    stage: Stage,
    outcome: Outcome,
) ![]const u8 {
    return switch (outcome) {
        .next_step => std.fmt.allocPrint(allocator, "Next step after {s}", .{stage.name}),
        .rejected => std.fmt.allocPrint(allocator, "Rejected after {s}", .{stage.name}),
        .withdrawn => std.fmt.allocPrint(allocator, "Withdrew after {s}", .{stage.name}),
        .accepted => allocator.dupe(u8, "Accepted offer"),
        .declined => allocator.dupe(u8, "Declined offer"),
    };
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
) !Stage {
    return .{
        .id = statement.colInt(0),
        .process_id = statement.colInt(1),
        .name = try allocator.dupe(u8, statement.colText(2)),
        .kind = try parseKind(statement.colText(3)),
        .position = statement.colInt(4),
        .status = try parseStatus(statement.colText(5)),
        .outcome = if (statement.colOptionalText(6)) |value|
            try parseOutcome(value)
        else
            null,
        .outcome_reason = try optionalDupe(
            allocator,
            statement.colOptionalText(7),
        ),
        .started_at = try optionalDupe(allocator, statement.colOptionalText(8)),
        .completed_at = try optionalDupe(
            allocator,
            statement.colOptionalText(9),
        ),
        .created_at = try allocator.dupe(u8, statement.colText(10)),
        .updated_at = try allocator.dupe(u8, statement.colText(11)),
    };
}

fn optionalDupe(
    allocator: std.mem.Allocator,
    value: ?[]const u8,
) !?[]const u8 {
    return if (value) |text| try allocator.dupe(u8, text) else null;
}

fn nullable(value: []const u8) ?[]const u8 {
    return if (value.len == 0) null else value;
}
