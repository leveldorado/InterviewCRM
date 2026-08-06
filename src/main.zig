const std = @import("std");
const app = @import("interview_crm");
pub fn main(init: std.process.Init) !void {
    const startup_allocator = init.arena.allocator();
    const configuration = try app.config.load(startup_allocator);
    try app.config.ensureDatabaseDirectory(init.io, configuration.database);

    var database = try app.Database.open(configuration.database);
    defer database.close();
    try app.migrations.apply(&database);

    std.debug.print(
        "Interview CRM running at http://{s}:{d}\n",
        .{ configuration.address, configuration.port },
    );
    try app.server.serve(
        init.io,
        &database,
        configuration.address,
        configuration.port,
    );
}
