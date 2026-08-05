const std = @import("std");
const c = @cImport({
    @cInclude("stdlib.h");
});
pub const Config = struct { address: []const u8, port: u16, database: [:0]const u8 };
pub const Platform = enum { macos, linux };
fn env(name: [*:0]const u8) ?[]const u8 {
    const p = c.getenv(name) orelse return null;
    return std.mem.span(p);
}
pub fn load(a: std.mem.Allocator) !Config {
    const address = env("INTERVIEW_CRM_ADDRESS") orelse "127.0.0.1";
    const port = if (env("INTERVIEW_CRM_PORT")) |v| try std.fmt.parseInt(u16, v, 10) else 7331;
    if (env("INTERVIEW_CRM_DATABASE")) |v| return .{ .address = address, .port = port, .database = try a.dupeZ(u8, v) };
    const home = env("HOME") orelse return error.HomeNotSet;
    const platform: Platform = if (@import("builtin").os.tag == .macos) .macos else .linux;
    return .{ .address = address, .port = port, .database = try resolveDatabasePath(a, platform, home, env("XDG_DATA_HOME")) };
}

pub fn resolveDatabasePath(a: std.mem.Allocator, platform: Platform, home: []const u8, xdg_data_home: ?[]const u8) ![:0]u8 {
    return switch (platform) {
        .macos => std.fs.path.joinZ(a, &.{ home, "Library/Application Support/InterviewCRM/interview-crm.sqlite" }),
        .linux => if (xdg_data_home) |xdg|
            std.fs.path.joinZ(a, &.{ xdg, "interview-crm/interview-crm.sqlite" })
        else
            std.fs.path.joinZ(a, &.{ home, ".local/share/interview-crm/interview-crm.sqlite" }),
    };
}

test "platform database paths" {
    const a = std.testing.allocator;
    const mac = try resolveDatabasePath(a, .macos, "/Users/test", null);
    defer a.free(mac);
    try std.testing.expectEqualStrings("/Users/test/Library/Application Support/InterviewCRM/interview-crm.sqlite", mac);
    const linux = try resolveDatabasePath(a, .linux, "/home/test", null);
    defer a.free(linux);
    try std.testing.expectEqualStrings("/home/test/.local/share/interview-crm/interview-crm.sqlite", linux);
    const xdg = try resolveDatabasePath(a, .linux, "/home/test", "/var/data");
    defer a.free(xdg);
    try std.testing.expectEqualStrings("/var/data/interview-crm/interview-crm.sqlite", xdg);
}
