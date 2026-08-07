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

pub const Stage = struct {
    id: i64,
    process_id: i64,
    name: []const u8,
    position: i64,
    status: Status,
    started_at: ?[]const u8,
    completed_at: ?[]const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

pub const DefaultStage = struct {
    name: []const u8,
    status: Status,
};

pub const default_stages = [_]DefaultStage{
    .{ .name = "Resume sent", .status = .in_progress },
    .{ .name = "Recruiter / HR interview", .status = .planned },
    .{ .name = "Technical interview", .status = .planned },
    .{ .name = "Technical assignment", .status = .planned },
    .{ .name = "Cultural fit interview", .status = .planned },
    .{ .name = "Final interview", .status = .planned },
    .{ .name = "Offer", .status = .planned },
};

pub fn statusText(status: Status) []const u8 {
    return switch (status) {
        .planned => "planned",
        .scheduled => "scheduled",
        .in_progress => "in_progress",
        .completed => "completed",
        .skipped => "skipped",
        .cancelled => "cancelled",
    };
}

pub fn parseStatus(value: []const u8) !Status {
    inline for (std.meta.tags(Status)) |status| {
        if (std.mem.eql(u8, value, statusText(status))) return status;
    }
    return error.UnknownStageStatus;
}

pub fn createDefaults(database: *db.Database, process_id: i64) !i64 {
    var insert = try database.prepare(
        "INSERT INTO stages(process_id,name,position,status,started_at,created_at,updated_at) VALUES(?,?,?,?,CASE WHEN ?='in_progress' THEN datetime('now') ELSE NULL END,datetime('now'),datetime('now'))",
    );
    defer insert.deinit();

    var first_stage_id: i64 = 0;
    for (default_stages, 1..) |definition, position| {
        if (position > 1) try insert.reset();
        try insert.int(1, process_id);
        try insert.text(2, definition.name);
        try insert.int(3, @intCast(position));
        try insert.text(4, statusText(definition.status));
        try insert.text(5, statusText(definition.status));
        _ = try insert.step();
        if (position == 1) first_stage_id = database.lastId();
    }

    var update = try database.prepare(
        "UPDATE job_processes SET current_stage_id=?,updated_at=datetime('now') WHERE id=?",
    );
    defer update.deinit();
    try update.int(1, first_stage_id);
    try update.int(2, process_id);
    _ = try update.step();
    if (database.changes() == 0) return error.NotFound;
    return first_stage_id;
}

pub fn listForProcess(
    allocator: std.mem.Allocator,
    database: *db.Database,
    process_id: i64,
) ![]Stage {
    var statement = try database.prepare(
        "SELECT id,process_id,name,position,status,started_at,completed_at,created_at,updated_at FROM stages WHERE process_id=? ORDER BY position,id",
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
        "SELECT id,process_id,name,position,status,started_at,completed_at,created_at,updated_at FROM stages WHERE id=?",
    );
    defer statement.deinit();
    try statement.int(1, stage_id);
    if (!try statement.step()) return null;
    return try read(allocator, &statement);
}

pub fn addCustom(
    allocator: std.mem.Allocator,
    database: *db.Database,
    process_id: i64,
    submitted_name: []const u8,
) !i64 {
    const name = std.mem.trim(u8, submitted_name, " \t\r\n");
    if (name.len == 0 or name.len > 120) return error.InvalidStageName;

    try database.begin();
    errdefer database.rollback() catch {};

    var process_statement = try database.prepare(
        "SELECT current_stage_id FROM job_processes WHERE id=?",
    );
    defer process_statement.deinit();
    try process_statement.int(1, process_id);
    if (!try process_statement.step()) return error.NotFound;
    const current_stage_id = process_statement.colOptionalInt(0);

    var insert = try database.prepare(
        "INSERT INTO stages(process_id,name,position,status,started_at,created_at,updated_at) SELECT ?,?,COALESCE(MAX(position),0)+1,?,CASE WHEN ?='in_progress' THEN datetime('now') ELSE NULL END,datetime('now'),datetime('now') FROM stages WHERE process_id=?",
    );
    defer insert.deinit();
    const status: Status = if (current_stage_id == null) .in_progress else .planned;
    try insert.int(1, process_id);
    try insert.text(2, name);
    try insert.text(3, statusText(status));
    try insert.text(4, statusText(status));
    try insert.int(5, process_id);
    _ = try insert.step();
    const stage_id = database.lastId();

    if (current_stage_id == null) {
        var update = try database.prepare(
            "UPDATE job_processes SET current_stage_id=?,updated_at=datetime('now') WHERE id=?",
        );
        defer update.deinit();
        try update.int(1, stage_id);
        try update.int(2, process_id);
        _ = try update.step();
    }

    const description = try std.fmt.allocPrint(allocator, "Added stage: {s}", .{name});
    try addActivity(database, process_id, "stage_added", description);
    try database.commit();
    return stage_id;
}

pub fn complete(
    allocator: std.mem.Allocator,
    database: *db.Database,
    stage_id: i64,
) !i64 {
    return transition(allocator, database, stage_id, .completed);
}

pub fn skip(
    allocator: std.mem.Allocator,
    database: *db.Database,
    stage_id: i64,
) !i64 {
    return transition(allocator, database, stage_id, .skipped);
}

pub fn reopen(
    allocator: std.mem.Allocator,
    database: *db.Database,
    stage_id: i64,
) !i64 {
    try database.begin();
    errdefer database.rollback() catch {};
    const stage = (try get(allocator, database, stage_id)) orelse return error.NotFound;
    if (stage.status != .completed and stage.status != .skipped) {
        return error.InvalidTransition;
    }

    var update_stage = try database.prepare(
        "UPDATE stages SET status='in_progress',completed_at=NULL,started_at=COALESCE(started_at,datetime('now')),updated_at=datetime('now') WHERE id=?",
    );
    defer update_stage.deinit();
    try update_stage.int(1, stage_id);
    _ = try update_stage.step();

    var update_process = try database.prepare(
        "UPDATE job_processes SET current_stage_id=?,updated_at=datetime('now') WHERE id=?",
    );
    defer update_process.deinit();
    try update_process.int(1, stage_id);
    try update_process.int(2, stage.process_id);
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

fn transition(
    allocator: std.mem.Allocator,
    database: *db.Database,
    stage_id: i64,
    destination: Status,
) !i64 {
    try database.begin();
    errdefer database.rollback() catch {};
    const stage = (try get(allocator, database, stage_id)) orelse return error.NotFound;
    if (stage.status == destination) return error.InvalidTransition;
    if (stage.status == .completed or stage.status == .skipped or stage.status == .cancelled) {
        return error.InvalidTransition;
    }

    var update_stage = try database.prepare(
        "UPDATE stages SET status=?,completed_at=datetime('now'),updated_at=datetime('now') WHERE id=?",
    );
    defer update_stage.deinit();
    try update_stage.text(1, statusText(destination));
    try update_stage.int(2, stage_id);
    _ = try update_stage.step();

    var current = try database.prepare(
        "SELECT current_stage_id FROM job_processes WHERE id=?",
    );
    defer current.deinit();
    try current.int(1, stage.process_id);
    if (!try current.step()) return error.NotFound;
    if (current.colOptionalInt(0) == stage_id) {
        try advance(database, stage);
    }

    const verb = if (destination == .completed) "Completed" else "Skipped";
    const activity_type = if (destination == .completed)
        "stage_completed"
    else
        "stage_skipped";
    const description = try std.fmt.allocPrint(
        allocator,
        "{s} stage: {s}",
        .{ verb, stage.name },
    );
    try addActivity(database, stage.process_id, activity_type, description);
    try database.commit();
    return stage.process_id;
}

fn advance(database: *db.Database, stage: Stage) !void {
    var next_statement = try database.prepare(
        "SELECT id,status FROM stages WHERE process_id=? AND position>? AND status NOT IN ('completed','skipped','cancelled') ORDER BY position,id LIMIT 1",
    );
    defer next_statement.deinit();
    try next_statement.int(1, stage.process_id);
    try next_statement.int(2, stage.position);
    const has_next = try next_statement.step();
    const next_id: ?i64 = if (has_next) next_statement.colInt(0) else null;
    if (has_next and try parseStatus(next_statement.colText(1)) == .planned) {
        var activate = try database.prepare(
            "UPDATE stages SET status='in_progress',started_at=COALESCE(started_at,datetime('now')),updated_at=datetime('now') WHERE id=?",
        );
        defer activate.deinit();
        try activate.int(1, next_id);
        _ = try activate.step();
    }

    var update_process = try database.prepare(
        "UPDATE job_processes SET current_stage_id=?,updated_at=datetime('now') WHERE id=?",
    );
    defer update_process.deinit();
    try update_process.int(1, next_id);
    try update_process.int(2, stage.process_id);
    _ = try update_process.step();
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
        .position = statement.colInt(3),
        .status = try parseStatus(statement.colText(4)),
        .started_at = try dupeOptional(allocator, statement.colOptionalText(5)),
        .completed_at = try dupeOptional(allocator, statement.colOptionalText(6)),
        .created_at = try allocator.dupe(u8, statement.colText(7)),
        .updated_at = try allocator.dupe(u8, statement.colText(8)),
    };
}

fn dupeOptional(
    allocator: std.mem.Allocator,
    value: ?[]const u8,
) !?[]const u8 {
    return if (value) |text| try allocator.dupe(u8, text) else null;
}
