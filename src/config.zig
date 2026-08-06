const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("stdlib.h");
});

pub const Config = struct {
    address: []const u8,
    port: u16,
    database: [:0]const u8,
};

pub const Platform = enum {
    macos,
    linux,
};

pub const EnvironmentInput = struct {
    database_override: ?[]const u8,
    xdg_data_home: ?[]const u8,
    home: ?[]const u8,
    platform: Platform,
};

fn environmentValue(name: [*:0]const u8) ?[]const u8 {
    const value = c.getenv(name) orelse return null;
    return std.mem.span(value);
}

pub fn load(allocator: std.mem.Allocator) !Config {
    const address = environmentValue("INTERVIEW_CRM_ADDRESS") orelse "127.0.0.1";
    const configured_port = environmentValue("INTERVIEW_CRM_PORT");
    const port = if (configured_port) |value|
        try std.fmt.parseInt(u16, value, 10)
    else
        7331;
    const platform: Platform = if (builtin.os.tag == .macos) .macos else .linux;
    const database = try resolveDatabasePath(allocator, .{
        .database_override = environmentValue("INTERVIEW_CRM_DATABASE"),
        .xdg_data_home = environmentValue("XDG_DATA_HOME"),
        .home = environmentValue("HOME"),
        .platform = platform,
    });

    return .{
        .address = address,
        .port = port,
        .database = database,
    };
}

pub fn resolveDatabasePath(
    allocator: std.mem.Allocator,
    input: EnvironmentInput,
) ![:0]u8 {
    if (input.database_override) |database_override| {
        if (database_override.len == 0) return error.EmptyDatabaseOverride;
        return allocator.dupeZ(u8, database_override);
    }

    const home = input.home orelse return error.HomeNotSet;
    if (home.len == 0) return error.HomeNotSet;

    return switch (input.platform) {
        .macos => std.fs.path.joinZ(allocator, &.{
            home,
            "Library/Application Support/InterviewCRM/interview-crm.sqlite",
        }),
        .linux => if (input.xdg_data_home) |xdg_data_home|
            if (xdg_data_home.len > 0)
                std.fs.path.joinZ(allocator, &.{
                    xdg_data_home,
                    "interview-crm/interview-crm.sqlite",
                })
            else
                linuxHomePath(allocator, home)
        else
            linuxHomePath(allocator, home),
    };
}

fn linuxHomePath(allocator: std.mem.Allocator, home: []const u8) ![:0]u8 {
    return std.fs.path.joinZ(allocator, &.{
        home,
        ".local/share/interview-crm/interview-crm.sqlite",
    });
}

pub fn ensureDatabaseDirectory(io: std.Io, database_path: []const u8) !void {
    const directory = std.fs.path.dirname(database_path) orelse return;
    try std.Io.Dir.cwd().createDirPath(io, directory);
}

test "explicit database override" {
    const path = try resolveDatabasePath(std.testing.allocator, .{
        .database_override = "/tmp/custom.sqlite",
        .xdg_data_home = null,
        .home = null,
        .platform = .linux,
    });
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/custom.sqlite", path);
}

test "platform database paths" {
    const allocator = std.testing.allocator;
    const macos_path = try resolveDatabasePath(allocator, .{
        .database_override = null,
        .xdg_data_home = null,
        .home = "/Users/test",
        .platform = .macos,
    });
    defer allocator.free(macos_path);
    try std.testing.expectEqualStrings(
        "/Users/test/Library/Application Support/InterviewCRM/interview-crm.sqlite",
        macos_path,
    );

    const linux_path = try resolveDatabasePath(allocator, .{
        .database_override = null,
        .xdg_data_home = null,
        .home = "/home/test",
        .platform = .linux,
    });
    defer allocator.free(linux_path);
    try std.testing.expectEqualStrings(
        "/home/test/.local/share/interview-crm/interview-crm.sqlite",
        linux_path,
    );

    const xdg_path = try resolveDatabasePath(allocator, .{
        .database_override = null,
        .xdg_data_home = "/var/data",
        .home = "/home/test",
        .platform = .linux,
    });
    defer allocator.free(xdg_path);
    try std.testing.expectEqualStrings(
        "/var/data/interview-crm/interview-crm.sqlite",
        xdg_path,
    );
}

test "empty environment path values are handled explicitly" {
    try std.testing.expectError(
        error.EmptyDatabaseOverride,
        resolveDatabasePath(std.testing.allocator, .{
            .database_override = "",
            .xdg_data_home = null,
            .home = "/home/test",
            .platform = .linux,
        }),
    );
    try std.testing.expectError(
        error.HomeNotSet,
        resolveDatabasePath(std.testing.allocator, .{
            .database_override = null,
            .xdg_data_home = null,
            .home = null,
            .platform = .linux,
        }),
    );
    try std.testing.expectError(
        error.HomeNotSet,
        resolveDatabasePath(std.testing.allocator, .{
            .database_override = null,
            .xdg_data_home = null,
            .home = "",
            .platform = .linux,
        }),
    );

    const empty_xdg_path = try resolveDatabasePath(std.testing.allocator, .{
        .database_override = null,
        .xdg_data_home = "",
        .home = "/home/test",
        .platform = .linux,
    });
    defer std.testing.allocator.free(empty_xdg_path);
    try std.testing.expectEqualStrings(
        "/home/test/.local/share/interview-crm/interview-crm.sqlite",
        empty_xdg_path,
    );
}

test "database directory is created" {
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    const relative_database_path = "nested/data/interview-crm.sqlite";
    const absolute_database_path = try temporary_directory.dir.realPathFileAlloc(
        std.testing.allocator,
        ".",
        .{},
    );
    defer std.testing.allocator.free(absolute_database_path);
    const database_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ absolute_database_path, relative_database_path },
    );
    defer std.testing.allocator.free(database_path);

    try ensureDatabaseDirectory(std.testing.io, database_path);
    var directory = try temporary_directory.dir.openDir(
        std.testing.io,
        "nested/data",
        .{},
    );
    directory.close(std.testing.io);
}
