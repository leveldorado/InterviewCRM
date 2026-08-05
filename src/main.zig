const std = @import("std");
const app = @import("interview_crm");
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const cfg = try app.config.load(a);
    if (std.fs.path.dirname(cfg.database)) |dir| try std.Io.Dir.cwd().createDirPath(init.io, dir);
    var database = try app.Database.open(cfg.database);
    defer database.close();
    try app.migrations.apply(&database);
    std.debug.print("Interview CRM running at http://{s}:{d}\n", .{ cfg.address, cfg.port });
    try app.server.serve(init.io, a, &database, cfg.address, cfg.port);
}
