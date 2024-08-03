const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "dough",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe.root_module.addImport("yazap", b.dependency("yazap", .{}).module("yazap"));
    exe.root_module.addImport("yaml", b.dependency("zig-yaml", .{}).module("yaml"));

    exe.linkSystemLibrary2("fdisk", .{
        .needed = true,
        .preferred_link_mode = .static,
    });
    b.installArtifact(exe);

    const fmt = b.addFmt(.{
        .check = true,
        .paths = &.{
            "src/main.zig",
        },
    });
    b.getInstallStep().dependOn(&fmt.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = exe.root_module.root_source_file.?,
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
