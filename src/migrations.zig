const std = @import("std");
const builtin = @import("builtin");
const db = @import("database.zig");

pub const Migration = struct {
    version: i64,
    name: []const u8,
    sql: [:0]const u8,
};

pub const registry = [_]Migration{
    .{
        .version = 1,
        .name = "initial_schema",
        .sql = @embedFile("migrations/001_initial_schema.sql"),
    },
    .{
        .version = 2,
        .name = "default_stages",
        .sql = @embedFile("migrations/002_default_stages.sql"),
    },
};

pub fn apply(database: *db.Database) !void {
    return applyRegistry(database, &registry);
}

pub fn applyRegistry(database: *db.Database, migrations: []const Migration) !void {
    try database.exec("CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, name TEXT NOT NULL, applied_at TEXT NOT NULL);");
    var previous: i64 = 0;
    for (migrations) |migration| {
        if (migration.version <= previous) return error.MigrationsNotOrdered;
        previous = migration.version;
        if (try isApplied(database, migration.version)) continue;

        database.begin() catch |err| {
            logFailure(database, migration, "begin");
            return err;
        };
        errdefer database.rollback() catch {};

        database.exec(migration.sql) catch |err| {
            logFailure(database, migration, "execute");
            return err;
        };
        record(database, migration) catch |err| {
            logFailure(database, migration, "record");
            return err;
        };
        database.commit() catch |err| {
            logFailure(database, migration, "commit");
            return err;
        };
    }
}

fn isApplied(database: *db.Database, version: i64) !bool {
    var statement = try database.prepare("SELECT 1 FROM schema_migrations WHERE version=?");
    defer statement.deinit();
    try statement.int(1, version);
    return try statement.step();
}

fn record(database: *db.Database, migration: Migration) !void {
    var statement = try database.prepare("INSERT INTO schema_migrations(version,name,applied_at) VALUES(?,?,datetime('now'))");
    defer statement.deinit();
    try statement.int(1, migration.version);
    try statement.text(2, migration.name);
    _ = try statement.step();
}

fn logFailure(database: *db.Database, migration: Migration, operation: []const u8) void {
    _ = database;
    if (builtin.is_test) return;
    std.log.err("migration {d} {s} failed during {s}", .{ migration.version, migration.name, operation });
}

test "multiple registered migrations apply in order" {
    var database = try db.Database.open(":memory:");
    defer database.close();
    const test_registry = [_]Migration{
        .{
            .version = 1,
            .name = "one",
            .sql = "CREATE TABLE one(id INTEGER);",
        },
        .{
            .version = 2,
            .name = "two",
            .sql = "CREATE TABLE two(id INTEGER);",
        },
    };
    try applyRegistry(&database, &test_registry);
    try std.testing.expectEqual(@as(i64, 2), try database.scalarInt("SELECT count(*) FROM schema_migrations"));
}

test "failed migration rolls back SQL and history" {
    var database = try db.Database.open(":memory:");
    defer database.close();
    const broken = [_]Migration{
        .{
            .version = 1,
            .name = "broken",
            .sql = "CREATE TABLE should_rollback(id INTEGER); THIS IS NOT SQL;",
        },
    };
    try std.testing.expectError(error.Sqlite, applyRegistry(&database, &broken));
    try std.testing.expectEqual(@as(i64, 0), try database.scalarInt("SELECT count(*) FROM schema_migrations"));
    try std.testing.expectEqual(@as(i64, 0), try database.scalarInt("SELECT count(*) FROM sqlite_master WHERE name='should_rollback'"));
}

test "default-stage migration backfills only stage-less processes" {
    var database = try db.Database.open(":memory:");
    defer database.close();
    try applyRegistry(&database, registry[0..1]);
    try database.exec(
        "INSERT INTO job_processes(id,company_name,position_name,created_at,updated_at) VALUES(1,'Old','Role',datetime('now'),datetime('now'));" ++
            "INSERT INTO job_processes(id,company_name,position_name,created_at,updated_at) VALUES(2,'Custom','Role',datetime('now'),datetime('now'));" ++
            "INSERT INTO job_processes(id,company_name,position_name,created_at,updated_at) VALUES(3,'Custom no pointer','Role',datetime('now'),datetime('now'));" ++
            "INSERT INTO stages(id,process_id,name,position,status,created_at,updated_at) VALUES(20,2,'Hiring manager',1,'scheduled',datetime('now'),datetime('now'));" ++
            "INSERT INTO stages(id,process_id,name,position,status,created_at,updated_at) VALUES(30,3,'Founder call',1,'planned',datetime('now'),datetime('now'));" ++
            "UPDATE job_processes SET current_stage_id=20 WHERE id=2;",
    );

    try apply(&database);
    try apply(&database);
    try std.testing.expectEqual(
        @as(i64, 7),
        try database.scalarInt("SELECT count(*) FROM stages WHERE process_id=1"),
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        try database.scalarInt("SELECT count(*) FROM stages WHERE process_id=2"),
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        try database.scalarInt("SELECT position FROM stages WHERE id=(SELECT current_stage_id FROM job_processes WHERE id=1)"),
    );
    try std.testing.expectEqual(
        @as(i64, 20),
        try database.scalarInt("SELECT current_stage_id FROM job_processes WHERE id=2"),
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        try database.scalarInt("SELECT count(*) FROM job_processes WHERE id=3 AND current_stage_id IS NULL"),
    );
}
