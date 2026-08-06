const std = @import("std");
const db = @import("database.zig");
const processes = @import("processes.zig");
const views = @import("views.zig");
pub const HostValidationOptions = struct {
    configured_address: []const u8,
    configured_port: u16,
};

pub fn serve(io: std.Io, database: *db.Database, address: []const u8, port: u16) !void {
    var ip = try std.Io.net.IpAddress.parse(address, port);
    var listener = try ip.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    while (true) {
        const stream = listener.accept(io) catch continue;
        defer stream.close(io);

        // The page allocator returns request-arena slabs to the OS at deinit.
        var request_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer request_arena.deinit();
        const request_allocator = request_arena.allocator();

        handle(
            io,
            request_allocator,
            stream,
            database,
            address,
            port,
        ) catch |err| {
            std.log.err("request failed: {s}", .{@errorName(err)});
        };
    }
}
fn handle(
    io: std.Io,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    database: *db.Database,
    address: []const u8,
    port: u16,
) !void {
    var rb: [16384]u8 = undefined;
    var wb: [16384]u8 = undefined;
    var r = stream.reader(io, &rb);
    var w = stream.writer(io, &wb);
    var server = std.http.Server.init(&r.interface, &w.interface);
    var req = try server.receiveHead();
    var hx = false;
    var host_ok = false;
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "hx-request") and std.ascii.eqlIgnoreCase(h.value, "true")) hx = true;
        if (std.ascii.eqlIgnoreCase(h.name, "host")) {
            host_ok = isAllowedHost(h.value, .{
                .configured_address = address,
                .configured_port = port,
            });
        }
    }
    if (!host_ok) return respondError(allocator, &req, .bad_request, "Bad request", "Unexpected Host header.");
    const target = try allocator.dupe(u8, req.head.target);
    const method = req.head.method;
    if (method == .GET) return get(allocator, &req, database, target);
    if (method == .POST) {
        var body_buf: [4096]u8 = undefined;
        const body = try req.readerExpectNone(&body_buf).allocRemaining(allocator, .limited(65536));
        const input = parseForm(allocator, body) catch return respondError(allocator, &req, .bad_request, "Bad request", "Malformed form data.");
        if (std.mem.eql(u8, target, "/processes")) return save(allocator, &req, database, input, null, hx);
        if (parseEditId(target)) |id| return save(allocator, &req, database, input, id, hx);
    }
    return respondError(allocator, &req, .not_found, "Not found", "The requested page does not exist.");
}

pub fn isAllowedHost(host: []const u8, options: HostValidationOptions) bool {
    if (host.len == 0) return false;
    if (std.mem.eql(u8, host, "localhost") or
        std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, options.configured_address)) return true;

    var expected_buffer: [512]u8 = undefined;
    const localhost_with_port = std.fmt.bufPrint(
        &expected_buffer,
        "localhost:{d}",
        .{options.configured_port},
    ) catch return false;
    if (std.mem.eql(u8, host, localhost_with_port)) return true;

    const loopback_with_port = std.fmt.bufPrint(
        &expected_buffer,
        "127.0.0.1:{d}",
        .{options.configured_port},
    ) catch return false;
    if (std.mem.eql(u8, host, loopback_with_port)) return true;

    const configured_with_port = std.fmt.bufPrint(
        &expected_buffer,
        "{s}:{d}",
        .{ options.configured_address, options.configured_port },
    ) catch return false;
    return std.mem.eql(u8, host, configured_with_port);
}
fn get(a: std.mem.Allocator, req: *std.http.Server.Request, database: *db.Database, target: []const u8) !void {
    if (std.mem.eql(u8, target, "/static/app.css")) return req.respond(views.css, .{ .extra_headers = &.{.{ .name = "content-type", .value = "text/css; charset=utf-8" }}, .keep_alive = false });
    if (std.mem.eql(u8, target, "/static/vendor/htmx.min.js")) return req.respond(views.htmx, .{ .extra_headers = &.{.{ .name = "content-type", .value = "text/javascript; charset=utf-8" }}, .keep_alive = false });
    if (std.mem.eql(u8, target, "/")) {
        const list = try processes.list(a, database);
        var out: std.Io.Writer.Allocating = .init(a);
        try views.dashboard(&out.writer, list);
        return html(req, out.written(), .ok);
    }
    if (std.mem.eql(u8, target, "/processes/new")) {
        var out: std.Io.Writer.Allocating = .init(a);
        try views.form(&out.writer, .{}, .{}, null, false);
        return html(req, out.written(), .ok);
    }
    if (parseDetailId(target)) |id| {
        const found = try processes.get(a, database, id) orelse return respondError(a, req, .not_found, "Not found", "That job process does not exist.");
        var out: std.Io.Writer.Allocating = .init(a);
        try views.detail(&out.writer, found);
        return html(req, out.written(), .ok);
    }
    if (parseEditId(target)) |id| {
        const found = try processes.get(a, database, id) orelse return respondError(a, req, .not_found, "Not found", "That job process does not exist.");
        var out: std.Io.Writer.Allocating = .init(a);
        try views.form(&out.writer, found.input, .{}, id, false);
        return html(req, out.written(), .ok);
    }
    return respondError(a, req, .not_found, "Not found", "The requested page does not exist.");
}
fn save(
    allocator: std.mem.Allocator,
    req: *std.http.Server.Request,
    database: *db.Database,
    input: processes.Input,
    id: ?i64,
    hx: bool,
) !void {
    const errs = processes.validate(input);
    if (errs.any()) {
        var out: std.Io.Writer.Allocating = .init(allocator);
        try views.form(&out.writer, input, errs, id, hx);
        return html(req, out.written(), .unprocessable_entity);
    }
    const saved = if (id) |v| blk: {
        processes.update(database, v, input) catch |err| {
            if (err == error.NotFound) {
                return respondError(allocator, req, .not_found, "Not found", "That job process does not exist.");
            }
            return err;
        };
        break :blk v;
    } else try processes.create(database, input);
    var location: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&location, "/processes/{d}", .{saved});
    return req.respond("", .{ .status = .see_other, .extra_headers = &.{.{ .name = "location", .value = url }}, .keep_alive = false });
}
fn html(req: *std.http.Server.Request, body: []const u8, status: std.http.Status) !void {
    return req.respond(body, .{ .status = status, .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }}, .keep_alive = false });
}
fn respondError(a: std.mem.Allocator, req: *std.http.Server.Request, status: std.http.Status, title: []const u8, msg: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(a);
    try views.errorPage(&out.writer, title, msg);
    return html(req, out.written(), status);
}
fn parseDetailId(t: []const u8) ?i64 {
    if (!std.mem.startsWith(u8, t, "/processes/")) return null;
    const rest = t[11..];
    if (std.mem.endsWith(u8, rest, "/edit")) return null;
    return std.fmt.parseInt(i64, rest, 10) catch null;
}
fn parseEditId(t: []const u8) ?i64 {
    if (!std.mem.startsWith(u8, t, "/processes/") or !std.mem.endsWith(u8, t, "/edit")) return null;
    return std.fmt.parseInt(i64, t[11 .. t.len - 5], 10) catch null;
}
pub fn parseForm(a: std.mem.Allocator, body: []const u8) !processes.Input {
    var input = processes.Input{};
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = pair[0..eq];
        const val = try decode(a, pair[eq + 1 ..]);
        if (std.mem.eql(u8, key, "company_name")) input.company_name = val else if (std.mem.eql(u8, key, "position_name")) input.position_name = val else if (std.mem.eql(u8, key, "job_url")) input.job_url = val else if (std.mem.eql(u8, key, "source")) input.source = val else if (std.mem.eql(u8, key, "location")) input.location = val else if (std.mem.eql(u8, key, "work_arrangement")) input.work_arrangement = val else if (std.mem.eql(u8, key, "salary_discussed")) input.salary_discussed = true else if (std.mem.eql(u8, key, "salary_min")) {
            input.salary_min_text = val;
            input.salary_min = if (val.len == 0) null else std.fmt.parseInt(i64, val, 10) catch blk: {
                input.salary_min_invalid = true;
                break :blk null;
            };
        } else if (std.mem.eql(u8, key, "salary_max")) {
            input.salary_max_text = val;
            input.salary_max = if (val.len == 0) null else std.fmt.parseInt(i64, val, 10) catch blk: {
                input.salary_max_invalid = true;
                break :blk null;
            };
        } else if (std.mem.eql(u8, key, "currency")) {
            for (val) |*ch| ch.* = std.ascii.toUpper(ch.*);
            input.currency = val;
        } else if (std.mem.eql(u8, key, "period")) input.period = val else if (std.mem.eql(u8, key, "salary_type")) input.salary_type = val else if (std.mem.eql(u8, key, "salary_notes")) input.salary_notes = val;
    }
    return input;
}
fn decode(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try a.alloc(u8, s.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '+') {
            out[n] = ' ';
            n += 1;
            i += 1;
        } else if (s[i] == '%') {
            if (i + 2 >= s.len) return error.MalformedEncoding;
            out[n] = try std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16);
            n += 1;
            i += 3;
        } else {
            out[n] = s[i];
            n += 1;
            i += 1;
        }
    }
    return out[0..n];
}

test "invalid salary input is preserved as validation data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input = try parseForm(arena.allocator(), "company_name=Acme&position_name=Engineer&salary_min=12x&salary_max=500");
    try std.testing.expect(input.salary_min_invalid);
    try std.testing.expectEqualStrings("12x", input.salary_min_text);
    try std.testing.expectEqualStrings("500", input.salary_max_text);
    try std.testing.expect(processes.validate(input).salary_min != null);
}

test "minimum and maximum invalid salary values are preserved independently" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input = try parseForm(
        arena.allocator(),
        "company_name=Acme&position_name=Engineer&salary_min=12x&salary_max=wrong",
    );
    const validation_errors = processes.validate(input);
    try std.testing.expectEqualStrings("12x", input.salary_min_text);
    try std.testing.expectEqualStrings("wrong", input.salary_max_text);
    try std.testing.expect(validation_errors.salary_min != null);
    try std.testing.expect(validation_errors.salary_max != null);
}

test "exact local and configured hosts are allowed" {
    const options = HostValidationOptions{
        .configured_address = "dev.local",
        .configured_port = 8123,
    };
    try std.testing.expect(isAllowedHost("localhost", options));
    try std.testing.expect(isAllowedHost("localhost:8123", options));
    try std.testing.expect(isAllowedHost("127.0.0.1", options));
    try std.testing.expect(isAllowedHost("127.0.0.1:8123", options));
    try std.testing.expect(isAllowedHost("dev.local", options));
    try std.testing.expect(isAllowedHost("dev.local:8123", options));
}

test "malformed injected and wrong-port hosts are rejected" {
    const options = HostValidationOptions{
        .configured_address = "127.0.0.1",
        .configured_port = 7331,
    };
    for ([_][]const u8{
        "",
        "attacker.localhost",
        "localhost:7332",
        "localhost:7331.example.com",
        "localhost:7331@attacker.example",
        "127.0.0.1:7331.attacker",
        "127.0.0.1.example.com",
    }) |host| {
        try std.testing.expect(!isAllowedHost(host, options));
    }
}

test "missing Host is rejected by request validation state" {
    var host_ok = false;
    try std.testing.expect(!host_ok);
    host_ok = isAllowedHost("localhost", .{
        .configured_address = "127.0.0.1",
        .configured_port = 7331,
    });
    try std.testing.expect(host_ok);
}

test "malformed percent encoding is rejected" {
    try std.testing.expectError(error.MalformedEncoding, parseForm(std.testing.allocator, "company_name=%Z"));
}
