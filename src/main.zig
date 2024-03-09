//! The 'mach' CLI and engine editor

// Check that the user's app matches the required interface.
comptime {
    if (!@import("builtin").is_test) @import("mach").core.AppInterface(@import("app"));
}

// Forward "app" declarations into our namespace, such that @import("root").foo works as expected.
pub usingnamespace @import("app");

const std = @import("std");
const builtin = @import("builtin");
const core = @import("mach").core;
// TODO(sysgpu): re-enable
// const sysgpu = @import("mach-sysgpu");
const Builder = @import("Builder.zig");
// TODO(sysgpu): re-enable
// const ShaderCompiler = @import("ShaderCompiler.zig");
const Target = @import("target.zig").Target;
const App = @import("app").App;
const eql = std.mem.eql;
const endsWith = std.mem.endsWith;

pub const GPUInterface = core.gpu.dawn.Interface;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    const cmd = args.next() orelse {
        try core.gpu.Impl.init(allocator, .{});
        _ = core.gpu.Export(GPUInterface);

        var app: App = undefined;
        try app.init();
        defer app.deinit();

        while (true) {
            if (try core.update(&app)) return;
        }
    };

    if (std.mem.eql(u8, cmd, "build")) {
        return build(allocator, &args);
    } else if (std.mem.eql(u8, cmd, "compile")) {
        fail("disabled", .{});
        // TODO(sysgpu): re-enable
        // return compile(allocator, &args);
    } else if (std.mem.eql(u8, cmd, "help")) {
        _ = try std.io.getStdOut().write(help_output);
    } else {
        fail("invalid command '{s}'", .{cmd});
    }
}

fn build(gpa: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    var builder = Builder{ .gpa = gpa };
    var steps = std.ArrayList([]const u8).init(gpa);
    var zig_args = std.ArrayList([]const u8).init(gpa);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "help")) {
            _ = try std.io.getStdOut().write(build_help_output);
            return;
        } else if (eql(u8, arg, "--zig-path")) {
            builder.zig_path = args.next() orelse fail("expected a path after {s}", .{arg});
        } else if (std.mem.eql(u8, arg, "--serve")) {
            if (builder.target == null) builder.target = .wasm32;
            if (builder.target.? != .wasm32) {
                fail("--serve requires --target=wasm32", .{});
            }
            builder.serve = true;
        } else if (eql(u8, arg, "--target")) {
            const target_triple = args.next() orelse fail("expected a target triple after {s}", .{arg});
            builder.target = Target.parse(target_triple) orelse {
                fail("invalid target '{s}'", .{arg});
            };
        } else if (eql(u8, arg, "--listen-port")) {
            const port_str = args.next() orelse fail("expected port number after {s}", .{arg});
            builder.listen_port = std.fmt.parseInt(u16, port_str, 10) catch {
                fail("invalid port '{s}'", .{arg});
            };
        } else if (eql(u8, arg, "--watch-path")) {
            const paths = args.next() orelse fail("expected a path after {s}", .{arg});
            var paths_splitted = std.mem.splitScalar(u8, paths, ',');
            builder.watch_paths = try gpa.alloc([]const u8, std.mem.count(u8, paths, ",") + 1);
            for (0..255) |i| {
                const path = paths_splitted.next() orelse break;
                builder.watch_paths.?[i] = std.mem.trim(u8, path, &std.ascii.whitespace);
            }
        } else if (eql(u8, arg, "--optimize")) {
            const opt = args.next() orelse fail("expected an optimization value after {s}", .{arg});
            builder.optimize = std.meta.stringToEnum(std.builtin.OptimizeMode, opt) orelse {
                fail("invalid optimize mode '{s}'", .{arg});
            };
        } else if (std.mem.eql(u8, arg, "--")) {
            while (args.next()) |zig_arg| {
                try zig_args.append(zig_arg);
            }
        } else {
            try steps.append(arg);
        }
    }

    builder.steps = try steps.toOwnedSlice();
    builder.zig_build_args = try zig_args.toOwnedSlice();
    try builder.run();
}

// TODO(sysgpu): re-enable
// fn compile(gpa: std.mem.Allocator, args: *std.process.ArgIterator) !void {
//     var input_file: ?[]const u8 = null;
//     var output_file: ?[]const u8 = null;
//     var env: ShaderCompiler.Environment = .opengl;
//     var version: ?u16 = null;

//     while (args.next()) |arg| {
//         if (eql(u8, arg, "help")) {
//             _ = try std.io.getStdOut().write(compile_help_output);
//             return;
//         } else if (eql(u8, arg, "--output") or eql(u8, arg, "-o")) {
//             output_file = args.next() orelse fail("expected output path after {s}", .{arg});
//         } else if (eql(u8, arg, "--target")) {
//             const target_str = args.next() orelse fail("expected target environment and version after {s}", .{arg});
//             var split_iter = std.mem.split(u8, target_str, "-");
//             const env_str = split_iter.first();
//             env = std.meta.stringToEnum(ShaderCompiler.Environment, env_str) orelse fail("invalid environment '{s}'", .{env_str});
//             if (split_iter.next()) |version_str| {
//                 version = std.fmt.parseInt(u16, version_str, 10) catch fail("invalid target version '{s}'", .{version_str});
//             }
//         } else if (input_file == null) {
//             input_file = arg;
//         } else {
//             fail("invalid argument '{s}'", .{arg});
//         }
//     }

//     if (input_file == null) {
//         fail("no input file has been specified", .{});
//     }

//     if (output_file) |o| {
//         if (endsWith(u8, o, ".spv")) {
//             env = .spirv;
//             version = 140;
//         } else if (endsWith(u8, o, ".glsl")) {
//             env = .opengl;
//             version = 450;
//         } else if (endsWith(u8, o, ".hlsl")) {
//             env = .hlsl;
//         } else if (endsWith(u8, o, ".msl")) {
//             env = .msl;
//         }
//     }

//     ShaderCompiler.compile(gpa, input_file.?, output_file, env, version);
// }

pub fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    const stderr = std.io.getStdErr();
    var tty_config = std.io.tty.detectConfig(std.io.getStdErr());

    tty_config.setColor(stderr, .bold) catch {};
    tty_config.setColor(stderr, .bright_red) catch {};
    _ = stderr.write("error: ") catch {};
    tty_config.setColor(stderr, .reset) catch {};
    _ = stderr.writer().print(fmt ++ "\n", args) catch {};

    const debug_info = std.debug.getSelfDebugInfo() catch std.os.exit(1);
    std.debug.writeCurrentStackTrace(stderr.writer(), debug_info, tty_config, @returnAddress()) catch std.os.exit(1);

    std.os.exit(1);
}

const build_help_output =
    \\Usage: 
    \\    mach build [steps] [options] [-- [zig build options]]
    \\
    \\General Options:
    \\  --zig-path    [path]     Override path to zig binary
    \\  --target      [target]   The CPU architecture and OS to build for
    \\                           Default is native target
    \\                           Available options:
    \\                             linux-x86_64,   linux-aarch64,
    \\                             macos-x86_64,   macos-aarch64,
    \\                             windows-x86_64, windows-aarch64,
    \\                             wasm32,
    \\  --optimize    [optimize] Prioritize performance, safety, or binary size
    \\                           Default is Debug
    \\                           Available options:
    \\                             Debug
    \\                             ReleaseSafe
    \\                             ReleaseFast
    \\                             ReleaseSmall
    \\
    \\Serve Options:
    \\  --serve                  Starts a development server
    \\                           for testing WASM applications/games
    \\  --listen-port [port]     The development server port
    \\  --watch-path  [paths]    Watches for changes in specified directory
    \\                           and automatically builds and reloads
    \\                           development server
    \\                           Separate each path with comma (,)
    \\
;

const compile_help_output =
    \\Usage: 
    \\    mach compile [input file] [options]
    \\
    \\Options:
    \\  --output, -o   [path]            Path to output file.
    \\  --target       [<ENV>-<VERSION>] Available environments:
    \\                                     vulkan
    \\                                     spirv
    \\                                     opengl
    \\                                     opengl_es
    \\                                     hlsl
    \\                                     msl
    \\                                   e.g. opengl-450
    \\
;

const help_output =
    \\Usage: 
    \\  mach [command]
    \\
    \\Commands:
    \\  build    Build current project
    \\  compile  Compile a shader unit
    \\  help     Print this mesage
    \\
;
