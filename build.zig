const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.linkSystemLibrary("sqlite3", .{});
    const exe = b.addExecutable(.{ .name = "interview-crm", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "interview_crm", .module = module }},
    }) });
    exe.root_module.linkSystemLibrary("sqlite3", .{});
    b.installArtifact(exe);

    const zig_sources = &.{ "build.zig", "src" };
    const format = b.addFmt(.{ .paths = zig_sources });
    b.step("fmt", "Format Zig source files").dependOn(&format.step);

    const format_check = b.addFmt(.{ .paths = zig_sources, .check = true });
    const check = b.step("check", "Verify formatting and compile the application");
    check.dependOn(&format_check.step);
    check.dependOn(&exe.step);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run Interview CRM").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = module });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run tests").dependOn(&run_tests.step);
}
