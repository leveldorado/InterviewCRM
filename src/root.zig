pub const Database = @import("database.zig").Database;
pub const assets = @import("assets.zig");
pub const migrations = @import("migrations.zig");
pub const processes = @import("processes.zig");
pub const stages = @import("stages.zig");
pub const notes = @import("notes.zig");
pub const appointments = @import("appointments.zig");
pub const views = @import("views.zig");
pub const view_models = @import("view_models.zig");
pub const config = @import("config.zig");
pub const server = @import("server.zig");
const std = @import("std");
fn memoryDb() !Database {
    return Database.open(":memory:");
}
test "migrations empty idempotent and versioned" {
    var d = try memoryDb();
    defer d.close();
    try migrations.apply(&d);
    try migrations.apply(&d);
    try std.testing.expectEqual(@as(i64, 2), try d.scalarInt("SELECT count(*) FROM schema_migrations"));
    try std.testing.expectEqual(@as(i64, 5), try d.scalarInt("SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('job_processes','stages','appointments','notes','activity_log')"));
}
test "create update and missing lookup" {
    var d = try memoryDb();
    defer d.close();
    try migrations.apply(&d);
    const id = try processes.create(&d, .{ .company_name = "Acme", .position_name = "Engineer", .salary_discussed = true });
    const got = (try processes.get(std.testing.allocator, &d, id)).?;
    defer {
        std.testing.allocator.free(got.input.company_name);
        std.testing.allocator.free(got.input.position_name);
        std.testing.allocator.free(got.input.job_url);
        std.testing.allocator.free(got.input.source);
        std.testing.allocator.free(got.input.location);
        std.testing.allocator.free(got.input.work_arrangement);
        std.testing.allocator.free(got.input.currency);
        std.testing.allocator.free(got.input.period);
        std.testing.allocator.free(got.input.salary_type);
        std.testing.allocator.free(got.input.salary_notes);
        std.testing.allocator.free(got.status);
        std.testing.allocator.free(got.created_at);
        std.testing.allocator.free(got.updated_at);
    }
    try std.testing.expect(got.input.salary_discussed);
    try std.testing.expect(got.current_stage_id != null);
    try std.testing.expectEqual(
        @as(i64, 7),
        try d.scalarInt("SELECT count(*) FROM stages"),
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        try d.scalarInt("SELECT count(*) FROM stages WHERE position=1 AND status='in_progress'"),
    );
    try std.testing.expectEqual(
        @as(i64, 6),
        try d.scalarInt("SELECT count(*) FROM stages WHERE position>1 AND status='planned'"),
    );
    try processes.update(&d, id, .{ .company_name = "Acme 2", .position_name = "Engineer" });
    try std.testing.expect((try processes.get(std.testing.allocator, &d, 9999)) == null);
}

test "create rolls back when activity logging fails" {
    var database = try memoryDb();
    defer database.close();
    try migrations.apply(&database);
    try database.exec("DROP TABLE activity_log");
    try std.testing.expectError(error.Sqlite, processes.create(&database, .{ .company_name = "Acme", .position_name = "Engineer" }));
    try std.testing.expectEqual(@as(i64, 0), try database.scalarInt("SELECT count(*) FROM job_processes"));
    try std.testing.expectEqual(
        @as(i64, 0),
        try database.scalarInt("SELECT count(*) FROM stages"),
    );
}

test "update rolls back when activity logging fails" {
    var database = try memoryDb();
    defer database.close();
    try migrations.apply(&database);
    const id = try processes.create(&database, .{ .company_name = "Before", .position_name = "Engineer" });
    try database.exec("DROP TABLE activity_log");
    try std.testing.expectError(error.Sqlite, processes.update(&database, id, .{ .company_name = "After", .position_name = "Engineer" }));
    try std.testing.expectEqual(@as(i64, 1), try database.scalarInt("SELECT count(*) FROM job_processes WHERE company_name='Before'"));
}

test "custom stages append validate and become current when needed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var database = try memoryDb();
    defer database.close();
    try migrations.apply(&database);
    const process_id = try processes.create(&database, .{
        .company_name = "Acme",
        .position_name = "Engineer",
    });
    try std.testing.expectError(
        error.InvalidStageName,
        stages.addCustom(allocator, &database, process_id, "  "),
    );
    const custom_id = try stages.addCustom(
        allocator,
        &database,
        process_id,
        "  CTO interview  ",
    );
    try std.testing.expectEqual(
        @as(i64, 8),
        try database.scalarInt("SELECT position FROM stages WHERE name='CTO interview'"),
    );

    try database.exec("UPDATE job_processes SET current_stage_id=NULL; UPDATE stages SET status='completed';");
    const active_id = try stages.addCustom(
        allocator,
        &database,
        process_id,
        "Decision call",
    );
    try std.testing.expect(active_id != custom_id);
    try std.testing.expectEqual(
        active_id,
        try database.scalarInt("SELECT current_stage_id FROM job_processes"),
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        try database.scalarInt("SELECT count(*) FROM stages WHERE id=(SELECT current_stage_id FROM job_processes) AND status='in_progress'"),
    );
}

test "stage completion skip reopen and scheduled progression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var database = try memoryDb();
    defer database.close();
    try migrations.apply(&database);
    const process_id = try processes.create(&database, .{
        .company_name = "Acme",
        .position_name = "Engineer",
    });
    const first_id = try database.scalarInt(
        "SELECT id FROM stages WHERE position=1",
    );
    const second_id = try database.scalarInt(
        "SELECT id FROM stages WHERE position=2",
    );
    _ = try stages.complete(allocator, &database, first_id);
    try std.testing.expectEqual(
        second_id,
        try database.scalarInt("SELECT current_stage_id FROM job_processes"),
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        try database.scalarInt("SELECT count(*) FROM stages WHERE id=2 AND status='in_progress'"),
    );

    try database.exec("UPDATE stages SET status='scheduled' WHERE position=3;");
    _ = try stages.skip(allocator, &database, second_id);
    try std.testing.expectEqual(
        @as(i64, 1),
        try database.scalarInt("SELECT count(*) FROM stages WHERE position=3 AND status='scheduled' AND id=(SELECT current_stage_id FROM job_processes)"),
    );
    _ = try stages.reopen(allocator, &database, first_id);
    try std.testing.expectEqual(
        first_id,
        try database.scalarInt("SELECT current_stage_id FROM job_processes"),
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        try database.scalarInt("SELECT count(*) FROM stages WHERE id=1 AND status='in_progress' AND completed_at IS NULL"),
    );

    try database.exec("UPDATE stages SET status='completed'; UPDATE stages SET status='in_progress' WHERE position=7; UPDATE job_processes SET current_stage_id=(SELECT id FROM stages WHERE position=7);");
    const final_id = try database.scalarInt("SELECT id FROM stages WHERE position=7");
    _ = try stages.complete(allocator, &database, final_id);
    try std.testing.expectEqual(
        @as(i64, 1),
        try database.scalarInt("SELECT count(*) FROM job_processes WHERE current_stage_id IS NULL"),
    );
    _ = process_id;
}

test "stage completion and future skip rules are enforced by the domain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var database = try memoryDb();
    defer database.close();
    try migrations.apply(&database);
    _ = try processes.create(&database, .{
        .company_name = "Acme",
        .position_name = "Engineer",
    });

    const first_id = try database.scalarInt("SELECT id FROM stages WHERE position=1");
    const second_id = try database.scalarInt("SELECT id FROM stages WHERE position=2");
    const third_id = try database.scalarInt("SELECT id FROM stages WHERE position=3");
    const fourth_id = try database.scalarInt("SELECT id FROM stages WHERE position=4");
    const fifth_id = try database.scalarInt("SELECT id FROM stages WHERE position=5");
    const sixth_id = try database.scalarInt("SELECT id FROM stages WHERE position=6");

    _ = try stages.complete(allocator, &database, first_id);
    try std.testing.expectError(
        error.InvalidTransition,
        stages.complete(allocator, &database, first_id),
    );
    try database.exec("UPDATE stages SET status='scheduled' WHERE position=2;");
    _ = try stages.complete(allocator, &database, second_id);
    try std.testing.expectEqual(
        third_id,
        try database.scalarInt("SELECT current_stage_id FROM job_processes"),
    );

    try std.testing.expectError(
        error.InvalidTransition,
        stages.complete(allocator, &database, fifth_id),
    );
    try database.exec("UPDATE stages SET status='scheduled' WHERE position=4;");
    try std.testing.expectError(
        error.InvalidTransition,
        stages.complete(allocator, &database, fourth_id),
    );
    try database.exec("UPDATE stages SET status='skipped' WHERE position=6;");
    try std.testing.expectError(
        error.InvalidTransition,
        stages.complete(allocator, &database, sixth_id),
    );

    _ = try stages.skip(allocator, &database, fifth_id);
    try std.testing.expectEqual(
        third_id,
        try database.scalarInt("SELECT current_stage_id FROM job_processes"),
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        try database.scalarInt("SELECT count(*) FROM stages WHERE position=5 AND status='skipped'"),
    );
}

test "notes enforce ownership and retain escaped rendering input" {
    var database = try memoryDb();
    defer database.close();
    try migrations.apply(&database);
    const process_id = try processes.create(&database, .{
        .company_name = "Acme",
        .position_name = "Engineer",
    });
    const stage_id = try database.scalarInt("SELECT current_stage_id FROM job_processes");
    try std.testing.expectError(
        error.InvalidInput,
        notes.createForStage(&database, process_id, stage_id, .{}),
    );
    const note_id = try notes.createForStage(
        &database,
        process_id,
        stage_id,
        .{ .body = "  <script>alert(1)</script>\nPrepare  " },
    );
    try notes.updateStageNote(
        &database,
        process_id,
        stage_id,
        note_id,
        .{ .body = "Updated" },
    );
    try std.testing.expectError(
        error.NotFound,
        notes.updateStageNote(
            &database,
            process_id + 1,
            stage_id,
            note_id,
            .{ .body = "Wrong owner" },
        ),
    );
    try notes.deleteStageNote(&database, process_id, stage_id, note_id);
    try std.testing.expectEqual(
        @as(i64, 0),
        try database.scalarInt("SELECT count(*) FROM notes"),
    );
}

test "appointments validate schedule current stages and retain cancellation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var database = try memoryDb();
    defer database.close();
    try migrations.apply(&database);
    const process_id = try processes.create(&database, .{
        .company_name = "Acme",
        .position_name = "Engineer",
    });
    const stage_id = try database.scalarInt("SELECT current_stage_id FROM job_processes");
    const input = appointments.Input{
        .title = "Recruiter interview",
        .starts_at = "2026-08-12T15:30",
        .ends_at = "2026-08-12T16:00",
        .meeting_url = "https://meet.example.com/room",
    };
    const appointment_id = try appointments.create(
        allocator,
        &database,
        stage_id,
        input,
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        try database.scalarInt("SELECT count(*) FROM appointments WHERE process_id=(SELECT id FROM job_processes) AND stage_id=(SELECT current_stage_id FROM job_processes)"),
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        try database.scalarInt("SELECT count(*) FROM stages WHERE id=(SELECT current_stage_id FROM job_processes) AND status='scheduled'"),
    );
    _ = try appointments.cancel(
        allocator,
        &database,
        appointment_id,
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        try database.scalarInt("SELECT count(*) FROM appointments WHERE status='cancelled'"),
    );
    try std.testing.expectError(
        error.InvalidTransition,
        appointments.cancel(allocator, &database, appointment_id),
    );

    try database.exec("UPDATE stages SET status='completed' WHERE id=(SELECT current_stage_id FROM job_processes);");
    const completed_appointment_id = try appointments.create(
        allocator,
        &database,
        stage_id,
        input,
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        try database.scalarInt("SELECT count(*) FROM stages WHERE id=(SELECT current_stage_id FROM job_processes) AND status='completed'"),
    );
    try database.exec("UPDATE appointments SET status='completed' WHERE id=2;");
    try std.testing.expectError(
        error.InvalidTransition,
        appointments.cancel(
            allocator,
            &database,
            completed_appointment_id,
        ),
    );
    _ = process_id;
}

test "transactional workflow mutations roll back when activity logging fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var database = try memoryDb();
    defer database.close();
    try migrations.apply(&database);
    const process_id = try processes.create(&database, .{
        .company_name = "Acme",
        .position_name = "Engineer",
    });
    const stage_id = try database.scalarInt("SELECT current_stage_id FROM job_processes");
    try database.exec("DROP TABLE activity_log");

    try std.testing.expectError(
        error.Sqlite,
        stages.complete(allocator, &database, stage_id),
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        try database.scalarInt("SELECT count(*) FROM stages WHERE id=(SELECT current_stage_id FROM job_processes) AND status='in_progress'"),
    );
    try std.testing.expectError(
        error.Sqlite,
        stages.addCustom(
            allocator,
            &database,
            process_id,
            "CTO interview",
        ),
    );
    try std.testing.expectEqual(
        @as(i64, 7),
        try database.scalarInt("SELECT count(*) FROM stages"),
    );
    try std.testing.expectError(
        error.Sqlite,
        appointments.create(
            allocator,
            &database,
            stage_id,
            .{
                .title = "Interview",
                .starts_at = "2026-08-12T15:30",
            },
        ),
    );
    try std.testing.expectEqual(
        @as(i64, 0),
        try database.scalarInt("SELECT count(*) FROM appointments"),
    );
}
