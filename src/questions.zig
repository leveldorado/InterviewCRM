const std = @import("std");
const db = @import("database.zig");

pub const Kind = enum {
    company,
    learning,
};

pub const Question = struct {
    id: i64,
    process_id: i64,
    stage_id: ?i64,
    kind: Kind,
    question: []const u8,
    answer: ?[]const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

pub const Input = struct {
    process_id: i64,
    stage_id: ?i64 = null,
    kind: Kind,
    question: []const u8,
    answer: []const u8 = "",
};

pub fn listForProcess(
    allocator: std.mem.Allocator,
    database: *db.Database,
    process_id: i64,
    kind: Kind,
) ![]Question {
    return listQuery(
        allocator,
        database,
        \\SELECT id,process_id,stage_id,kind,question,answer,created_at,updated_at
        \\FROM questions WHERE process_id=? AND kind=? ORDER BY created_at,id
    ,
        process_id,
        null,
        kind,
    );
}

pub fn listForStage(
    allocator: std.mem.Allocator,
    database: *db.Database,
    process_id: i64,
    stage_id: i64,
    kind: Kind,
) ![]Question {
    return listQuery(
        allocator,
        database,
        \\SELECT id,process_id,stage_id,kind,question,answer,created_at,updated_at
        \\FROM questions WHERE process_id=? AND stage_id=? AND kind=?
        \\ORDER BY created_at,id
    ,
        process_id,
        stage_id,
        kind,
    );
}

pub fn create(database: *db.Database, input: Input) !i64 {
    try validateRelationship(database, input);
    const question = try validateQuestion(input.question);
    const answer = try validateAnswer(input.answer);
    var statement = try database.prepare(
        \\INSERT INTO questions(
        \\ process_id,stage_id,kind,question,answer,created_at,updated_at
        \\) VALUES(?,?,?,?,?,datetime('now'),datetime('now'))
    );
    defer statement.deinit();
    try statement.int(1, input.process_id);
    try statement.int(2, input.stage_id);
    try statement.text(3, @tagName(input.kind));
    try statement.text(4, question);
    try statement.text(5, nullable(answer));
    _ = try statement.step();
    return database.lastId();
}

pub fn update(database: *db.Database, id: i64, input: Input) !void {
    try validateRelationship(database, input);
    const question = try validateQuestion(input.question);
    const answer = try validateAnswer(input.answer);
    var statement = try database.prepare(
        \\UPDATE questions SET question=?,answer=?,updated_at=datetime('now')
        \\WHERE id=? AND process_id=? AND kind=?
        \\AND (stage_id IS ? OR stage_id=?)
    );
    defer statement.deinit();
    try statement.text(1, question);
    try statement.text(2, nullable(answer));
    try statement.int(3, id);
    try statement.int(4, input.process_id);
    try statement.text(5, @tagName(input.kind));
    try statement.int(6, input.stage_id);
    try statement.int(7, input.stage_id);
    _ = try statement.step();
    if (database.changes() == 0) return error.NotFound;
}

pub fn delete(database: *db.Database, id: i64, process_id: i64) !void {
    var statement = try database.prepare(
        "DELETE FROM questions WHERE id=? AND process_id=?",
    );
    defer statement.deinit();
    try statement.int(1, id);
    try statement.int(2, process_id);
    _ = try statement.step();
    if (database.changes() == 0) return error.NotFound;
}

pub fn get(
    allocator: std.mem.Allocator,
    database: *db.Database,
    id: i64,
) !?Question {
    var statement = try database.prepare(
        \\SELECT id,process_id,stage_id,kind,question,answer,created_at,updated_at
        \\FROM questions WHERE id=?
    );
    defer statement.deinit();
    try statement.int(1, id);
    if (!try statement.step()) return null;
    return try read(allocator, &statement);
}

fn validateQuestion(value: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 1000) {
        return error.InvalidQuestion;
    }
    return trimmed;
}

fn validateAnswer(value: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len > 10_000) return error.InvalidAnswer;
    return trimmed;
}

fn validateRelationship(database: *db.Database, input: Input) !void {
    if (input.stage_id) |stage_id| {
        var statement = try database.prepare(
            "SELECT 1 FROM stages WHERE id=? AND process_id=?",
        );
        defer statement.deinit();
        try statement.int(1, stage_id);
        try statement.int(2, input.process_id);
        if (!try statement.step()) return error.InvalidRelationship;
    }
}

fn listQuery(
    allocator: std.mem.Allocator,
    database: *db.Database,
    sql: [:0]const u8,
    process_id: i64,
    stage_id: ?i64,
    kind: Kind,
) ![]Question {
    var statement = try database.prepare(sql);
    defer statement.deinit();
    try statement.int(1, process_id);
    if (stage_id) |id| {
        try statement.int(2, id);
        try statement.text(3, @tagName(kind));
    } else {
        try statement.text(2, @tagName(kind));
    }
    var result: std.ArrayList(Question) = .empty;
    while (try statement.step()) {
        try result.append(allocator, try read(allocator, &statement));
    }
    return result.toOwnedSlice(allocator);
}

fn read(
    allocator: std.mem.Allocator,
    statement: *db.Statement,
) !Question {
    const kind: Kind = if (std.mem.eql(u8, statement.colText(3), "company"))
        .company
    else if (std.mem.eql(u8, statement.colText(3), "learning"))
        .learning
    else
        return error.UnknownQuestionKind;
    return .{
        .id = statement.colInt(0),
        .process_id = statement.colInt(1),
        .stage_id = statement.colOptionalInt(2),
        .kind = kind,
        .question = try allocator.dupe(u8, statement.colText(4)),
        .answer = if (statement.colOptionalText(5)) |value|
            try allocator.dupe(u8, value)
        else
            null,
        .created_at = try allocator.dupe(u8, statement.colText(6)),
        .updated_at = try allocator.dupe(u8, statement.colText(7)),
    };
}

fn nullable(value: []const u8) ?[]const u8 {
    return if (value.len == 0) null else value;
}
