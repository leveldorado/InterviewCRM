const std = @import("std");
const db = @import("database.zig");

pub const Kind = enum {
    advertised,
    discussed,
    offer,
};

pub const Compensation = struct {
    id: i64,
    process_id: i64,
    kind: Kind,
    amount_min: ?i64,
    amount_max: ?i64,
    currency: ?[]const u8,
    period: ?[]const u8,
    salary_type: ?[]const u8,
    confirmed: bool,
    notes: ?[]const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

pub const Input = struct {
    process_id: i64 = 0,
    kind: Kind = .advertised,
    amount_min: ?i64 = null,
    amount_max: ?i64 = null,
    amount_min_text: []const u8 = "",
    amount_max_text: []const u8 = "",
    amount_min_invalid: bool = false,
    amount_max_invalid: bool = false,
    currency: []const u8 = "",
    period: []const u8 = "",
    salary_type: []const u8 = "",
    confirmed: bool = false,
    notes: []const u8 = "",
};

pub const Errors = struct {
    amount_min: ?[]const u8 = null,
    amount_max: ?[]const u8 = null,
    period: ?[]const u8 = null,
    salary_type: ?[]const u8 = null,
    pub fn any(value: Errors) bool {
        return value.amount_min != null or value.amount_max != null or
            value.period != null or value.salary_type != null;
    }
};

pub fn kindText(kind: Kind) []const u8 {
    return @tagName(kind);
}

pub fn parseKind(value: []const u8) !Kind {
    inline for (std.meta.tags(Kind)) |kind| {
        if (std.mem.eql(u8, value, @tagName(kind))) return kind;
    }
    return error.UnknownCompensationKind;
}

pub fn validate(input: Input) Errors {
    var errors = Errors{};
    if (input.amount_min_invalid) errors.amount_min = "Enter a whole number.";
    if (input.amount_max_invalid) errors.amount_max = "Enter a whole number.";
    if (input.amount_min) |value| if (value < 0) {
        errors.amount_min = "Must not be negative.";
    };
    if (input.amount_max) |value| if (value < 0) {
        errors.amount_max = "Must not be negative.";
    };
    if (input.amount_min != null and input.amount_max != null and
        input.amount_min.? > input.amount_max.?)
    {
        errors.amount_max = "Maximum must be at least the minimum.";
    }
    if (!supported(input.period, &.{ "", "hour", "month", "year" })) {
        errors.period = "Choose a supported period.";
    }
    if (!supported(input.salary_type, &.{ "", "gross", "net" })) {
        errors.salary_type = "Choose gross or net.";
    }
    return errors;
}

pub fn isEmpty(input: Input) bool {
    return input.amount_min == null and input.amount_max == null and
        input.currency.len == 0 and input.period.len == 0 and
        input.salary_type.len == 0 and !input.confirmed and
        std.mem.trim(u8, input.notes, " \t\r\n").len == 0;
}

pub fn getForProcess(
    allocator: std.mem.Allocator,
    database: *db.Database,
    process_id: i64,
    kind: Kind,
) !?Compensation {
    var statement = try database.prepare(
        \\SELECT id,process_id,kind,amount_min,amount_max,currency,period,
        \\ salary_type,confirmed,notes,created_at,updated_at
        \\FROM compensations WHERE process_id=? AND kind=?
    );
    defer statement.deinit();
    try statement.int(1, process_id);
    try statement.text(2, kindText(kind));
    if (!try statement.step()) return null;
    return try read(allocator, &statement);
}

pub fn listForProcess(
    allocator: std.mem.Allocator,
    database: *db.Database,
    process_id: i64,
) ![]Compensation {
    var statement = try database.prepare(
        \\SELECT id,process_id,kind,amount_min,amount_max,currency,period,
        \\ salary_type,confirmed,notes,created_at,updated_at
        \\FROM compensations WHERE process_id=?
        \\ORDER BY CASE kind
        \\ WHEN 'advertised' THEN 1 WHEN 'discussed' THEN 2 ELSE 3 END
    );
    defer statement.deinit();
    try statement.int(1, process_id);
    var result: std.ArrayList(Compensation) = .empty;
    while (try statement.step()) {
        try result.append(allocator, try read(allocator, &statement));
    }
    return result.toOwnedSlice(allocator);
}

pub fn upsert(database: *db.Database, input: Input) !void {
    if (validate(input).any()) return error.InvalidInput;
    if (isEmpty(input)) return error.EmptyCompensation;
    var currency_buffer: [12]u8 = undefined;
    if (input.currency.len > currency_buffer.len) return error.InvalidInput;
    const currency = currency_buffer[0..input.currency.len];
    for (input.currency, currency) |from, *to| {
        to.* = std.ascii.toUpper(from);
    }
    var statement = try database.prepare(
        \\INSERT INTO compensations(
        \\ process_id,kind,amount_min,amount_max,currency,period,salary_type,
        \\ confirmed,notes,created_at,updated_at
        \\) VALUES(?,?,?,?,?,?,?,?,?,datetime('now'),datetime('now'))
        \\ON CONFLICT(process_id,kind) DO UPDATE SET
        \\ amount_min=excluded.amount_min,amount_max=excluded.amount_max,
        \\ currency=excluded.currency,period=excluded.period,
        \\ salary_type=excluded.salary_type,confirmed=excluded.confirmed,
        \\ notes=excluded.notes,updated_at=datetime('now')
    );
    defer statement.deinit();
    try statement.int(1, input.process_id);
    try statement.text(2, kindText(input.kind));
    try statement.int(3, input.amount_min);
    try statement.int(4, input.amount_max);
    try statement.text(5, nullable(currency));
    try statement.text(6, nullable(input.period));
    try statement.text(7, nullable(input.salary_type));
    try statement.int(8, if (input.confirmed) 1 else 0);
    try statement.text(9, nullable(std.mem.trim(u8, input.notes, " \t\r\n")));
    _ = try statement.step();
}

pub fn delete(database: *db.Database, process_id: i64, kind: Kind) !void {
    var statement = try database.prepare(
        "DELETE FROM compensations WHERE process_id=? AND kind=?",
    );
    defer statement.deinit();
    try statement.int(1, process_id);
    try statement.text(2, kindText(kind));
    _ = try statement.step();
}

fn supported(value: []const u8, values: []const []const u8) bool {
    for (values) |candidate| {
        if (std.mem.eql(u8, value, candidate)) return true;
    }
    return false;
}

fn nullable(value: []const u8) ?[]const u8 {
    return if (value.len == 0) null else value;
}

fn optionalDupe(
    allocator: std.mem.Allocator,
    value: ?[]const u8,
) !?[]const u8 {
    return if (value) |text| try allocator.dupe(u8, text) else null;
}

fn read(
    allocator: std.mem.Allocator,
    statement: *db.Statement,
) !Compensation {
    return .{
        .id = statement.colInt(0),
        .process_id = statement.colInt(1),
        .kind = try parseKind(statement.colText(2)),
        .amount_min = statement.colOptionalInt(3),
        .amount_max = statement.colOptionalInt(4),
        .currency = try optionalDupe(allocator, statement.colOptionalText(5)),
        .period = try optionalDupe(allocator, statement.colOptionalText(6)),
        .salary_type = try optionalDupe(allocator, statement.colOptionalText(7)),
        .confirmed = statement.colInt(8) == 1,
        .notes = try optionalDupe(allocator, statement.colOptionalText(9)),
        .created_at = try allocator.dupe(u8, statement.colText(10)),
        .updated_at = try allocator.dupe(u8, statement.colText(11)),
    };
}
