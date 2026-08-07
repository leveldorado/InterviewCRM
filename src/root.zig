pub const Database = @import("database.zig").Database;
pub const assets = @import("assets.zig");
pub const migrations = @import("migrations.zig");
pub const processes = @import("processes.zig");
pub const stages = @import("stages.zig");
pub const notes = @import("notes.zig");
pub const appointments = @import("appointments.zig");
pub const compensations = @import("compensations.zig");
pub const questions = @import("questions.zig");
pub const sources = @import("sources.zig");
pub const views = @import("views.zig");
pub const view_models = @import("view_models.zig");
pub const config = @import("config.zig");
pub const server = @import("server.zig");

const std = @import("std");

fn memoryDb() !Database {
    return Database.open(":memory:");
}

test "migration 003 is idempotent and preserves pre-V2 values" {
    var database = try memoryDb();
    defer database.close();
    try migrations.applyRegistry(&database, migrations.registry[0..2]);
    try database.exec(
        \\INSERT INTO job_processes(
        \\ id,company_name,position_name,source,salary_discussed,
        \\ salary_amount_min,salary_amount_max,salary_currency,salary_period,
        \\ salary_type,salary_notes,created_at,updated_at
        \\) VALUES(
        \\ 1,'Legacy','Engineer','Telegram channel',1,5000,6000,'EUR','month',
        \\ 'gross','FOP','2026-07-01 10:00:00','2026-07-01 10:00:00'
        \\)
    );
    try database.exec(
        \\INSERT INTO stages(
        \\ process_id,name,position,status,created_at,updated_at
        \\) VALUES
        \\ (1,'Resume sent',1,'in_progress',datetime('now'),datetime('now')),
        \\ (1,'Technical assignment',2,'planned',datetime('now'),datetime('now'))
    );
    try database.exec(
        \\INSERT INTO notes(
        \\ process_id,stage_id,category,body,created_at,updated_at
        \\) VALUES(1,1,'general','Legacy note',datetime('now'),datetime('now'));
        \\INSERT INTO appointments(
        \\ process_id,stage_id,title,starts_at,status,created_at,updated_at
        \\) VALUES(1,1,'Legacy interview','2026-08-12T15:30','scheduled',datetime('now'),datetime('now'));
        \\INSERT INTO activity_log(
        \\ process_id,activity_type,description,created_at
        \\) VALUES(1,'legacy','Legacy activity',datetime('now'))
    );
    try migrations.apply(&database);
    try migrations.apply(&database);
    try std.testing.expectEqual(
        @as(i64, 3),
        try database.scalarInt("SELECT count(*) FROM schema_migrations"),
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        try database.scalarInt(
            "SELECT count(*) FROM job_processes p JOIN sources s ON s.id=p.source_id WHERE p.id=1 AND s.name='Telegram channel' AND p.applied_at=p.created_at",
        ),
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        try database.scalarInt(
            "SELECT count(*) FROM compensations WHERE process_id=1 AND kind='discussed' AND amount_min=5000 AND amount_max=6000 AND currency='EUR' AND confirmed=1 AND notes='FOP'",
        ),
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        try database.scalarInt(
            "SELECT count(*) FROM stages WHERE process_id=1 AND name='Applied' AND kind='applied'",
        ),
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        try database.scalarInt(
            "SELECT count(*) FROM stages WHERE process_id=1 AND name='Technical assignment' AND kind='custom'",
        ),
    );
    try std.testing.expectEqual(
        @as(i64, 3),
        try database.scalarInt(
            "SELECT (SELECT count(*) FROM notes)+(SELECT count(*) FROM appointments)+(SELECT count(*) FROM activity_log)",
        ),
    );
}

test "new process creates only Applied and persists ratings and compensation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var database = try memoryDb();
    defer database.close();
    try migrations.apply(&database);
    const id = try processes.create(&database, .{
        .company_name = "ExamplePay",
        .position_name = "Senior Go Engineer",
        .applied_at = "2026-08-08",
        .interest_rating = 5,
        .money_rating = 4,
        .growth_rating = 5,
        .advertised = .{
            .kind = .advertised,
            .amount_min = 5000,
            .amount_max = 6000,
            .currency = "eur",
            .period = "month",
        },
        .discussed = .{
            .kind = .discussed,
            .confirmed = true,
        },
    });
    try std.testing.expectEqual(
        @as(i64, 1),
        try database.scalarInt("SELECT count(*) FROM stages WHERE process_id=1"),
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        try database.scalarInt(
            "SELECT count(*) FROM stages WHERE process_id=1 AND name='Applied' AND kind='applied' AND status='in_progress' AND id=(SELECT current_stage_id FROM job_processes WHERE id=1)",
        ),
    );
    const process = (try processes.get(arena.allocator(), &database, id)).?;
    try std.testing.expectEqualStrings("2026-08-08", process.input.applied_at);
    try std.testing.expectEqual(@as(?i64, 5), process.input.interest_rating);
    try std.testing.expectEqual(
        @as(i64, 2),
        try database.scalarInt("SELECT count(*) FROM compensations WHERE process_id=1"),
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        try database.scalarInt(
            "SELECT count(*) FROM compensations WHERE process_id=1 AND kind='advertised' AND currency='EUR'",
        ),
    );
}

test "stage outcomes enforce kind rules and update process status" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var database = try memoryDb();
    defer database.close();
    try migrations.apply(&database);
    const process_id = try processes.create(&database, .{
        .company_name = "Acme",
        .position_name = "Engineer",
        .applied_at = "2026-08-08",
    });
    const applied_id = try database.scalarInt(
        "SELECT current_stage_id FROM job_processes WHERE id=1",
    );
    const technical_id = try stages.add(
        allocator,
        &database,
        process_id,
        .technical,
        "",
    );
    _ = try stages.setOutcome(
        allocator,
        &database,
        applied_id,
        .next_step,
        "",
    );
    try std.testing.expectEqual(
        technical_id,
        try database.scalarInt("SELECT current_stage_id FROM job_processes"),
    );
    try std.testing.expectError(
        error.InvalidTransition,
        stages.setOutcome(
            allocator,
            &database,
            technical_id,
            .accepted,
            "",
        ),
    );
    _ = try stages.setOutcome(
        allocator,
        &database,
        technical_id,
        .rejected,
        "Company chose another candidate.",
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        try database.scalarInt(
            "SELECT count(*) FROM job_processes WHERE status='rejected' AND current_stage_id IS NULL AND closed_at IS NOT NULL",
        ),
    );
    _ = try stages.reopen(allocator, &database, technical_id);
    try std.testing.expectEqual(
        @as(i64, 1),
        try database.scalarInt(
            "SELECT count(*) FROM job_processes WHERE status='active' AND closed_at IS NULL AND current_stage_id=(SELECT id FROM stages WHERE kind='technical')",
        ),
    );

    _ = try stages.setOutcome(
        allocator,
        &database,
        technical_id,
        .next_step,
        "",
    );
    const offer_id = try stages.add(
        allocator,
        &database,
        process_id,
        .offer,
        "",
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        try database.scalarInt("SELECT count(*) FROM job_processes WHERE status='offer_received'"),
    );
    try std.testing.expectError(
        error.InvalidTransition,
        stages.setOutcome(allocator, &database, offer_id, .next_step, ""),
    );
    _ = try stages.setOutcome(
        allocator,
        &database,
        offer_id,
        .accepted,
        "",
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        try database.scalarInt("SELECT count(*) FROM job_processes WHERE status='accepted'"),
    );
}

test "withdrawn and declined outcomes set their terminal statuses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var database = try memoryDb();
    defer database.close();
    try migrations.apply(&database);

    const withdrawn_process = try processes.create(&database, .{
        .company_name = "Withdrawn Co",
        .position_name = "Engineer",
        .applied_at = "2026-08-08",
    });
    const withdrawn_stage = try database.scalarInt(
        "SELECT current_stage_id FROM job_processes WHERE id=1",
    );
    _ = try stages.setOutcome(
        allocator,
        &database,
        withdrawn_stage,
        .withdrawn,
        "Accepted another offer.",
    );

    const declined_process = try processes.create(&database, .{
        .company_name = "Declined Co",
        .position_name = "Engineer",
        .applied_at = "2026-08-08",
    });
    const applied_stage = try database.scalarInt(
        "SELECT current_stage_id FROM job_processes WHERE id=2",
    );
    _ = try stages.setOutcome(
        allocator,
        &database,
        applied_stage,
        .next_step,
        "",
    );
    const offer_stage = try stages.add(
        allocator,
        &database,
        declined_process,
        .offer,
        "",
    );
    _ = try stages.setOutcome(
        allocator,
        &database,
        offer_stage,
        .declined,
        "Salary below expectation.",
    );

    _ = withdrawn_process;
    try std.testing.expectEqual(
        @as(i64, 1),
        try database.scalarInt(
            "SELECT count(*) FROM job_processes WHERE status='withdrawn'",
        ),
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        try database.scalarInt(
            "SELECT count(*) FROM job_processes WHERE status='declined'",
        ),
    );
}

test "compensation validates ranges and supports upsert and delete" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var database = try memoryDb();
    defer database.close();
    try migrations.apply(&database);
    const process_id = try processes.create(&database, .{
        .company_name = "Acme",
        .position_name = "Engineer",
        .applied_at = "2026-08-08",
    });
    try std.testing.expect(compensations.validate(.{
        .amount_min = -1,
    }).any());
    try std.testing.expect(compensations.validate(.{
        .amount_min = 200,
        .amount_max = 100,
    }).any());
    try compensations.upsert(&database, .{
        .process_id = process_id,
        .kind = .discussed,
        .confirmed = true,
    });
    try compensations.upsert(&database, .{
        .process_id = process_id,
        .kind = .discussed,
        .amount_min = 5500,
        .amount_max = 6500,
        .currency = "eur",
        .period = "month",
        .confirmed = true,
    });
    const stored = (try compensations.getForProcess(
        arena.allocator(),
        &database,
        process_id,
        .discussed,
    )).?;
    try std.testing.expectEqualStrings("EUR", stored.currency.?);
    try std.testing.expectEqual(@as(?i64, 5500), stored.amount_min);
    try compensations.delete(&database, process_id, .discussed);
    try std.testing.expect((try compensations.getForProcess(
        arena.allocator(),
        &database,
        process_id,
        .discussed,
    )) == null);
}

test "sources compensation questions and hard delete preserve ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var database = try memoryDb();
    defer database.close();
    try migrations.apply(&database);
    try std.testing.expectEqual(
        @as(i64, 5),
        try database.scalarInt("SELECT count(*) FROM sources"),
    );
    const source_id = try sources.create(&database, "  LinkedIn  ");
    try std.testing.expectEqual(
        source_id,
        try sources.create(&database, "linkedin"),
    );
    const process_id = try processes.create(&database, .{
        .company_name = "Acme",
        .position_name = "Engineer",
        .applied_at = "2026-08-08",
        .source_id = source_id,
    });
    const stage_id = try database.scalarInt(
        "SELECT current_stage_id FROM job_processes",
    );
    try compensations.upsert(&database, .{
        .process_id = process_id,
        .kind = .offer,
        .amount_min = 6200,
        .currency = "eur",
        .period = "month",
    });
    const question_id = try questions.create(&database, .{
        .process_id = process_id,
        .kind = .company,
        .question = " Why is this role open? ",
    });
    try questions.update(&database, question_id, .{
        .process_id = process_id,
        .kind = .company,
        .question = "Why is this role open?",
        .answer = "Team expansion.",
    });
    try questions.delete(&database, question_id, process_id);
    _ = try questions.create(&database, .{
        .process_id = process_id,
        .kind = .company,
        .question = "How are decisions made?",
    });
    try std.testing.expectError(
        error.InvalidQuestion,
        questions.create(&database, .{
            .process_id = process_id,
            .kind = .company,
            .question = "   ",
        }),
    );
    _ = try questions.create(&database, .{
        .process_id = process_id,
        .stage_id = stage_id,
        .kind = .learning,
        .question = "How does MVCC work?",
    });
    try std.testing.expectError(
        error.InvalidRelationship,
        questions.create(&database, .{
            .process_id = process_id + 1,
            .stage_id = stage_id,
            .kind = .learning,
            .question = "Wrong owner",
        }),
    );
    _ = try notes.createForStage(
        &database,
        process_id,
        stage_id,
        .{ .body = "Prepare examples" },
    );
    _ = try appointments.create(allocator, &database, stage_id, .{
        .title = "Interview",
        .starts_at = "2026-08-12T15:30",
    });
    try processes.delete(&database, process_id);
    inline for (.{
        "stages",
        "notes",
        "appointments",
        "questions",
        "compensations",
        "activity_log",
    }) |table| {
        try std.testing.expectEqual(
            @as(i64, 0),
            try database.scalarInt("SELECT count(*) FROM " ++ table),
        );
    }
}
