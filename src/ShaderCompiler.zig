const std = @import("std");
const c = @cImport({
    @cInclude("spirv-cross/spirv_cross_c.h");
    @cInclude("spirv-tools/libspirv.h");
});
const sysgpu = @import("mach-sysgpu");
const fail = @import("main.zig").fail;

const max_file_size = 100 * 1024 * 1024; // 100MB
const default_opengl_version = 450;
const default_spirv_version = 140;
const default_vulkan_version = 110;

pub const Environment = enum {
    spirv,
    vulkan,
    opengl,
    opengl_es,
    hlsl,
    msl,
};

pub fn compile(
    gpa: std.mem.Allocator,
    input_file: []const u8,
    output_file: ?[]const u8,
    env: Environment,
    version: ?u16,
) void {
    const file = std.fs.cwd().openFile(input_file, .{}) catch |err| switch (err) {
        error.FileNotFound => fail("input file ('{s}') not found", .{input_file}),
        else => fail("couldn't open input file ('{s}')", .{input_file}),
    };
    var data: [:0]const u8 = file.readToEndAllocOptions(gpa, max_file_size, null, @alignOf(u8), 0) catch |err| {
        fail("can't read input file: {s}", .{@errorName(err)});
    };
    defer gpa.free(data);

    if (std.mem.endsWith(u8, input_file, ".wgsl")) {
        var err_list = sysgpu.shader.ErrorList.init(gpa) catch |err| fail("{s}", .{@errorName(err)});
        var ast = sysgpu.shader.Ast.parse(gpa, &err_list, data) catch |err| switch (err) {
            error.Parsing => {
                err_list.print(data, input_file) catch fail("{s}", .{@errorName(err)});
                std.os.exit(1);
            },
            else => fail("{s}", .{@errorName(err)}),
        };
        var air = sysgpu.shader.Air.generate(gpa, &ast, &err_list, null) catch |err| switch (err) {
            error.AnalysisFail => {
                err_list.print(data, input_file) catch fail("{s}", .{@errorName(err)});
                std.os.exit(1);
            },
            else => fail("{s}", .{@errorName(err)}),
        };
        ast.deinit(gpa);
        data = blk: {
            const spirv_data = sysgpu.shader.CodeGen.generate(gpa, &air, .spirv, .{}, null) catch |err| {
                fail("{s}", .{@errorName(err)});
            };
            air.deinit(gpa);
            const spirv_data_z = gpa.allocSentinel(u8, spirv_data.len, 0) catch |err| fail("{s}", .{@errorName(err)});
            @memcpy(spirv_data_z, spirv_data);
            gpa.free(spirv_data);
            gpa.free(data);
            break :blk spirv_data_z;
        };
    } else if (!std.mem.endsWith(u8, input_file, ".spv")) {
        fail("unknown file extension: {s}", .{input_file});
    }

    const words: []const u32 = @as([*]const u32, @ptrCast(@alignCast(data.ptr)))[0 .. data.len / @sizeOf(u32)];
    var optimized_spirv: c.spv_binary = undefined;

    // SPIRV-Optimizer
    const target_env = createTargetEnv(env, version) catch fail("invalid version: {?d}", .{version});
    const optimizer = c.spvOptimizerCreate(target_env);
    defer c.spvOptimizerDestroy(optimizer);

    c.spvOptimizerSetMessageConsumer(optimizer, optMessageConsumer);
    c.spvOptimizerRegisterPerformancePasses(optimizer);
    c.spvOptimizerRegisterLegalizationPasses(optimizer);

    const opt_options = c.spvOptimizerOptionsCreate();
    defer c.spvOptimizerOptionsDestroy(opt_options);
    c.spvOptimizerOptionsSetRunValidator(opt_options, false);

    const res = c.spvOptimizerRun(optimizer, words.ptr, words.len, &optimized_spirv, opt_options);
    switch (res) {
        c.SPV_SUCCESS => {},
        else => fail("optimizing spirv input failed: {d}", .{res}),
    }

    if (env == .spirv or env == .vulkan) {
        if (output_file) |o| {
            return std.fs.cwd().writeFile(
                o,
                @as([*]const u8, @ptrCast(@alignCast(optimized_spirv.*.code)))[0 .. optimized_spirv.*.wordCount * 4],
            ) catch |err| {
                fail("can't write to output file: {s}", .{@errorName(err)});
            };
        } else {
            fail("can't write binary file to stdout. please specify an output file", .{});
        }
    }

    // SPIRV-Cross
    var context: c.spvc_context = undefined;
    _ = c.spvc_context_create(&context);
    defer c.spvc_context_destroy(context);
    c.spvc_context_set_error_callback(context, errorCallback, null);

    var ir: c.spvc_parsed_ir = undefined;
    _ = c.spvc_context_parse_spirv(context, optimized_spirv.*.code, optimized_spirv.*.wordCount, &ir);

    var compiler: c.spvc_compiler = undefined;
    _ = c.spvc_context_create_compiler(
        context,
        envToSpirVBackend(env),
        ir,
        c.SPVC_CAPTURE_MODE_TAKE_OWNERSHIP,
        &compiler,
    );

    var options: c.spvc_compiler_options = undefined;
    _ = c.spvc_compiler_create_compiler_options(compiler, &options);
    switch (env) {
        .opengl => {
            _ = c.spvc_compiler_options_set_uint(options, c.SPVC_COMPILER_OPTION_GLSL_VERSION, version orelse default_opengl_version);
            _ = c.spvc_compiler_options_set_bool(options, c.SPVC_COMPILER_OPTION_GLSL_ES, c.SPVC_FALSE);
        },
        .opengl_es => {
            _ = c.spvc_compiler_options_set_uint(options, c.SPVC_COMPILER_OPTION_GLSL_VERSION, version orelse default_opengl_version);
            _ = c.spvc_compiler_options_set_bool(options, c.SPVC_COMPILER_OPTION_GLSL_ES, c.SPVC_TRUE);
        },
        else => {},
    }
    _ = c.spvc_compiler_install_compiler_options(compiler, options);

    var result: [*c]const u8 = undefined;
    _ = c.spvc_compiler_compile(compiler, &result);

    if (output_file) |o| {
        std.fs.cwd().writeFile(o, std.mem.span(result)) catch |err| {
            fail("can't write to output file: {s}", .{@errorName(err)});
        };
    } else {
        _ = std.io.getStdOut().write(std.mem.span(result)) catch |err| {
            fail("writing to standard output failed: {s}", .{@errorName(err)});
        };
    }
}

fn optMessageConsumer(
    level: c.spv_message_level_t,
    src: [*c]const u8,
    pos: [*c]const c.spv_position_t,
    msg: [*c]const u8,
) callconv(.C) void {
    switch (level) {
        c.SPV_MSG_FATAL,
        c.SPV_MSG_INTERNAL_ERROR,
        c.SPV_MSG_ERROR,
        => {
            fail("{s} at :{d}:{d}\n{s}", .{
                std.mem.span(msg),
                pos.*.line,
                pos.*.column,
                std.mem.span(src),
            });
        },
        else => {},
    }
}

fn errorCallback(userdata: ?*anyopaque, err: [*c]const u8) callconv(.C) void {
    _ = userdata;
    fail("{s}", .{std.mem.span(err)}) catch {};
}

fn envToSpirVBackend(env: Environment) c_uint {
    return switch (env) {
        .opengl, .opengl_es => c.SPVC_BACKEND_GLSL,
        .hlsl => c.SPVC_BACKEND_HLSL,
        .msl => c.SPVC_BACKEND_MSL,
        .spirv, .vulkan => unreachable,
    };
}

fn createTargetEnv(env: Environment, version: ?u16) !c.spv_target_env {
    return switch (env) {
        .opengl, .opengl_es => switch (version orelse default_opengl_version) {
            400 => c.SPV_ENV_OPENGL_4_0,
            410 => c.SPV_ENV_OPENGL_4_1,
            420 => c.SPV_ENV_OPENGL_4_2,
            430 => c.SPV_ENV_OPENGL_4_3,
            450 => c.SPV_ENV_OPENGL_4_5,
            else => error.InvalidVersion,
        },
        .spirv => switch (version orelse default_spirv_version) {
            100 => c.SPV_ENV_UNIVERSAL_1_0,
            110 => c.SPV_ENV_UNIVERSAL_1_1,
            120 => c.SPV_ENV_UNIVERSAL_1_2,
            130 => c.SPV_ENV_UNIVERSAL_1_3,
            140 => c.SPV_ENV_UNIVERSAL_1_4,
            150 => c.SPV_ENV_UNIVERSAL_1_5,
            160 => c.SPV_ENV_UNIVERSAL_1_6,
            else => error.InvalidVersion,
        },
        .vulkan => switch (version orelse default_vulkan_version) {
            100 => c.SPV_ENV_VULKAN_1_0,
            110 => c.SPV_ENV_VULKAN_1_1,
            120 => c.SPV_ENV_VULKAN_1_2,
            130 => c.SPV_ENV_VULKAN_1_3,
            else => error.InvalidVersion,
        },
        else => c.SPV_ENV_UNIVERSAL_1_4,
    };
}
