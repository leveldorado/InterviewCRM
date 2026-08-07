const std = @import("std");
const db = @import("database.zig");

pub const Note = struct {
    id: i64,
    process_id: i64,
    stage_id: i64,
    body: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

pub const Input = struct {
    body: []const u8 = "",
};

pub const Errors = struct {
    body: ?[]const u8 = null,

    pub fn any(errors: Errors) bool {
        return errors.body != null;
    }
};

pub fn validate(input: Input) Errors {
    const body = std.mem.trim(u8, input.body, " \t\r\n");
    if (body.len == 0) return .{ .body = "Note text is required." };
    if (body.len > 5000) return .{ .body = "Note must be 5,000 characters or fewer." };
    return .{};
}

pub fn listForStage(
    allocator: std.mem.Allocator,
    database: *db.Database,
    process_id: i64,
    stage_id: i64,
) ![]Note {
    try verifyStage(database, process_id, stage_id);
    var statement = try database.prepare(
        "SELECT id,process_id,stage_id,body,created_at,updated_at FROM notes WHERE process_id=? AND stage_id=? AND category='general' ORDER BY created_at,id",
    );
    defer statement.deinit();
    try statement.int(1, process_id);
    try statement.int(2, stage_id);
    var result: std.ArrayList(Note) = .empty;
    while (try statement.step()) {
        try result.append(allocator, try read(allocator, &statement));
    }
    return result.toOwnedSlice(allocator);
}

pub fn createForStage(
    database: *db.Database,
    process_id: i64,
    stage_id: i64,
    input: Input,
) !i64 {
    if (validate(input).any()) return error.InvalidInput;
    try verifyStage(database, process_id, stage_id);
    const body = std.mem.trim(u8, input.body, " \t\r\n");
    var statement = try database.prepare(
        "INSERT INTO notes(process_id,stage_id,category,body,created_at,updated_at) VALUES(?,?,'general',?,datetime('now'),datetime('now'))",
    );
    defer statement.deinit();
    try statement.int(1, process_id);
    try statement.int(2, stage_id);
    try statement.text(3, body);
    _ = try statement.step();
    return database.lastId();
}

pub fn updateStageNote(
    database: *db.Database,
    process_id: i64,
    stage_id: i64,
    note_id: i64,
    input: Input,
) !void {
    if (validate(input).any()) return error.InvalidInput;
    const body = std.mem.trim(u8, input.body, " \t\r\n");
    var statement = try database.prepare(
        "UPDATE notes SET body=?,updated_at=datetime('now') WHERE id=? AND process_id=? AND stage_id=? AND category='general'",
    );
    defer statement.deinit();
    try statement.text(1, body);
    try statement.int(2, note_id);
    try statement.int(3, process_id);
    try statement.int(4, stage_id);
    _ = try statement.step();
    if (database.changes() == 0) return error.NotFound;
}

pub fn deleteStageNote(
    database: *db.Database,
    process_id: i64,
    stage_id: i64,
    note_id: i64,
) !void {
    var statement = try database.prepare(
        "DELETE FROM notes WHERE id=? AND process_id=? AND stage_id=? AND category='general'",
    );
    defer statement.deinit();
    try statement.int(1, note_id);
    try statement.int(2, process_id);
    try statement.int(3, stage_id);
    _ = try statement.step();
    if (database.changes() == 0) return error.NotFound;
}

pub fn get(
    allocator: std.mem.Allocator,
    database: *db.Database,
    note_id: i64,
) !?Note {
    var statement = try database.prepare(
        "SELECT id,process_id,stage_id,body,created_at,updated_at FROM notes WHERE id=? AND category='general'",
    );
    defer statement.deinit();
    try statement.int(1, note_id);
    if (!try statement.step()) return null;
    return try read(allocator, &statement);
}

fn verifyStage(
    database: *db.Database,
    process_id: i64,
    stage_id: i64,
) !void {
    var statement = try database.prepare(
        "SELECT 1 FROM stages WHERE id=? AND process_id=?",
    );
    defer statement.deinit();
    try statement.int(1, stage_id);
    try statement.int(2, process_id);
    if (!try statement.step()) return error.InvalidRelationship;
}

fn read(
    allocator: std.mem.Allocator,
    statement: *db.Statement,
) !Note {
    return .{
        .id = statement.colInt(0),
        .process_id = statement.colInt(1),
        .stage_id = statement.colInt(2),
        .body = try allocator.dupe(u8, statement.colText(3)),
        .created_at = try allocator.dupe(u8, statement.colText(4)),
        .updated_at = try allocator.dupe(u8, statement.colText(5)),
    };
}

test "note validation preserves line breaks while trimming edges" {
    try std.testing.expect(validate(.{}).body != null);
    try std.testing.expect(!validate(.{ .body = "first\nsecond" }).any());
}
