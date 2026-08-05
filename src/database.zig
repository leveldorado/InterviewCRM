const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Database = struct {
    handle: *c.sqlite3,
    pub fn open(path: [:0]const u8) !Database {
        var h: ?*c.sqlite3 = null;
        if (c.sqlite3_open(path.ptr, &h) != c.SQLITE_OK) return error.DatabaseOpen;
        var self = Database{ .handle = h.? };
        errdefer self.close();
        try self.exec("PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;");
        return self;
    }
    pub fn close(self: *Database) void {
        _ = c.sqlite3_close(self.handle);
    }
    pub fn exec(self: *Database, sql: [:0]const u8) !void {
        var msg: [*c]u8 = null;
        if (c.sqlite3_exec(self.handle, sql.ptr, null, null, &msg) != c.SQLITE_OK) {
            if (msg != null) c.sqlite3_free(msg);
            return error.Sqlite;
        }
    }
    pub fn scalarInt(self: *Database, sql: [:0]const u8) !i64 {
        var st: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &st, null) != c.SQLITE_OK) return error.Sqlite;
        defer _ = c.sqlite3_finalize(st);
        if (c.sqlite3_step(st) != c.SQLITE_ROW) return error.Sqlite;
        return c.sqlite3_column_int64(st, 0);
    }
    pub fn lastId(self: *Database) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }
    pub fn changes(self: *Database) i32 {
        return c.sqlite3_changes(self.handle);
    }
    pub fn prepare(self: *Database, sql: [:0]const u8) !Statement {
        var st: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &st, null) != c.SQLITE_OK) return error.Sqlite;
        return .{ .handle = st.? };
    }
};

pub const Statement = struct {
    handle: *c.sqlite3_stmt,
    pub fn deinit(self: *Statement) void {
        _ = c.sqlite3_finalize(self.handle);
    }
    pub fn text(self: *Statement, i: c_int, value: ?[]const u8) !void {
        const rc = if (value) |v| c.sqlite3_bind_text(self.handle, i, v.ptr, @intCast(v.len), null) else c.sqlite3_bind_null(self.handle, i);
        if (rc != c.SQLITE_OK) return error.Sqlite;
    }
    pub fn int(self: *Statement, i: c_int, value: ?i64) !void {
        const rc = if (value) |v| c.sqlite3_bind_int64(self.handle, i, v) else c.sqlite3_bind_null(self.handle, i);
        if (rc != c.SQLITE_OK) return error.Sqlite;
    }
    pub fn step(self: *Statement) !bool {
        const rc = c.sqlite3_step(self.handle);
        if (rc == c.SQLITE_ROW) return true;
        if (rc == c.SQLITE_DONE) return false;
        return error.Sqlite;
    }
    pub fn colText(self: *Statement, i: c_int) []const u8 {
        const p = c.sqlite3_column_text(self.handle, i);
        if (p == null) return "";
        return p[0..@intCast(c.sqlite3_column_bytes(self.handle, i))];
    }
    pub fn colOptionalText(self: *Statement, i: c_int) ?[]const u8 {
        if (c.sqlite3_column_type(self.handle, i) == c.SQLITE_NULL) return null;
        return self.colText(i);
    }
    pub fn colInt(self: *Statement, i: c_int) i64 {
        return c.sqlite3_column_int64(self.handle, i);
    }
    pub fn colOptionalInt(self: *Statement, i: c_int) ?i64 {
        if (c.sqlite3_column_type(self.handle, i) == c.SQLITE_NULL) return null;
        return self.colInt(i);
    }
};
