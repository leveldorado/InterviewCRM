const std = @import("std");
const zt = @import("zt");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zt_dependency = b.dependency("zt", .{
        .target = target,
        .optimize = optimize,
    });
    const zt_compiler = zt_dependency.artifact("zt-compile");
    zt_compiler.root_module.root_source_file = b.path("tools/zt_compile.zig");
    zt_compiler.root_module.addImport("zt", zt_dependency.module("zt"));
    const templates_step = zt.addTemplates(
        b,
        zt_dependency,
        &.{
            b.path("src/templates/layout.zt"),
            b.path("src/templates/components.zt"),
            b.path("src/templates/dashboard.zt"),
            b.path("src/templates/process_form.zt"),
            b.path("src/templates/process_detail.zt"),
            b.path("src/templates/error_page.zt"),
        },
    );

    const application_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    application_module.addImport("zt", zt_dependency.module("zt"));
    application_module.linkSystemLibrary("sqlite3", .{});

    const executable_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    executable_module.addImport("interview_crm", application_module);
    const executable = b.addExecutable(.{
        .name = "interview-crm",
        .root_module = executable_module,
    });
    executable.root_module.linkSystemLibrary("sqlite3", .{});
    executable.step.dependOn(templates_step);
    b.installArtifact(executable);

    const handwritten_zig_sources = &.{
        "build.zig",
        "src/assets.zig",
        "src/config.zig",
        "src/database.zig",
        "src/main.zig",
        "src/migrations.zig",
        "src/processes.zig",
        "src/root.zig",
        "src/server.zig",
        "src/view_models.zig",
        "src/views.zig",
        "tools/zt_compile.zig",
    };
    const format = b.addFmt(.{ .paths = handwritten_zig_sources });
    b.step("fmt", "Format Zig source files").dependOn(&format.step);

    const format_check = b.addFmt(.{
        .paths = handwritten_zig_sources,
        .check = true,
    });
    const check = b.step("check", "Verify formatting and compile the application");
    check.dependOn(&format_check.step);
    check.dependOn(&executable.step);

    const run = b.addRunArtifact(executable);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run Interview CRM").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = application_module });
    tests.step.dependOn(templates_step);
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run tests").dependOn(&run_tests.step);
}
