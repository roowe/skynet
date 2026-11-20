const std = @import("std");

// Match the Make build for the C sources even in Zig's debug mode.
const c_flags = [_][]const u8{ "-g", "-O2", "-Wall" };
const lua_c_flags = c_flags ++ [_][]const u8{ "-std=gnu99", "-Wextra" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const smoke = b.step("smoke", "Verify Lua startup, plugin loading, messaging, and timers");
    const test_timer = b.step("test-timer", "Compare C and Zig timer behavior with deterministic ticks");
    const test_mq = b.step("test-mq", "Run the message queue contract tests against C and Zig");
    const test_handle = b.step("test-handle", "Run the service handle contract tests against C and Zig");
    const macos = target.result.os.tag == .macos and target.result.cpu.arch == .aarch64;
    const linux = target.result.os.tag == .linux and target.result.isGnuLibC() and target.query.isNativeTriple();
    if (!macos and !linux) {
        const unsupported = b.addFail("this Zig build supports aarch64-macos and native Linux with glibc");
        b.getInstallStep().dependOn(&unsupported.step);
        smoke.dependOn(&unsupported.step);
        test_timer.dependOn(&unsupported.step);
        test_mq.dependOn(&unsupported.step);
        test_handle.dependOn(&unsupported.step);
        return;
    }

    const lua = b.addLibrary(.{
        .name = "skynet-lua",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    lua.root_module.addIncludePath(b.path("skynet-src"));
    const lua_platform = if (linux) "LUA_USE_LINUX" else "LUA_USE_MACOSX";
    lua.root_module.addCMacro(lua_platform, "1");
    lua.root_module.addCSourceFiles(.{
        .root = b.path("3rd/lua"),
        .flags = &lua_c_flags,
        .files = &.{
            "lapi.c",     "lcode.c",    "lctype.c",  "ldebug.c",   "ldo.c",      "ldump.c",
            "lfunc.c",    "lgc.c",      "llex.c",    "lmem.c",     "lobject.c",  "lopcodes.c",
            "lparser.c",  "lstate.c",   "lstring.c", "ltable.c",   "ltm.c",      "lundump.c",
            "lvm.c",      "lzio.c",     "lauxlib.c", "lbaselib.c", "lcorolib.c", "ldblib.c",
            "liolib.c",   "lmathlib.c", "loadlib.c", "loslib.c",   "lstrlib.c",  "ltablib.c",
            "lutf8lib.c", "linit.c",
        },
    });

    for ([_][]const u8{ "lua", "luac" }) |name| {
        const cli = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
        });
        if (std.mem.eql(u8, name, "lua")) {
            // The interpreter also loads native Lua extensions.
            cli.rdynamic = true;
            cli.link_gc_sections = false;
        }
        cli.root_module.linkLibrary(lua);
        if (linux) {
            cli.root_module.linkSystemLibrary("m", .{});
            cli.root_module.linkSystemLibrary("dl", .{});
        } else {
            cli.root_module.linkSystemLibrary("readline", .{});
        }
        cli.root_module.addIncludePath(b.path("skynet-src"));
        cli.root_module.addCMacro(lua_platform, "1");
        cli.root_module.addCSourceFile(.{ .file = b.path(b.fmt("3rd/lua/{s}.c", .{name})), .flags = &lua_c_flags });
        b.installArtifact(cli);
    }

    const skynet = b.addExecutable(.{
        .name = "skynet",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    // C services and Lua extensions resolve Skynet and Lua symbols from the host.
    skynet.rdynamic = true;
    skynet.link_gc_sections = false;
    skynet.root_module.linkLibrary(lua);
    skynet.root_module.addIncludePath(b.path("3rd/lua"));
    skynet.root_module.addIncludePath(b.path("skynet-src"));
    if (linux) {
        const jemalloc = buildJemalloc(b);
        skynet.root_module.addIncludePath(jemalloc.path(b, "include/jemalloc"));
        skynet.root_module.addObjectFile(jemalloc.path(b, "lib/libjemalloc_pic.a"));
        // jemalloc profiling uses the unwind ABI supplied implicitly by GCC.
        skynet.root_module.linkSystemLibrary("unwind", .{ .use_pkg_config = .no });
        for ([_][]const u8{ "pthread", "m", "dl", "rt" }) |name| {
            skynet.root_module.linkSystemLibrary(name, .{});
        }
    } else {
        skynet.root_module.addCMacro("NOUSE_JEMALLOC", "1");
    }
    skynet.root_module.addCSourceFiles(.{
        .root = b.path("skynet-src"),
        .flags = &c_flags,
        .files = &.{
            "skynet_main.c",   "skynet_module.c", "skynet_server.c", "skynet_start.c",
            "skynet_error.c",  "skynet_harbor.c", "skynet_env.c",    "skynet_monitor.c",
            "skynet_socket.c", "socket_server.c", "mem_info.c",      "malloc_hook.c",
            "skynet_daemon.c", "skynet_log.c",
        },
    });
    skynet.root_module.addCSourceFile(.{
        .file = b.path("skynet-src/skynet_timer.c"),
        .flags = &(c_flags ++ [_][]const u8{"-DSKYNET_ZIG_TIMER"}),
    });
    const timer = b.addObject(.{
        .name = "skynet-zig-timer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("skynet-src/skynet_zig_timer.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    skynet.root_module.addObject(timer);
    const mq = b.addObject(.{
        .name = "skynet-zig-mq",
        .root_module = b.createModule(.{
            .root_source_file = b.path("skynet-src/skynet_mq.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    skynet.root_module.addObject(mq);
    const handle = b.addObject(.{
        .name = "skynet-zig-handle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("skynet-src/skynet_handle.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    skynet.root_module.addObject(handle);
    b.installArtifact(skynet);

    for ([_][]const u8{ "snlua", "logger", "gate", "harbor" }) |name| {
        _ = addPlugin(b, target, optimize, "cservice", name, "service-src", &.{b.fmt("service_{s}.c", .{name})}, &.{});
    }
    _ = addPlugin(b, target, optimize, "luaclib", "skynet", "lualib-src", &.{
        "lua-skynet.c",    "lua-seri.c",      "lua-socket.c",       "lua-mongo.c",     "lua-netpack.c",
        "lua-memory.c",    "lua-multicast.c", "lua-cluster.c",      "lua-crypt.c",     "lsha1.c",
        "lua-sharedata.c", "lua-stm.c",       "lua-debugchannel.c", "lua-datasheet.c", "lua-sharetable.c",
    }, &.{"service-src"});
    const client = addPlugin(b, target, optimize, "luaclib", "client", "lualib-src", &.{
        "lua-clientsocket.c", "lua-crypt.c", "lsha1.c",
    }, &.{});
    if (linux) client.linkSystemLibrary("pthread", .{});
    _ = addPlugin(b, target, optimize, "luaclib", "bson", "lualib-src", &.{"lua-bson.c"}, &.{});
    _ = addPlugin(b, target, optimize, "luaclib", "sproto", "lualib-src/sproto", &.{ "sproto.c", "lsproto.c" }, &.{});
    _ = addPlugin(b, target, optimize, "luaclib", "md5", "3rd/lua-md5", &.{ "md5.c", "md5lib.c", "compat-5.2.c" }, &.{});
    _ = addPlugin(b, target, optimize, "luaclib", "lpeg", "3rd/lpeg", &.{
        "lpcap.c", "lpcode.c", "lpprint.c", "lptree.c", "lpvm.c", "lpcset.c",
    }, &.{});

    const run = b.addSystemCommand(&.{"/usr/bin/env"});
    run.setName("Skynet build smoke test");
    run.setCwd(b.path("."));
    run.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "" } }, .{
        .prefix = "SKYNET_BUILD_PREFIX=",
        .make_absolute = true,
    });
    run.addFileArg2(.{ .relative = .{ .base = .install_bin, .sub_path = "skynet" } }, .{ .make_absolute = true });
    run.addFileArg(b.path("test/config.build_smoke"));
    run.has_side_effects = true;
    run.expectStdOutMatch("skynet build smoke ok\n");
    run.step.dependOn(b.getInstallStep());
    smoke.dependOn(&run.step);

    const c_timer_tests = b.addExecutable(.{
        .name = "c-timer-tests",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    c_timer_tests.root_module.addIncludePath(b.path("skynet-src"));
    c_timer_tests.root_module.addCSourceFile(.{
        .file = b.path("test/timer_wheel_c_test.c"),
        .flags = &(c_flags ++ [_][]const u8{"-DNOUSE_JEMALLOC"}),
    });
    test_timer.dependOn(&b.addRunArtifact(c_timer_tests).step);

    const zig_timer_tests = b.addTest(.{
        .name = "zig-timer-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/timer_wheel_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "timer_wheel", .module = b.createModule(.{
                .root_source_file = b.path("skynet-src/skynet_timer_wheel.zig"),
                .target = target,
                .optimize = optimize,
            }) }},
        }),
    });
    test_timer.dependOn(&b.addRunArtifact(zig_timer_tests).step);

    addCAbiTests(b, target, optimize, "mq", mq, test_mq);
    addCAbiTests(b, target, optimize, "handle", handle, test_handle);
}

fn addCAbiTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    component: []const u8,
    port: *std.Build.Step.Compile,
    step: *std.Build.Step,
) void {
    for ([_][]const u8{ "c", "zig" }, [_]bool{ false, true }) |implementation, use_zig| {
        const tests = b.addExecutable(.{
            .name = b.fmt("{s}-{s}-tests", .{ implementation, component }),
            .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
        });
        const module = tests.root_module;
        module.addIncludePath(b.path("skynet-src"));
        module.addCSourceFile(.{ .file = b.path(b.fmt("test/{s}_test.c", .{component})), .flags = &c_flags });
        if (target.result.os.tag == .linux) module.linkSystemLibrary("pthread", .{});
        if (use_zig) {
            module.addObject(port);
        } else {
            module.addCSourceFile(.{ .file = b.path(b.fmt("skynet-src/skynet_{s}.c", .{component})), .flags = &c_flags });
        }
        step.dependOn(&b.addRunArtifact(tests).step);
    }
}

fn buildJemalloc(b: *std.Build) std.Build.LazyPath {
    const revision = b.addSystemCommand(&.{ "git", "rev-parse", "HEAD:3rd/jemalloc" });
    revision.setCwd(b.path("."));
    revision.has_side_effects = true;

    const run = b.addSystemCommand(&.{"bash"});
    run.setName("Build vendored jemalloc");
    run.addFileArg(b.path("tools/build-jemalloc.sh"));
    run.addDirectoryArg2(b.path("3rd/jemalloc"), .{ .make_absolute = true });
    run.addFileContentArg2(revision.captureStdOut(.{ .trim_whitespace = .trailing }), .{});
    return run.addOutputDirectoryArg2("jemalloc", .{ .make_absolute = true });
}

fn addPlugin(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    install_dir: []const u8,
    name: []const u8,
    source_dir: []const u8,
    sources: []const []const u8,
    include_dirs: []const []const u8,
) *std.Build.Module {
    const module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    module.addIncludePath(b.path("3rd/lua"));
    module.addIncludePath(b.path("skynet-src"));
    for (include_dirs) |dir| module.addIncludePath(b.path(dir));
    module.addCSourceFiles(.{ .root = b.path(source_dir), .files = sources, .flags = &c_flags });

    const lib = b.addLibrary(.{ .name = name, .linkage = .dynamic, .root_module = module });
    lib.linker_allow_shlib_undefined = true;
    const install = b.addInstallArtifact(lib, .{
        .dest_dir = .{ .override = .{ .custom = install_dir } },
        .dest_sub_path = b.fmt("{s}.so", .{name}),
    });
    b.getInstallStep().dependOn(&install.step);
    return module;
}
