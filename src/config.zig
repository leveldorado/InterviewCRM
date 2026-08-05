const std = @import("std");
const c = @cImport({
    @cInclude("stdlib.h");
});
pub const Config = struct { address: []const u8, port: u16, database: [:0]const u8 };
fn env(name: [*:0]const u8) ?[]const u8 {
    const p = c.getenv(name) orelse return null;
    return std.mem.span(p);
}
pub fn load(a: std.mem.Allocator) !Config {
    const address = env("INTERVIEW_CRM_ADDRESS") orelse "127.0.0.1";
    const port = if (env("INTERVIEW_CRM_PORT")) |v| try std.fmt.parseInt(u16, v, 10) else 7331;
    if (env("INTERVIEW_CRM_DATABASE")) |v| return .{ .address = address, .port = port, .database = try a.dupeZ(u8, v) };
    const home = env("HOME") orelse return error.HomeNotSet;
    const suffix = if (@import("builtin").os.tag == .macos) "~/Library/Application Support/InterviewCRM/interview-crm.sqlite" else ".local/share/interview-crm/interview-crm.sqlite";
    return .{ .address = address, .port = port, .database = try std.fs.path.joinZ(a, &.{ home, suffix }) };
}
