const std = @import("std");
const appointments = @import("appointments.zig");
const assets = @import("assets.zig");
const compensations = @import("compensations.zig");
const db = @import("database.zig");
const notes = @import("notes.zig");
const processes = @import("processes.zig");
const questions = @import("questions.zig");
const sources = @import("sources.zig");
const stages = @import("stages.zig");
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

const Route = union(enum) {
    dashboard,
    new_process,
    create_process,
    process_detail: i64,
    edit_process: i64,
    update_ratings: i64,
    delete_process: i64,
    add_source,
    compensation: struct {
        process_id: i64,
        kind: compensations.Kind,
    },
    add_stage: i64,
    stage_outcome: i64,
    skip_stage: i64,
    reopen_stage: i64,
    add_stage_note: i64,
    edit_note: i64,
    delete_note: i64,
    schedule_appointment: i64,
    cancel_appointment: i64,
    add_company_question: i64,
    add_learning_question: i64,
    edit_question: i64,
    delete_question: i64,
    static_css,
    static_htmx,
    favicon,
    not_found,
};

const FormData = struct {
    process: processes.Input = .{},
    name: []const u8 = "",
    kind: []const u8 = "",
    outcome: []const u8 = "",
    reason: []const u8 = "",
    new_source: []const u8 = "",
    question: []const u8 = "",
    answer: []const u8 = "",
    body: []const u8 = "",
    compensation: compensations.Input = .{},
    compensation_is_range: bool = false,
    compensation_amount: AmountValue = .{},
    compensation_from: AmountValue = .{},
    compensation_to: AmountValue = .{},
    appointment: appointments.Input = .{},
};

const AmountValue = struct {
    text: []const u8 = "",
    value: ?i64 = null,
    invalid: bool = false,
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
    const route = parseRoute(request.head.method, target);
    switch (request.head.method) {
        .GET => return handleGet(
            allocator,
            &request,
            database,
            route,
            request_kind,
        ),
        .POST => {
            var body_buffer: [4096]u8 = undefined;
            const body = try request.readerExpectNone(&body_buffer).allocRemaining(
                allocator,
                .limited(65536),
            );
            const form = parseFormData(allocator, body) catch {
                return respondError(
                    allocator,
                    &request,
                    .bad_request,
                    "Bad request",
                    "Malformed form data.",
                    request_kind,
                );
            };
            switch (route) {
                .create_process => return saveProcess(
                    allocator,
                    &request,
                    database,
                    form.process,
                    .{
                        .process_id = null,
                        .request_kind = request_kind,
                    },
                ),
                .edit_process => |process_id| return saveProcess(
                    allocator,
                    &request,
                    database,
                    form.process,
                    .{
                        .process_id = process_id,
                        .request_kind = request_kind,
                    },
                ),
                .update_ratings => |process_id| return updateRatings(
                    allocator,
                    &request,
                    database,
                    process_id,
                    form.process,
                    request_kind,
                ),
                .delete_process => |process_id| return deleteProcess(
                    allocator,
                    &request,
                    database,
                    process_id,
                    request_kind,
                ),
                .add_source => return addSource(
                    allocator,
                    &request,
                    database,
                    form,
                    request_kind,
                ),
                .compensation => |route_data| return saveCompensation(
                    allocator,
                    &request,
                    database,
                    route_data.process_id,
                    route_data.kind,
                    form.compensation,
                    request_kind,
                ),
                .add_stage => |process_id| return addStage(
                    allocator,
                    &request,
                    database,
                    process_id,
                    form.kind,
                    form.name,
                    request_kind,
                ),
                .stage_outcome => |stage_id| return setStageOutcome(
                    allocator,
                    &request,
                    database,
                    stage_id,
                    form.outcome,
                    form.reason,
                    request_kind,
                ),
                .skip_stage => |stage_id| return changeStage(
                    allocator,
                    &request,
                    database,
                    stage_id,
                    .skip,
                    request_kind,
                ),
                .reopen_stage => |stage_id| return changeStage(
                    allocator,
                    &request,
                    database,
                    stage_id,
                    .reopen,
                    request_kind,
                ),
                .add_stage_note => |stage_id| return addStageNote(
                    allocator,
                    &request,
                    database,
                    stage_id,
                    form.body,
                    request_kind,
                ),
                .edit_note => |note_id| return editStageNote(
                    allocator,
                    &request,
                    database,
                    note_id,
                    form.body,
                    request_kind,
                ),
                .delete_note => |note_id| return deleteStageNote(
                    allocator,
                    &request,
                    database,
                    note_id,
                    request_kind,
                ),
                .schedule_appointment => |stage_id| return scheduleAppointment(
                    allocator,
                    &request,
                    database,
                    stage_id,
                    form.appointment,
                    request_kind,
                ),
                .cancel_appointment => |appointment_id| return cancelAppointment(
                    allocator,
                    &request,
                    database,
                    appointment_id,
                    request_kind,
                ),
                .add_company_question => |process_id| return addQuestion(
                    allocator,
                    &request,
                    database,
                    process_id,
                    null,
                    .company,
                    form.question,
                    form.answer,
                    request_kind,
                ),
                .add_learning_question => |stage_id| return addLearningQuestion(
                    allocator,
                    &request,
                    database,
                    stage_id,
                    form.question,
                    form.answer,
                    request_kind,
                ),
                .edit_question => |question_id| return editQuestion(
                    allocator,
                    &request,
                    database,
                    question_id,
                    form.question,
                    form.answer,
                    request_kind,
                ),
                .delete_question => |question_id| return deleteQuestion(
                    allocator,
                    &request,
                    database,
                    question_id,
                    request_kind,
                ),
                else => {},
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
    route: Route,
    request_kind: RequestKind,
) !void {
    switch (route) {
        .static_css => return respondAsset(
            request,
            assets.css,
            "text/css; charset=utf-8",
        ),
        .static_htmx => return respondAsset(
            request,
            assets.htmx,
            "text/javascript; charset=utf-8",
        ),
        .favicon => return respondAsset(
            request,
            assets.favicon,
            "image/svg+xml",
        ),
        .dashboard => return serveDashboard(
            allocator,
            request,
            database,
            request_kind,
        ),
        .new_process => return serveNewProcessForm(
            allocator,
            request,
            database,
            request_kind,
        ),
        .process_detail => |process_id| return serveProcessDetail(
            allocator,
            request,
            database,
            process_id,
            request_kind,
        ),
        .edit_process => |process_id| return serveEditProcessForm(
            allocator,
            request,
            database,
            process_id,
            request_kind,
        ),
        else => {},
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
    const view = try views.buildDashboard(allocator, database, stored_processes);
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
    database: *db.Database,
    request_kind: RequestKind,
) !void {
    const view = try views.buildProcessForm(
        allocator,
        database,
        .{
            .applied_at = try localToday(allocator, database),
        },
        .{},
        null,
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
    const view = try views.buildProcessDetail(
        allocator,
        database,
        process,
        .{},
    );
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
        database,
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
    submitted_input: processes.Input,
    options: SaveOptions,
) !void {
    var input = submitted_input;
    if (options.process_id) |process_id| {
        const existing = (try processes.get(
            allocator,
            database,
            process_id,
        )) orelse {
            return respondError(
                allocator,
                request,
                .not_found,
                "Not found",
                "That job process does not exist.",
                options.request_kind,
            );
        };
        input.advertised = existing.input.advertised;
        input.discussed = existing.input.discussed;
    }
    const validation_errors = processes.validate(input);
    if (validation_errors.any()) {
        return respondToValidationFailure(
            allocator,
            request,
            database,
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

fn updateRatings(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    database: *db.Database,
    process_id: i64,
    input: processes.Input,
    request_kind: RequestKind,
) !void {
    processes.updateRatings(database, process_id, input) catch |err| {
        if (err == error.NotFound) {
            return respondError(
                allocator,
                request,
                .not_found,
                "Not found",
                "That job process does not exist.",
                request_kind,
            );
        }
        if (err == error.InvalidInput) {
            const process = (try processes.get(
                allocator,
                database,
                process_id,
            )).?;
            var errors = processes.Errors{};
            setRatingErrors(input, &errors);
            var attempted = process;
            attempted.input.interest_rating = input.interest_rating;
            attempted.input.money_rating = input.money_rating;
            attempted.input.growth_rating = input.growth_rating;
            const section = try views.buildRatingsSection(
                allocator,
                attempted,
                errors,
            );
            var output: std.Io.Writer.Allocating = .init(allocator);
            try views.renderRatingsFragment(&output.writer, section);
            return respondHtml(
                request,
                output.written(),
                .unprocessable_entity,
                &.{},
            );
        }
        return err;
    };
    if (request_kind == .traditional) return redirectToProcess(request, process_id);
    const process = (try processes.get(allocator, database, process_id)).?;
    const section = try views.buildRatingsSection(allocator, process, .{});
    var output: std.Io.Writer.Allocating = .init(allocator);
    try views.renderRatingsFragment(&output.writer, section);
    return respondHtml(request, output.written(), .ok, &.{});
}

fn setRatingErrors(input: processes.Input, errors: *processes.Errors) void {
    if (input.interest_rating_invalid or invalidRating(input.interest_rating)) {
        errors.interest_rating = "Choose a rating from 1 to 5.";
    }
    if (input.money_rating_invalid or invalidRating(input.money_rating)) {
        errors.money_rating = "Choose a rating from 1 to 5.";
    }
    if (input.growth_rating_invalid or invalidRating(input.growth_rating)) {
        errors.growth_rating = "Choose a rating from 1 to 5.";
    }
}

fn invalidRating(value: ?i64) bool {
    return value != null and (value.? < 1 or value.? > 5);
}

fn respondToValidationFailure(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    database: *db.Database,
    input: processes.Input,
    validation_errors: processes.Errors,
    options: SaveOptions,
) !void {
    const view = try views.buildProcessForm(
        allocator,
        database,
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
    const view = try views.buildProcessDetail(
        allocator,
        database,
        saved_process,
        .{},
    );
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

const StageChange = enum {
    skip,
    reopen,
};

fn addStage(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    database: *db.Database,
    process_id: i64,
    kind_value: []const u8,
    name: []const u8,
    request_kind: RequestKind,
) !void {
    const kind = stages.parseKind(kind_value) catch {
        return respondTimeline(
            allocator,
            request,
            database,
            process_id,
            request_kind,
            .unprocessable_entity,
            .{ .add_stage = .{
                .kind = kind_value,
                .name = name,
                .error_message = "Choose a supported stage type.",
            } },
        );
    };
    _ = stages.add(allocator, database, process_id, kind, name) catch |err| {
        if (err == error.InvalidStageName or err == error.InvalidStageKind) {
            return respondTimeline(
                allocator,
                request,
                database,
                process_id,
                request_kind,
                .unprocessable_entity,
                .{
                    .add_stage = .{
                        .kind = kind_value,
                        .name = name,
                        .error_message = "Enter a custom stage name of 120 characters or fewer.",
                    },
                },
            );
        }
        return err;
    };
    return respondTimeline(
        allocator,
        request,
        database,
        process_id,
        request_kind,
        .ok,
        .{},
    );
}

fn setStageOutcome(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    database: *db.Database,
    stage_id: i64,
    outcome_value: []const u8,
    reason: []const u8,
    request_kind: RequestKind,
) !void {
    const stage = (try stages.get(allocator, database, stage_id)) orelse {
        return respondError(
            allocator,
            request,
            .not_found,
            "Not found",
            "That interview stage does not exist.",
            request_kind,
        );
    };
    const outcome = stages.parseOutcome(outcome_value) catch {
        return respondTimeline(
            allocator,
            request,
            database,
            stage.process_id,
            request_kind,
            .unprocessable_entity,
            .{
                .stage_id = stage.id,
                .outcome = .{
                    .outcome = outcome_value,
                    .reason = reason,
                    .error_message = "Choose a valid outcome for this stage.",
                },
            },
        );
    };
    const process_id = stages.setOutcome(
        allocator,
        database,
        stage.id,
        outcome,
        reason,
    ) catch |err| {
        if (err == error.InvalidTransition) {
            return respondTimeline(
                allocator,
                request,
                database,
                stage.process_id,
                request_kind,
                .unprocessable_entity,
                .{
                    .stage_id = stage.id,
                    .outcome = .{
                        .outcome = outcome_value,
                        .reason = reason,
                        .error_message = "That outcome is not valid for this stage.",
                    },
                },
            );
        }
        return err;
    };
    return respondTimeline(
        allocator,
        request,
        database,
        process_id,
        request_kind,
        .ok,
        .{},
    );
}

fn changeStage(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    database: *db.Database,
    stage_id: i64,
    change: StageChange,
    request_kind: RequestKind,
) !void {
    const process_id = switch (change) {
        .skip => stages.skip(allocator, database, stage_id),
        .reopen => stages.reopen(allocator, database, stage_id),
    } catch |err| {
        if (err == error.NotFound) {
            return respondError(
                allocator,
                request,
                .not_found,
                "Not found",
                "That interview stage does not exist.",
                request_kind,
            );
        }
        if (err == error.InvalidTransition) {
            return respondError(
                allocator,
                request,
                .unprocessable_entity,
                "Invalid stage transition",
                "That stage cannot be changed in this way.",
                request_kind,
            );
        }
        return err;
    };
    return respondTimeline(
        allocator,
        request,
        database,
        process_id,
        request_kind,
        .ok,
        .{},
    );
}

fn addStageNote(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    database: *db.Database,
    stage_id: i64,
    body: []const u8,
    request_kind: RequestKind,
) !void {
    const stage = (try stages.get(allocator, database, stage_id)) orelse {
        return respondError(
            allocator,
            request,
            .not_found,
            "Not found",
            "That interview stage does not exist.",
            request_kind,
        );
    };
    const input = notes.Input{ .body = body };
    const validation_errors = notes.validate(input);
    if (validation_errors.any()) {
        return respondStageCard(
            allocator,
            request,
            database,
            stage,
            request_kind,
            .unprocessable_entity,
            .{
                .stage_id = stage.id,
                .add_note = .{
                    .body = body,
                    .error_message = validation_errors.body,
                },
            },
        );
    }
    _ = try notes.createForStage(database, stage.process_id, stage.id, input);
    return respondStageCard(
        allocator,
        request,
        database,
        stage,
        request_kind,
        .ok,
        .{},
    );
}

fn editStageNote(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    database: *db.Database,
    note_id: i64,
    body: []const u8,
    request_kind: RequestKind,
) !void {
    const note = (try notes.get(allocator, database, note_id)) orelse {
        return respondError(
            allocator,
            request,
            .not_found,
            "Not found",
            "That note does not exist.",
            request_kind,
        );
    };
    const stage = (try stages.get(allocator, database, note.stage_id)).?;
    const input = notes.Input{ .body = body };
    const validation_errors = notes.validate(input);
    if (validation_errors.any()) {
        return respondStageCard(
            allocator,
            request,
            database,
            stage,
            request_kind,
            .unprocessable_entity,
            .{
                .stage_id = stage.id,
                .edit_note = .{
                    .note_id = note.id,
                    .body = body,
                    .error_message = validation_errors.body,
                },
            },
        );
    }
    try notes.updateStageNote(
        database,
        note.process_id,
        note.stage_id,
        note.id,
        input,
    );
    return respondStageCard(
        allocator,
        request,
        database,
        stage,
        request_kind,
        .ok,
        .{},
    );
}

fn deleteStageNote(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    database: *db.Database,
    note_id: i64,
    request_kind: RequestKind,
) !void {
    const note = (try notes.get(allocator, database, note_id)) orelse {
        return respondError(
            allocator,
            request,
            .not_found,
            "Not found",
            "That note does not exist.",
            request_kind,
        );
    };
    const stage = (try stages.get(allocator, database, note.stage_id)).?;
    try notes.deleteStageNote(
        database,
        note.process_id,
        note.stage_id,
        note.id,
    );
    return respondStageCard(
        allocator,
        request,
        database,
        stage,
        request_kind,
        .ok,
        .{},
    );
}

fn scheduleAppointment(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    database: *db.Database,
    stage_id: i64,
    input: appointments.Input,
    request_kind: RequestKind,
) !void {
    const stage = (try stages.get(allocator, database, stage_id)) orelse {
        return respondError(
            allocator,
            request,
            .not_found,
            "Not found",
            "That interview stage does not exist.",
            request_kind,
        );
    };
    const validation_errors = appointments.validate(input);
    if (validation_errors.any()) {
        return respondStageCard(
            allocator,
            request,
            database,
            stage,
            request_kind,
            .unprocessable_entity,
            .{
                .stage_id = stage.id,
                .appointment = .{
                    .input = input,
                    .errors = validation_errors,
                },
            },
        );
    }
    _ = try appointments.create(allocator, database, stage.id, input);
    return respondStageCard(
        allocator,
        request,
        database,
        stage,
        request_kind,
        .ok,
        .{},
    );
}

fn cancelAppointment(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    database: *db.Database,
    appointment_id: i64,
    request_kind: RequestKind,
) !void {
    const appointment = (try appointments.get(
        allocator,
        database,
        appointment_id,
    )) orelse {
        return respondError(
            allocator,
            request,
            .not_found,
            "Not found",
            "That interview does not exist.",
            request_kind,
        );
    };
    const stage_id = appointment.stage_id orelse return error.InvalidRelationship;
    const stage = (try stages.get(allocator, database, stage_id)).?;
    _ = appointments.cancel(allocator, database, appointment.id) catch |err| {
        if (err == error.InvalidTransition) {
            return respondError(
                allocator,
                request,
                .unprocessable_entity,
                "Invalid appointment transition",
                "That interview has already been cancelled.",
                request_kind,
            );
        }
        return err;
    };
    return respondStageCard(
        allocator,
        request,
        database,
        stage,
        request_kind,
        .ok,
        .{},
    );
}

fn addSource(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    database: *db.Database,
    form: FormData,
    request_kind: RequestKind,
) !void {
    const source_id = sources.create(database, form.new_source) catch |err| {
        if (err == error.InvalidSourceName) {
            const field = try views.buildSourceField(
                allocator,
                database,
                form.process.source_id,
                form.new_source,
                "Enter a source name of 120 characters or fewer.",
            );
            var output: std.Io.Writer.Allocating = .init(allocator);
            try views.renderSourceFieldFragment(&output.writer, field);
            return respondHtml(
                request,
                output.written(),
                .unprocessable_entity,
                &.{},
            );
        }
        return err;
    };
    var input = form.process;
    input.source_id = source_id;
    if (request_kind == .traditional) {
        if (input.applied_at.len == 0) input.applied_at = try localToday(allocator, database);
        const form_view = try views.buildProcessForm(
            allocator,
            database,
            input,
            .{},
            null,
        );
        var output: std.Io.Writer.Allocating = .init(allocator);
        try views.renderProcessFormPage(&output.writer, form_view);
        return respondHtml(request, output.written(), .ok, &.{});
    }
    const field = try views.buildSourceField(
        allocator,
        database,
        source_id,
        "",
        null,
    );
    var output: std.Io.Writer.Allocating = .init(allocator);
    try views.renderSourceFieldFragment(&output.writer, field);
    return respondHtml(request, output.written(), .ok, &.{});
}

fn saveCompensation(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    database: *db.Database,
    process_id: i64,
    kind: compensations.Kind,
    submitted: compensations.Input,
    request_kind: RequestKind,
) !void {
    if (try processes.get(allocator, database, process_id) == null) {
        return respondError(
            allocator,
            request,
            .not_found,
            "Not found",
            "That job process does not exist.",
            request_kind,
        );
    }
    var input = submitted;
    input.process_id = process_id;
    input.kind = kind;
    const validation_errors = compensations.validate(input);
    if (!validation_errors.any()) {
        if (compensations.isEmpty(input)) {
            try compensations.delete(database, process_id, kind);
        } else {
            try compensations.upsert(database, input);
        }
    }
    if (request_kind == .traditional and !validation_errors.any()) {
        return redirectToProcess(request, process_id);
    }
    const stage = try compensationContextStage(
        allocator,
        database,
        process_id,
        kind,
    );
    return respondStageCard(
        allocator,
        request,
        database,
        stage,
        request_kind,
        if (validation_errors.any()) .unprocessable_entity else .ok,
        .{
            .stage_id = stage.id,
            .compensation_kind = if (validation_errors.any()) kind else null,
            .compensation_input = input,
            .compensation_errors = validation_errors,
        },
    );
}

fn compensationContextStage(
    allocator: std.mem.Allocator,
    database: *db.Database,
    process_id: i64,
    kind: compensations.Kind,
) !stages.Stage {
    const target_kind: stages.Kind = switch (kind) {
        .advertised => .applied,
        .discussed => .hr,
        .offer => .offer,
    };
    const all_stages = try stages.listForProcess(allocator, database, process_id);
    for (all_stages) |stage| {
        if (stage.kind == target_kind) return stage;
    }
    return error.NotFound;
}

fn addLearningQuestion(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    database: *db.Database,
    stage_id: i64,
    question: []const u8,
    answer: []const u8,
    request_kind: RequestKind,
) !void {
    const stage = (try stages.get(allocator, database, stage_id)) orelse {
        return respondError(
            allocator,
            request,
            .not_found,
            "Not found",
            "That interview stage does not exist.",
            request_kind,
        );
    };
    return addQuestion(
        allocator,
        request,
        database,
        stage.process_id,
        stage.id,
        .learning,
        question,
        answer,
        request_kind,
    );
}

fn addQuestion(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    database: *db.Database,
    process_id: i64,
    stage_id: ?i64,
    kind: questions.Kind,
    question: []const u8,
    answer: []const u8,
    request_kind: RequestKind,
) !void {
    _ = questions.create(database, .{
        .process_id = process_id,
        .stage_id = stage_id,
        .kind = kind,
        .question = question,
        .answer = answer,
    }) catch |err| {
        if (err == error.InvalidQuestion or err == error.InvalidAnswer) {
            return respondQuestionRegion(
                allocator,
                request,
                database,
                process_id,
                stage_id,
                kind,
                request_kind,
                .unprocessable_entity,
                .{
                    .question = question,
                    .answer = answer,
                    .error_message = "Enter a question of 1,000 characters and an answer of 10,000 characters or fewer.",
                },
            );
        }
        return err;
    };
    return respondQuestionRegion(
        allocator,
        request,
        database,
        process_id,
        stage_id,
        kind,
        request_kind,
        .ok,
        .{},
    );
}

fn editQuestion(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    database: *db.Database,
    question_id: i64,
    question: []const u8,
    answer: []const u8,
    request_kind: RequestKind,
) !void {
    const stored = (try questions.get(allocator, database, question_id)) orelse {
        return respondError(
            allocator,
            request,
            .not_found,
            "Not found",
            "That question does not exist.",
            request_kind,
        );
    };
    questions.update(database, stored.id, .{
        .process_id = stored.process_id,
        .stage_id = stored.stage_id,
        .kind = stored.kind,
        .question = question,
        .answer = answer,
    }) catch |err| {
        if (err == error.InvalidQuestion or err == error.InvalidAnswer) {
            return respondQuestionRegion(
                allocator,
                request,
                database,
                stored.process_id,
                stored.stage_id,
                stored.kind,
                request_kind,
                .unprocessable_entity,
                .{
                    .question = question,
                    .answer = answer,
                    .error_message = "Question cannot be empty.",
                },
            );
        }
        return err;
    };
    return respondQuestionRegion(
        allocator,
        request,
        database,
        stored.process_id,
        stored.stage_id,
        stored.kind,
        request_kind,
        .ok,
        .{},
    );
}

fn deleteQuestion(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    database: *db.Database,
    question_id: i64,
    request_kind: RequestKind,
) !void {
    const stored = (try questions.get(allocator, database, question_id)) orelse
        return error.NotFound;
    try questions.delete(database, stored.id, stored.process_id);
    return respondQuestionRegion(
        allocator,
        request,
        database,
        stored.process_id,
        stored.stage_id,
        stored.kind,
        request_kind,
        .ok,
        .{},
    );
}

fn respondQuestionRegion(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    database: *db.Database,
    process_id: i64,
    stage_id: ?i64,
    kind: questions.Kind,
    request_kind: RequestKind,
    status: std.http.Status,
    form: view_models.QuestionForm,
) !void {
    if (request_kind == .traditional and status == .ok) {
        return redirectToProcess(request, process_id);
    }
    if (stage_id) |id| {
        const stage = (try stages.get(allocator, database, id)).?;
        return respondStageCard(
            allocator,
            request,
            database,
            stage,
            request_kind,
            status,
            .{
                .stage_id = stage.id,
                .learning_question = form,
            },
        );
    }
    const section = try views.buildQuestionSection(
        allocator,
        database,
        process_id,
        null,
        kind,
        form,
    );
    var output: std.Io.Writer.Allocating = .init(allocator);
    try views.renderCompanyQuestionsFragment(&output.writer, section);
    return respondHtml(request, output.written(), status, &.{});
}

fn deleteProcess(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    database: *db.Database,
    process_id: i64,
    request_kind: RequestKind,
) !void {
    processes.delete(database, process_id) catch |err| {
        if (err == error.NotFound) {
            return respondError(
                allocator,
                request,
                .not_found,
                "Not found",
                "That job process does not exist.",
                request_kind,
            );
        }
        return err;
    };
    if (request_kind == .traditional) {
        return request.respond("", .{
            .status = .see_other,
            .extra_headers = &.{.{
                .name = "location",
                .value = "/",
            }},
            .keep_alive = false,
        });
    }
    const stored = try processes.list(allocator, database);
    const dashboard = try views.buildDashboard(allocator, database, stored);
    var output: std.Io.Writer.Allocating = .init(allocator);
    try views.renderDashboardFragment(&output.writer, dashboard);
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
                .value = "/",
            },
        },
    );
}

fn respondTimeline(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    database: *db.Database,
    process_id: i64,
    request_kind: RequestKind,
    status: std.http.Status,
    form_state: view_models.TimelineFormState,
) !void {
    if (request_kind == .traditional and status == .ok) {
        return redirectToProcess(request, process_id);
    }
    const process = (try processes.get(allocator, database, process_id)) orelse
        return error.NotFound;
    var output: std.Io.Writer.Allocating = .init(allocator);
    if (request_kind == .traditional) {
        const detail = try views.buildProcessDetail(
            allocator,
            database,
            process,
            form_state,
        );
        try views.renderProcessDetailPage(&output.writer, detail);
    } else {
        const timeline = try views.buildStageTimelineView(
            allocator,
            database,
            process.id,
            process.current_stage_id,
            form_state,
        );
        try views.renderStageTimelineFragment(&output.writer, timeline);
    }
    return respondHtml(request, output.written(), status, &.{});
}

fn respondStageCard(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    database: *db.Database,
    original_stage: stages.Stage,
    request_kind: RequestKind,
    status: std.http.Status,
    form_state: view_models.TimelineFormState,
) !void {
    if (request_kind == .traditional and status == .ok) {
        return redirectToProcess(request, original_stage.process_id);
    }
    const process = (try processes.get(
        allocator,
        database,
        original_stage.process_id,
    )).?;
    var output: std.Io.Writer.Allocating = .init(allocator);
    if (request_kind == .traditional) {
        const detail = try views.buildProcessDetail(
            allocator,
            database,
            process,
            form_state,
        );
        try views.renderProcessDetailPage(&output.writer, detail);
    } else {
        const current_stage = (try stages.get(
            allocator,
            database,
            original_stage.id,
        )).?;
        const card = try views.buildStageCardView(
            allocator,
            database,
            current_stage,
            process.current_stage_id,
            form_state,
        );
        try views.renderStageCardFragment(&output.writer, card);
    }
    return respondHtml(request, output.written(), status, &.{});
}

fn redirectToProcess(
    request: *std.http.Server.Request,
    process_id: i64,
) !void {
    var buffer: [64]u8 = undefined;
    const location = try std.fmt.bufPrint(
        &buffer,
        "/processes/{d}",
        .{process_id},
    );
    return request.respond("", .{
        .status = .see_other,
        .extra_headers = &.{.{
            .name = "location",
            .value = location,
        }},
        .keep_alive = false,
    });
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

fn parseRoute(method: std.http.Method, target: []const u8) Route {
    if (method == .GET and std.mem.eql(u8, target, "/")) return .dashboard;
    if (method == .GET and std.mem.eql(u8, target, "/processes/new")) {
        return .new_process;
    }
    if (method == .POST and std.mem.eql(u8, target, "/processes")) {
        return .create_process;
    }
    if (method == .POST and std.mem.eql(u8, target, "/sources")) {
        return .add_source;
    }
    if (method == .GET and std.mem.eql(u8, target, "/static/app.css")) {
        return .static_css;
    }
    if (method == .GET and
        std.mem.eql(u8, target, "/static/vendor/htmx.min.js"))
    {
        return .static_htmx;
    }
    if (method == .GET and std.mem.eql(u8, target, "/favicon.svg")) {
        return .favicon;
    }

    var parts = std.mem.tokenizeScalar(u8, target, '/');
    const resource = parts.next() orelse return .not_found;
    const id_text = parts.next() orelse return .not_found;
    const id = std.fmt.parseInt(i64, id_text, 10) catch return .not_found;
    const action = parts.next();
    const detail = parts.next();
    if (parts.next() != null) return .not_found;

    if (std.mem.eql(u8, resource, "processes")) {
        if (action == null and method == .GET) return .{ .process_detail = id };
        if (action) |name| {
            if (detail != null) {
                if (method == .POST and
                    std.mem.eql(u8, name, "compensations"))
                {
                    const kind = compensations.parseKind(detail.?) catch
                        return .not_found;
                    return .{ .compensation = .{
                        .process_id = id,
                        .kind = kind,
                    } };
                }
                if (method == .POST and
                    std.mem.eql(u8, name, "questions") and
                    std.mem.eql(u8, detail.?, "company"))
                {
                    return .{ .add_company_question = id };
                }
                return .not_found;
            }
            if (std.mem.eql(u8, name, "edit") and
                (method == .GET or method == .POST))
            {
                return .{ .edit_process = id };
            }
            if (std.mem.eql(u8, name, "ratings") and method == .POST) {
                return .{ .update_ratings = id };
            }
            if (std.mem.eql(u8, name, "stages") and method == .POST) {
                return .{ .add_stage = id };
            }
            if (std.mem.eql(u8, name, "delete") and method == .POST) {
                return .{ .delete_process = id };
            }
        }
    }
    if (std.mem.eql(u8, resource, "stages") and method == .POST) {
        const name = action orelse return .not_found;
        if (detail != null) {
            if (std.mem.eql(u8, name, "questions") and
                std.mem.eql(u8, detail.?, "learning"))
            {
                return .{ .add_learning_question = id };
            }
            return .not_found;
        }
        if (std.mem.eql(u8, name, "outcome")) return .{ .stage_outcome = id };
        if (std.mem.eql(u8, name, "skip")) return .{ .skip_stage = id };
        if (std.mem.eql(u8, name, "reopen")) return .{ .reopen_stage = id };
        if (std.mem.eql(u8, name, "notes")) return .{ .add_stage_note = id };
        if (std.mem.eql(u8, name, "appointments")) {
            return .{ .schedule_appointment = id };
        }
    }
    if (std.mem.eql(u8, resource, "notes") and method == .POST) {
        if (detail != null) return .not_found;
        const name = action orelse return .not_found;
        if (std.mem.eql(u8, name, "edit")) return .{ .edit_note = id };
        if (std.mem.eql(u8, name, "delete")) return .{ .delete_note = id };
    }
    if (std.mem.eql(u8, resource, "appointments") and method == .POST) {
        if (detail != null) return .not_found;
        const name = action orelse return .not_found;
        if (std.mem.eql(u8, name, "cancel")) {
            return .{ .cancel_appointment = id };
        }
    }
    if (std.mem.eql(u8, resource, "questions") and method == .POST) {
        if (detail != null) return .not_found;
        const name = action orelse return .not_found;
        if (std.mem.eql(u8, name, "edit")) return .{ .edit_question = id };
        if (std.mem.eql(u8, name, "delete")) return .{ .delete_question = id };
    }
    return .not_found;
}

pub fn parseForm(allocator: std.mem.Allocator, body: []const u8) !processes.Input {
    return (try parseFormData(allocator, body)).process;
}

fn parseFormData(allocator: std.mem.Allocator, body: []const u8) !FormData {
    var form = FormData{};
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        const equals_index = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = pair[0..equals_index];
        const value = try decode(allocator, pair[equals_index + 1 ..]);
        try assignFormValue(&form, key, value);
    }
    finalizeCompensationInput(&form);
    return form;
}

fn assignFormValue(
    form: *FormData,
    key: []const u8,
    value: []u8,
) !void {
    if (std.mem.eql(u8, key, "name")) {
        form.name = value;
    } else if (std.mem.eql(u8, key, "kind")) {
        form.kind = value;
    } else if (std.mem.eql(u8, key, "outcome")) {
        form.outcome = value;
    } else if (std.mem.eql(u8, key, "reason")) {
        form.reason = value;
    } else if (std.mem.eql(u8, key, "new_source")) {
        form.new_source = value;
    } else if (std.mem.eql(u8, key, "question")) {
        form.question = value;
    } else if (std.mem.eql(u8, key, "answer")) {
        form.answer = value;
    } else if (std.mem.eql(u8, key, "body")) {
        form.body = value;
    } else if (std.mem.eql(u8, key, "title")) {
        form.appointment.title = value;
    } else if (std.mem.eql(u8, key, "starts_at")) {
        form.appointment.starts_at = value;
    } else if (std.mem.eql(u8, key, "ends_at")) {
        form.appointment.ends_at = value;
    } else if (std.mem.eql(u8, key, "meeting_url")) {
        form.appointment.meeting_url = value;
    } else if (std.mem.eql(u8, key, "contact_name")) {
        form.appointment.contact_name = value;
    } else if (std.mem.eql(u8, key, "preparation_note")) {
        form.appointment.preparation_note = value;
    } else if (std.mem.eql(u8, key, "company_name")) form.process.company_name = value else if (std.mem.eql(u8, key, "position_name")) form.process.position_name = value else if (std.mem.eql(u8, key, "job_url")) form.process.job_url = value else if (std.mem.eql(u8, key, "company_summary")) form.process.company_summary = value else if (std.mem.eql(u8, key, "applied_at")) form.process.applied_at = value else if (std.mem.eql(u8, key, "source_id")) {
        form.process.source_id = if (value.len == 0)
            null
        else
            std.fmt.parseInt(i64, value, 10) catch null;
    } else if (std.mem.eql(u8, key, "interest_rating")) {
        assignRating(value, &form.process.interest_rating, &form.process.interest_rating_invalid);
    } else if (std.mem.eql(u8, key, "money_rating")) {
        assignRating(value, &form.process.money_rating, &form.process.money_rating_invalid);
    } else if (std.mem.eql(u8, key, "growth_rating")) {
        assignRating(value, &form.process.growth_rating, &form.process.growth_rating_invalid);
    } else if (std.mem.eql(u8, key, "location")) {
        form.process.location = value;
        form.appointment.location = value;
    } else if (std.mem.eql(u8, key, "work_arrangement")) form.process.work_arrangement = value else if (std.mem.eql(u8, key, "amount")) assignAmountValue(&form.compensation_amount, value) else if (std.mem.eql(u8, key, "amount_from")) assignAmountValue(&form.compensation_from, value) else if (std.mem.eql(u8, key, "amount_to")) assignAmountValue(&form.compensation_to, value) else if (std.mem.eql(u8, key, "is_range")) form.compensation_is_range = true else if (std.mem.eql(u8, key, "currency")) form.compensation.currency = value else if (std.mem.eql(u8, key, "period")) form.compensation.period = value else if (std.mem.eql(u8, key, "salary_type")) form.compensation.salary_type = value else if (std.mem.eql(u8, key, "confirmed")) form.compensation.confirmed = true else if (std.mem.eql(u8, key, "notes")) form.compensation.notes = value;
}

const SalaryField = enum {
    minimum,
    maximum,
};

fn assignAmount(
    input: *compensations.Input,
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
            input.amount_min_text = value;
            input.amount_min = parsed;
            input.amount_min_invalid = invalid;
        },
        .maximum => {
            input.amount_max_text = value;
            input.amount_max = parsed;
            input.amount_max_invalid = invalid;
        },
    }
}

fn assignAmountValue(target: *AmountValue, value: []const u8) void {
    target.* = .{
        .text = value,
        .value = if (value.len == 0)
            null
        else
            std.fmt.parseInt(i64, value, 10) catch null,
        .invalid = value.len > 0 and
            (std.fmt.parseInt(i64, value, 10) catch null) == null,
    };
}

fn finalizeCompensationInput(form: *FormData) void {
    const minimum = if (form.compensation_is_range)
        form.compensation_from
    else
        form.compensation_amount;
    form.compensation.amount_min = minimum.value;
    form.compensation.amount_min_text = minimum.text;
    form.compensation.amount_min_invalid = minimum.invalid;
    if (form.compensation_is_range) {
        form.compensation.amount_max = form.compensation_to.value;
        form.compensation.amount_max_text = form.compensation_to.text;
        form.compensation.amount_max_invalid = form.compensation_to.invalid;
    }
}

fn assignRating(
    value: []const u8,
    parsed_value: *?i64,
    invalid: *bool,
) void {
    parsed_value.* = if (value.len == 0)
        null
    else
        std.fmt.parseInt(i64, value, 10) catch null;
    invalid.* = value.len > 0 and parsed_value.* == null;
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

fn localToday(
    allocator: std.mem.Allocator,
    database: *db.Database,
) ![]const u8 {
    var statement = try database.prepare(
        "SELECT strftime('%Y-%m-%d','now','localtime')",
    );
    defer statement.deinit();
    _ = try statement.step();
    return allocator.dupe(u8, statement.colText(0));
}

test "invalid compensation input is preserved as validation data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input = try parseForm(
        arena.allocator(),
        "company_name=Acme&position_name=Engineer&applied_at=2026-08-08&advertised_amount_min=12x&advertised_amount_max=wrong",
    );
    const errors = processes.validate(input);
    try std.testing.expectEqualStrings("12x", input.advertised.amount_min_text);
    try std.testing.expectEqualStrings("wrong", input.advertised.amount_max_text);
    try std.testing.expect(errors.advertised.amount_min != null);
    try std.testing.expect(errors.advertised.amount_max != null);
}

test "malformed percent encoding is rejected" {
    try std.testing.expectError(
        error.MalformedEncoding,
        parseForm(std.testing.allocator, "company_name=%Z"),
    );
}

test "workflow routes parse explicitly" {
    try std.testing.expectEqual(
        @as(i64, 42),
        parseRoute(.POST, "/processes/42/stages").add_stage,
    );
    try std.testing.expectEqual(
        @as(i64, 7),
        parseRoute(.POST, "/stages/7/outcome").stage_outcome,
    );
    try std.testing.expectEqual(
        @as(i64, 8),
        parseRoute(.POST, "/stages/8/notes").add_stage_note,
    );
    try std.testing.expectEqual(
        @as(i64, 9),
        parseRoute(.POST, "/notes/9/delete").delete_note,
    );
    try std.testing.expectEqual(
        @as(i64, 10),
        parseRoute(.POST, "/appointments/10/cancel").cancel_appointment,
    );
    try std.testing.expect(parseRoute(.POST, "/sources") == .add_source);
    try std.testing.expect(parseRoute(.GET, "/favicon.svg") == .favicon);
    try std.testing.expectEqual(
        @as(i64, 11),
        parseRoute(.POST, "/processes/11/delete").delete_process,
    );
    try std.testing.expectEqual(
        compensations.Kind.offer,
        parseRoute(
            .POST,
            "/processes/11/compensations/offer",
        ).compensation.kind,
    );
    try std.testing.expectEqual(
        @as(i64, 12),
        parseRoute(
            .POST,
            "/processes/12/questions/company",
        ).add_company_question,
    );
    try std.testing.expectEqual(
        @as(i64, 13),
        parseRoute(
            .POST,
            "/stages/13/questions/learning",
        ).add_learning_question,
    );
    try std.testing.expect(
        parseRoute(.GET, "/stages/7/outcome") == .not_found,
    );
}

test "workflow form data decodes notes stages and appointments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const form = try parseFormData(
        arena.allocator(),
        "name=CTO+interview&body=first%0Asecond&title=Interview&starts_at=2026-08-12T15%3A30&location=Google+Meet",
    );
    try std.testing.expectEqualStrings("CTO interview", form.name);
    try std.testing.expectEqualStrings("first\nsecond", form.body);
    try std.testing.expectEqualStrings("Interview", form.appointment.title);
    try std.testing.expectEqualStrings(
        "2026-08-12T15:30",
        form.appointment.starts_at,
    );
    try std.testing.expectEqualStrings("Google Meet", form.appointment.location);
}

test "Job Model V2 form data preserves typed values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const form = try parseFormData(
        arena.allocator(),
        "applied_at=2026-08-08&source_id=5&interest_rating=4&kind=technical&outcome=rejected&reason=Role+changed&advertised_amount_min=5000&discussed_confirmed=1&question=Why%3F&answer=Growth",
    );
    try std.testing.expectEqualStrings("2026-08-08", form.process.applied_at);
    try std.testing.expectEqual(@as(?i64, 5), form.process.source_id);
    try std.testing.expectEqual(@as(?i64, 4), form.process.interest_rating);
    try std.testing.expectEqual(@as(?i64, 5000), form.process.advertised.amount_min);
    try std.testing.expect(form.process.discussed.confirmed);
    try std.testing.expectEqualStrings("technical", form.kind);
    try std.testing.expectEqualStrings("rejected", form.outcome);
    try std.testing.expectEqualStrings("Role changed", form.reason);
    try std.testing.expectEqualStrings("Why?", form.question);
    try std.testing.expectEqualStrings("Growth", form.answer);
}

test "salary editor parses a single amount and a range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const single = try parseFormData(
        arena.allocator(),
        "amount=5500&currency=EUR&period=month",
    );
    try std.testing.expectEqual(@as(?i64, 5500), single.compensation.amount_min);
    try std.testing.expectEqual(@as(?i64, null), single.compensation.amount_max);

    const range = try parseFormData(
        arena.allocator(),
        "amount=ignored&amount_from=5500&amount_to=6500&is_range=1",
    );
    try std.testing.expectEqual(@as(?i64, 5500), range.compensation.amount_min);
    try std.testing.expectEqual(@as(?i64, 6500), range.compensation.amount_max);
}

test "salary editor preserves invalid selected range values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const form = try parseFormData(
        arena.allocator(),
        "amount_from=wrong&amount_to=100&is_range=1",
    );
    const errors = compensations.validate(form.compensation);
    try std.testing.expect(form.compensation.amount_min_invalid);
    try std.testing.expectEqualStrings("wrong", form.compensation.amount_min_text);
    try std.testing.expect(errors.amount_min != null);
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
