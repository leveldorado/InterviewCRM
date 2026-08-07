const std = @import("std");
const assets = @import("assets.zig");
const db = @import("database.zig");
const processes = @import("processes.zig");
const view_models = @import("view_models.zig");
const views = @import("views.zig");

pub const HostValidationOptions = struct {
    configured_address: []const u8,
    configured_port: u16,
};

const RequestKind = enum {
    traditional,
    htmx,
};

const SaveOptions = struct {
    process_id: ?i64,
    request_kind: RequestKind,
};

pub fn serve(
    io: std.Io,
    database: *db.Database,
    address: []const u8,
    port: u16,
) !void {
    var ip = try std.Io.net.IpAddress.parse(address, port);
    var listener = try ip.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    while (true) {
        const stream = listener.accept(io) catch continue;
        defer stream.close(io);

        // Page-backed arena slabs are returned after every request.
        var request_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer request_arena.deinit();

        handleConnection(
            io,
            request_arena.allocator(),
            stream,
            database,
            address,
            port,
        ) catch |err| {
            std.log.err("request failed: {s}", .{@errorName(err)});
        };
    }
}

fn handleConnection(
    io: std.Io,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    database: *db.Database,
    address: []const u8,
    port: u16,
) !void {
    var read_buffer: [16384]u8 = undefined;
    var write_buffer: [16384]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    var request = try server.receiveHead();
    const headers = inspectHeaders(
        &request,
        .{
            .configured_address = address,
            .configured_port = port,
        },
    );
    const request_kind: RequestKind = if (headers.is_htmx)
        .htmx
    else
        .traditional;
    if (!headers.host_is_allowed) {
        return respondError(
            allocator,
            &request,
            .bad_request,
            "Bad request",
            "Unexpected Host header.",
            request_kind,
        );
    }

    const target = try allocator.dupe(u8, request.head.target);
    switch (request.head.method) {
        .GET => return handleGet(
            allocator,
            &request,
            database,
            target,
            request_kind,
        ),
        .POST => {
            var body_buffer: [4096]u8 = undefined;
            const body = try request.readerExpectNone(&body_buffer).allocRemaining(
                allocator,
                .limited(65536),
            );
            const input = parseForm(allocator, body) catch {
                return respondError(
                    allocator,
                    &request,
                    .bad_request,
                    "Bad request",
                    "Malformed form data.",
                    request_kind,
                );
            };
            if (std.mem.eql(u8, target, "/processes")) {
                return saveProcess(
                    allocator,
                    &request,
                    database,
                    input,
                    .{
                        .process_id = null,
                        .request_kind = request_kind,
                    },
                );
            }
            if (parseEditId(target)) |process_id| {
                return saveProcess(
                    allocator,
                    &request,
                    database,
                    input,
                    .{
                        .process_id = process_id,
                        .request_kind = request_kind,
                    },
                );
            }
        },
        else => {},
    }
    return respondError(
        allocator,
        &request,
        .not_found,
        "Not found",
        "The requested page does not exist.",
        request_kind,
    );
}

const InspectedHeaders = struct {
    host_is_allowed: bool = false,
    is_htmx: bool = false,
};

fn inspectHeaders(
    request: *std.http.Server.Request,
    options: HostValidationOptions,
) InspectedHeaders {
    var result = InspectedHeaders{};
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "hx-request") and
            std.ascii.eqlIgnoreCase(header.value, "true"))
        {
            result.is_htmx = true;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "host")) {
            result.host_is_allowed = isAllowedHost(header.value, options);
        }
    }
    return result;
}

fn handleGet(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    database: *db.Database,
    target: []const u8,
    request_kind: RequestKind,
) !void {
    if (std.mem.eql(u8, target, "/static/app.css")) {
        return respondAsset(request, assets.css, "text/css; charset=utf-8");
    }
    if (std.mem.eql(u8, target, "/static/vendor/htmx.min.js")) {
        return respondAsset(
            request,
            assets.htmx,
            "text/javascript; charset=utf-8",
        );
    }
    if (std.mem.eql(u8, target, "/")) {
        return serveDashboard(allocator, request, database, request_kind);
    }
    if (std.mem.eql(u8, target, "/processes/new")) {
        return serveNewProcessForm(allocator, request, request_kind);
    }
    if (parseDetailId(target)) |process_id| {
        return serveProcessDetail(
            allocator,
            request,
            database,
            process_id,
            request_kind,
        );
    }
    if (parseEditId(target)) |process_id| {
        return serveEditProcessForm(
            allocator,
            request,
            database,
            process_id,
            request_kind,
        );
    }
    return respondError(
        allocator,
        request,
        .not_found,
        "Not found",
        "The requested page does not exist.",
        request_kind,
    );
}

fn serveDashboard(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    database: *db.Database,
    request_kind: RequestKind,
) !void {
    const stored_processes = try processes.list(allocator, database);
    const view = try views.buildDashboard(allocator, stored_processes);
    var output: std.Io.Writer.Allocating = .init(allocator);
    switch (request_kind) {
        .traditional => try views.renderDashboardPage(&output.writer, view),
        .htmx => try views.renderDashboardFragment(&output.writer, view),
    }
    return respondHtml(request, output.written(), .ok, &.{});
}

fn serveNewProcessForm(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    request_kind: RequestKind,
) !void {
    const view = try views.buildProcessForm(allocator, .{}, .{}, null);
    var output: std.Io.Writer.Allocating = .init(allocator);
    switch (request_kind) {
        .traditional => try views.renderProcessFormPage(&output.writer, view),
        .htmx => try views.renderProcessFormNavigationFragment(
            &output.writer,
            view,
        ),
    }
    return respondHtml(request, output.written(), .ok, &.{});
}

fn serveProcessDetail(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    database: *db.Database,
    process_id: i64,
    request_kind: RequestKind,
) !void {
    const process = try loadProcessOrRespond(
        allocator,
        request,
        database,
        process_id,
        request_kind,
    ) orelse return;
    const view = try views.buildProcessDetail(allocator, process);
    var output: std.Io.Writer.Allocating = .init(allocator);
    switch (request_kind) {
        .traditional => try views.renderProcessDetailPage(&output.writer, view),
        .htmx => try views.renderProcessDetailFragment(&output.writer, view),
    }
    return respondHtml(request, output.written(), .ok, &.{});
}

fn serveEditProcessForm(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    database: *db.Database,
    process_id: i64,
    request_kind: RequestKind,
) !void {
    const process = try loadProcessOrRespond(
        allocator,
        request,
        database,
        process_id,
        request_kind,
    ) orelse return;
    const view = try views.buildProcessForm(
        allocator,
        process.input,
        .{},
        process_id,
    );
    var output: std.Io.Writer.Allocating = .init(allocator);
    switch (request_kind) {
        .traditional => try views.renderProcessFormPage(&output.writer, view),
        .htmx => try views.renderProcessFormNavigationFragment(
            &output.writer,
            view,
        ),
    }
    return respondHtml(request, output.written(), .ok, &.{});
}

fn loadProcessOrRespond(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    database: *db.Database,
    process_id: i64,
    request_kind: RequestKind,
) !?processes.Process {
    const process = try processes.get(allocator, database, process_id);
    if (process) |found| return found;
    try respondError(
        allocator,
        request,
        .not_found,
        "Not found",
        "That job process does not exist.",
        request_kind,
    );
    return null;
}

fn saveProcess(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    database: *db.Database,
    input: processes.Input,
    options: SaveOptions,
) !void {
    const validation_errors = processes.validate(input);
    if (validation_errors.any()) {
        return respondToValidationFailure(
            allocator,
            request,
            input,
            validation_errors,
            options,
        );
    }

    const saved_id = if (options.process_id) |process_id| block: {
        processes.update(database, process_id, input) catch |err| {
            if (err == error.NotFound) {
                return respondError(
                    allocator,
                    request,
                    .not_found,
                    "Not found",
                    "That job process does not exist.",
                    options.request_kind,
                );
            }
            return err;
        };
        break :block process_id;
    } else try processes.create(database, input);

    return respondToSuccessfulSave(
        allocator,
        request,
        database,
        saved_id,
        options.request_kind,
    );
}

fn respondToValidationFailure(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    input: processes.Input,
    validation_errors: processes.Errors,
    options: SaveOptions,
) !void {
    const view = try views.buildProcessForm(
        allocator,
        input,
        validation_errors,
        options.process_id,
    );
    var output: std.Io.Writer.Allocating = .init(allocator);
    switch (options.request_kind) {
        .traditional => try views.renderProcessFormPage(&output.writer, view),
        .htmx => try views.renderProcessFormValidationFragment(
            &output.writer,
            view,
        ),
    }
    return respondHtml(
        request,
        output.written(),
        .unprocessable_entity,
        &.{},
    );
}

fn respondToSuccessfulSave(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    database: *db.Database,
    process_id: i64,
    request_kind: RequestKind,
) !void {
    var url_buffer: [64]u8 = undefined;
    const process_url = try std.fmt.bufPrint(
        &url_buffer,
        "/processes/{d}",
        .{process_id},
    );
    if (request_kind == .traditional) {
        return request.respond("", .{
            .status = .see_other,
            .extra_headers = &.{.{
                .name = "location",
                .value = process_url,
            }},
            .keep_alive = false,
        });
    }

    const saved_process = (try processes.get(
        allocator,
        database,
        process_id,
    )).?;
    const view = try views.buildProcessDetail(allocator, saved_process);
    var output: std.Io.Writer.Allocating = .init(allocator);
    try views.renderProcessDetailFragment(&output.writer, view);
    return respondHtml(
        request,
        output.written(),
        .ok,
        &.{
            .{
                .name = "hx-retarget",
                .value = "#main-content",
            },
            .{
                .name = "hx-reswap",
                .value = "innerHTML",
            },
            .{
                .name = "hx-push-url",
                .value = process_url,
            },
        },
    );
}

fn respondAsset(
    request: *std.http.Server.Request,
    body: []const u8,
    content_type: []const u8,
) !void {
    return request.respond(body, .{
        .extra_headers = &.{.{
            .name = "content-type",
            .value = content_type,
        }},
        .keep_alive = false,
    });
}

fn respondHtml(
    request: *std.http.Server.Request,
    body: []const u8,
    status: std.http.Status,
    extra_headers: []const std.http.Header,
) !void {
    var headers: [4]std.http.Header = undefined;
    headers[0] = .{
        .name = "content-type",
        .value = "text/html; charset=utf-8",
    };
    @memcpy(headers[1 .. extra_headers.len + 1], extra_headers);
    return request.respond(body, .{
        .status = status,
        .extra_headers = headers[0 .. extra_headers.len + 1],
        .keep_alive = false,
    });
}

fn respondError(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    status: std.http.Status,
    title: []const u8,
    message: []const u8,
    request_kind: RequestKind,
) !void {
    var output: std.Io.Writer.Allocating = .init(allocator);
    const view = view_models.ErrorPage{
        .title = title,
        .message = message,
    };
    switch (request_kind) {
        .traditional => try views.renderErrorPage(&output.writer, view),
        .htmx => try views.renderErrorFragment(&output.writer, view),
    }
    return respondHtml(request, output.written(), status, &.{});
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

fn parseDetailId(target: []const u8) ?i64 {
    if (!std.mem.startsWith(u8, target, "/processes/")) return null;
    const remainder = target[11..];
    if (std.mem.endsWith(u8, remainder, "/edit")) return null;
    return std.fmt.parseInt(i64, remainder, 10) catch null;
}

fn parseEditId(target: []const u8) ?i64 {
    const has_prefix = std.mem.startsWith(u8, target, "/processes/");
    const has_suffix = std.mem.endsWith(u8, target, "/edit");
    if (!has_prefix or !has_suffix) return null;
    return std.fmt.parseInt(i64, target[11 .. target.len - 5], 10) catch null;
}

pub fn parseForm(allocator: std.mem.Allocator, body: []const u8) !processes.Input {
    var input = processes.Input{};
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        const equals_index = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = pair[0..equals_index];
        const value = try decode(allocator, pair[equals_index + 1 ..]);
        try assignFormValue(&input, key, value);
    }
    return input;
}

fn assignFormValue(
    input: *processes.Input,
    key: []const u8,
    value: []u8,
) !void {
    if (std.mem.eql(u8, key, "company_name")) input.company_name = value else if (std.mem.eql(u8, key, "position_name")) input.position_name = value else if (std.mem.eql(u8, key, "job_url")) input.job_url = value else if (std.mem.eql(u8, key, "source")) input.source = value else if (std.mem.eql(u8, key, "location")) input.location = value else if (std.mem.eql(u8, key, "work_arrangement")) input.work_arrangement = value else if (std.mem.eql(u8, key, "salary_discussed")) input.salary_discussed = true else if (std.mem.eql(u8, key, "salary_min")) assignSalaryValue(input, value, .minimum) else if (std.mem.eql(u8, key, "salary_max")) assignSalaryValue(input, value, .maximum) else if (std.mem.eql(u8, key, "currency")) {
        for (value) |*character| character.* = std.ascii.toUpper(character.*);
        input.currency = value;
    } else if (std.mem.eql(u8, key, "period")) input.period = value else if (std.mem.eql(u8, key, "salary_type")) input.salary_type = value else if (std.mem.eql(u8, key, "salary_notes")) input.salary_notes = value;
}

const SalaryField = enum {
    minimum,
    maximum,
};

fn assignSalaryValue(
    input: *processes.Input,
    value: []const u8,
    field: SalaryField,
) void {
    const parsed = if (value.len == 0)
        null
    else
        std.fmt.parseInt(i64, value, 10) catch null;
    const invalid = value.len > 0 and parsed == null;
    switch (field) {
        .minimum => {
            input.salary_min_text = value;
            input.salary_min = parsed;
            input.salary_min_invalid = invalid;
        },
        .maximum => {
            input.salary_max_text = value;
            input.salary_max = parsed;
            input.salary_max_invalid = invalid;
        },
    }
}

fn decode(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    var output = try allocator.alloc(u8, encoded.len);
    var output_index: usize = 0;
    var input_index: usize = 0;
    while (input_index < encoded.len) {
        switch (encoded[input_index]) {
            '+' => {
                output[output_index] = ' ';
                output_index += 1;
                input_index += 1;
            },
            '%' => {
                if (input_index + 2 >= encoded.len) return error.MalformedEncoding;
                output[output_index] = try std.fmt.parseInt(
                    u8,
                    encoded[input_index + 1 .. input_index + 3],
                    16,
                );
                output_index += 1;
                input_index += 3;
            },
            else => |character| {
                output[output_index] = character;
                output_index += 1;
                input_index += 1;
            },
        }
    }
    return output[0..output_index];
}

test "invalid salary input is preserved as validation data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input = try parseForm(
        arena.allocator(),
        "company_name=Acme&position_name=Engineer&salary_min=12x&salary_max=wrong",
    );
    const errors = processes.validate(input);
    try std.testing.expectEqualStrings("12x", input.salary_min_text);
    try std.testing.expectEqualStrings("wrong", input.salary_max_text);
    try std.testing.expect(errors.salary_min != null);
    try std.testing.expect(errors.salary_max != null);
}

test "malformed percent encoding is rejected" {
    try std.testing.expectError(
        error.MalformedEncoding,
        parseForm(std.testing.allocator, "company_name=%Z"),
    );
}

test "exact local and configured hosts are allowed" {
    const options = HostValidationOptions{
        .configured_address = "dev.local",
        .configured_port = 8123,
    };
    for ([_][]const u8{
        "localhost",
        "localhost:8123",
        "127.0.0.1",
        "127.0.0.1:8123",
        "dev.local",
        "dev.local:8123",
    }) |host| try std.testing.expect(isAllowedHost(host, options));
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
    }) |host| try std.testing.expect(!isAllowedHost(host, options));
}
