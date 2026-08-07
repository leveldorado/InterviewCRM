const std = @import("std");
const db = @import("database.zig");

pub const Source = struct {
    id: i64,
    name: []const u8,
};

pub fn list(
    allocator: std.mem.Allocator,
    database: *db.Database,
) ![]Source {
    var statement = try database.prepare(
        "SELECT id,name FROM sources ORDER BY name COLLATE NOCASE",
    );
    defer statement.deinit();
    var result: std.ArrayList(Source) = .empty;
    while (try statement.step()) {
        try result.append(allocator, .{
            .id = statement.colInt(0),
            .name = try allocator.dupe(u8, statement.colText(1)),
        });
    }
    return result.toOwnedSlice(allocator);
}

pub fn create(database: *db.Database, submitted_name: []const u8) !i64 {
    const name = std.mem.trim(u8, submitted_name, " \t\r\n");
    if (name.len == 0 or name.len > 120) return error.InvalidSourceName;
    var existing = try database.prepare(
        "SELECT id FROM sources WHERE name=? COLLATE NOCASE",
    );
    defer existing.deinit();
    try existing.text(1, name);
    if (try existing.step()) return existing.colInt(0);
    var insert = try database.prepare(
        "INSERT INTO sources(name,created_at) VALUES(?,datetime('now'))",
    );
    defer insert.deinit();
    try insert.text(1, name);
    _ = try insert.step();
    return database.lastId();
}
