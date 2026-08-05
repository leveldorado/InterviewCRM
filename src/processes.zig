const std = @import("std");
const db = @import("database.zig");

pub const Input = struct {
    company_name: []const u8 = "",
    position_name: []const u8 = "",
    job_url: []const u8 = "",
    source: []const u8 = "",
    location: []const u8 = "",
    work_arrangement: []const u8 = "",
    salary_discussed: bool = false,
    salary_min: ?i64 = null,
    salary_max: ?i64 = null, currency: []const u8 = "", period: []const u8 = "", salary_type: []const u8 = "", salary_notes: []const u8 = "" };
pub const Errors = struct {
    company: ?[]const u8 = null,
    position: ?[]const u8 = null,
    url: ?[]const u8 = null,
    salary_min: ?[]const u8 = null,
    salary_max: ?[]const u8 = null,
    pub fn any(e: Errors) bool {
        return e.company != null or e.position != null or e.url != null or e.salary_min != null or e.salary_max != null;
    }
};
pub const Process = struct { id: i64, input: Input, status: []const u8, created_at: []const u8, updated_at: []const u8 };

pub fn validate(input: Input) Errors {
    var e = Errors{};
    if (std.mem.trim(u8, input.company_name, " \t\r\n").len == 0) e.company = "Company is required.";
    if (std.mem.trim(u8, input.position_name, " \t\r\n").len == 0) e.position = "Position is required.";
    if (input.job_url.len > 0 and !std.mem.startsWith(u8, input.job_url, "http://") and !std.mem.startsWith(u8, input.job_url, "https://")) e.url = "Use an HTTP or HTTPS URL.";
    if (input.salary_min) |v| if (v < 0) {
        e.salary_min = "Must not be negative.";
    };
    if (input.salary_max) |v| if (v < 0) {
        e.salary_max = "Must not be negative.";
    };
    if (input.salary_min != null and input.salary_max != null and input.salary_min.? > input.salary_max.?) e.salary_max = "Maximum must be at least the minimum.";
    return e;
}

const select_cols = "id,company_name,position_name,job_url,source,location,work_arrangement,salary_discussed,salary_amount_min,salary_amount_max,salary_currency,salary_period,salary_type,salary_notes,status,created_at,updated_at";
pub fn create(database: *db.Database, input: Input) !i64 {
    if (validate(input).any()) return error.InvalidInput;
    var s = try database.prepare("INSERT INTO job_processes(company_name,position_name,job_url,source,location,work_arrangement,salary_discussed,salary_amount_min,salary_amount_max,salary_currency,salary_period,salary_type,salary_notes,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,datetime('now'),datetime('now'))");
    defer s.deinit();
    try bind(&s, input);
    _ = try s.step();
    const id = database.lastId();
    var a = try database.prepare("INSERT INTO activity_log(process_id,activity_type,description,created_at) VALUES(?,'process_created','Job process created',datetime('now'))");
    defer a.deinit();
    try a.int(1, id);
    _ = try a.step();
    return id;
}
pub fn update(database: *db.Database, id: i64, input: Input) !void {
    if (validate(input).any()) return error.InvalidInput;
    var s = try database.prepare("UPDATE job_processes SET company_name=?,position_name=?,job_url=?,source=?,location=?,work_arrangement=?,salary_discussed=?,salary_amount_min=?,salary_amount_max=?,salary_currency=?,salary_period=?,salary_type=?,salary_notes=?,updated_at=datetime('now') WHERE id=?");
    defer s.deinit();
    try bind(&s, input);
    try s.int(14, id);
    _ = try s.step();
    if (database.changes() == 0) return error.NotFound;
    var a = try database.prepare("INSERT INTO activity_log(process_id,activity_type,description,created_at) VALUES(?,'process_updated','Job process updated',datetime('now'))");
    defer a.deinit();
    try a.int(1, id);
    _ = try a.step();
}
fn bind(s: *db.Statement, input: Input) !void {
    try s.text(1, input.company_name);
    try s.text(2, input.position_name);
    try s.text(3, nullable(input.job_url));
    try s.text(4, nullable(input.source));
    try s.text(5, nullable(input.location));
    try s.text(6, nullable(input.work_arrangement));
    try s.int(7, if (input.salary_discussed) 1 else 0);
    try s.int(8, input.salary_min);
    try s.int(9, input.salary_max);
    try s.text(10, nullable(input.currency));
    try s.text(11, nullable(input.period));
    try s.text(12, nullable(input.salary_type));
    try s.text(13, nullable(input.salary_notes));
}
fn nullable(v: []const u8) ?[]const u8 {
    return if (v.len == 0) null else v;
}
pub fn get(allocator: std.mem.Allocator, database: *db.Database, id: i64) !?Process {
    var s = try database.prepare(("SELECT " ++ select_cols ++ " FROM job_processes WHERE id=?"));
    defer s.deinit();
    try s.int(1, id);
    if (!try s.step()) return null;
    return try read(allocator, &s);
}
pub fn list(allocator: std.mem.Allocator, database: *db.Database) ![]Process {
    var s = try database.prepare(("SELECT " ++ select_cols ++ " FROM job_processes WHERE status IN ('active','offer_received') ORDER BY updated_at DESC"));
    defer s.deinit();
    var out: std.ArrayList(Process) = .empty;
    while (try s.step()) try out.append(allocator, try read(allocator, &s));
    return out.toOwnedSlice(allocator);
}
fn read(a: std.mem.Allocator, s: *db.Statement) !Process {
    return .{ .id = s.colInt(0), .input = .{ .company_name = try a.dupe(u8, s.colText(1)), .position_name = try a.dupe(u8, s.colText(2)), .job_url = try a.dupe(u8, s.colText(3)), .source = try a.dupe(u8, s.colText(4)), .location = try a.dupe(u8, s.colText(5)), .work_arrangement = try a.dupe(u8, s.colText(6)), .salary_discussed = s.colInt(7) == 1, .salary_min = s.colOptionalInt(8), .salary_max = s.colOptionalInt(9), .currency = try a.dupe(u8, s.colText(10)), .period = try a.dupe(u8, s.colText(11)), .salary_type = try a.dupe(u8, s.colText(12)), .salary_notes = try a.dupe(u8, s.colText(13)) }, .status = try a.dupe(u8, s.colText(14)), .created_at = try a.dupe(u8, s.colText(15)), .updated_at = try a.dupe(u8, s.colText(16)) };
}

test "validation rules" {
    try std.testing.expect(validate(.{}).company != null);
    try std.testing.expect(validate(.{ .company_name = "A", .position_name = "B", .salary_min = 200, .salary_max = 100 }).salary_max != null);
    try std.testing.expect(!validate(.{ .company_name = "A", .position_name = "B", .salary_discussed = true }).any());
}
