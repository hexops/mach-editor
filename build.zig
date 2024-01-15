const std = @import("std");
const mach = @import("mach");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // TODO(sysgpu): re-enable
    // const mach_sysgpu = b.dependency("mach_sysgpu", .{ .target = target, .optimize = optimize });
    const spirv_cross_dep = b.dependency("spirv_cross", .{ .target = target, .optimize = optimize });
    const spirv_tools_dep = b.dependency("spirv_tools", .{ .target = target, .optimize = optimize });

    const app = try mach.App.init(b, .{
        .name = "mach",
        .src = "src/app.zig",
        .custom_entrypoint = "src/main.zig",
        .target = target,
        .optimize = optimize,
        .deps = &[_]std.Build.Module.Import{},
    });
    // TODO(sysgpu): re-enable
    // app.compile.root_module.addImport("mach-sysgpu", mach_sysgpu.module("mach-sysgpu"));
    app.compile.linkLibrary(spirv_cross_dep.artifact("spirv-cross"));
    app.compile.linkLibrary(spirv_tools_dep.artifact("spirv-opt"));
    if (b.args) |args| app.run.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&app.run.step);

    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/app.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
