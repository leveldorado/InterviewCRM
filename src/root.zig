pub const Database = @import("database.zig").Database;
pub const migrations = @import("migrations.zig");
pub const processes = @import("processes.zig");
pub const views = @import("views.zig");
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
    try std.testing.expectEqual(@as(i64, 1), try d.scalarInt("SELECT count(*) FROM schema_migrations WHERE version=1"));
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
    try processes.update(&d, id, .{ .company_name = "Acme 2", .position_name = "Engineer" });
    try std.testing.expect((try processes.get(std.testing.allocator, &d, 9999)) == null);
}
