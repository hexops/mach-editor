const std = @import("std");
const mach = @import("mach");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const app = try mach.App.init(b, .{
        .name = "mach",
        .src = "src/app.zig",
        .custom_entrypoint = "src/main.zig",
        .target = target,
        .optimize = optimize,
        .deps = &[_]std.build.ModuleDependency{},
    });
    if (b.args) |args| app.run.addArgs(args);

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&app.run.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

// pub fn build(b: *std.Build) !void {
//     const optimize = b.standardOptimizeOption(.{});
//     const target = b.standardTargetOptions(.{});

//     if (target.getCpuArch() != .wasm32) {
//         const tests_step = b.step("test", "Run tests");
//         tests_step.dependOn(&testStep(b, optimize, target).step);

//         try editor.link();

//         const editor_install_step = b.step("editor", "Install editor");
//         editor_install_step.dependOn(&editor.install.step);

//         const editor_run_step = b.step("run", "Run the editor");
//         editor_run_step.dependOn(&editor.run.step);
//     }
// }

// fn testStep(b: *std.Build, optimize: std.builtin.OptimizeMode, target: std.zig.CrossTarget) *std.build.RunStep {
//     const main_tests = b.addTest(.{
//         .name = "mach-tests",
//         .root_source_file = .{ .path = "src/main.zig" },
//         .target = target,
//         .optimize = optimize,
//     });
//     var iter = module(b, optimize, target).dependencies.iterator();
//     while (iter.next()) |e| {
//         main_tests.addModule(e.key_ptr.*, e.value_ptr.*);
//     }
//     b.installArtifact(main_tests);
//     return b.addRunArtifact(main_tests);
// }
