const std = @import("std");
const db = @import("database.zig");

pub const initial_sql = @embedFile("migrations/001_initial_schema.sql");

pub fn apply(database: *db.Database) !void {
    try database.exec("CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, name TEXT NOT NULL, applied_at TEXT NOT NULL);");
    if (try database.scalarInt("SELECT count(*) FROM schema_migrations WHERE version=1") != 0) return;
    database.exec("BEGIN IMMEDIATE") catch |err| {
        std.log.err("migration 1 001_initial_schema failed", .{});
        return err;
    };
    errdefer database.exec("ROLLBACK") catch {};
    database.exec(initial_sql) catch |err| {
        std.log.err("migration 1 001_initial_schema failed", .{});
        return err;
    };
    try database.exec("INSERT INTO schema_migrations(version,name,applied_at) VALUES(1,'001_initial_schema',datetime('now'));");
    try database.exec("COMMIT");
}
