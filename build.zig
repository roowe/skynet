const std = @import("std");

// Match the Make build for the C sources even in Zig's debug mode.
const c_flags = [_][]const u8{ "-g", "-O2", "-Wall" };
const lua_flags = c_flags ++ [_][]const u8{ "-std=gnu99", "-Wextra", "-DLUA_USE_MACOSX" };
const skynet_flags = c_flags ++ [_][]const u8{"-DNOUSE_JEMALLOC"};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const smoke = b.step("smoke", "Verify Lua startup, plugin loading, messaging, and timers");
    if (target.result.os.tag != .macos or target.result.cpu.arch != .aarch64) {
        const unsupported = b.addFail("this Zig build supports aarch64-macos only");
        b.getInstallStep().dependOn(&unsupported.step);
        smoke.dependOn(&unsupported.step);
        return;
    }

    const lua = b.addLibrary(.{
        .name = "skynet-lua",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    lua.root_module.addIncludePath(b.path("skynet-src"));
    lua.root_module.addCSourceFiles(.{
        .root = b.path("3rd/lua"),
        .flags = &lua_flags,
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
        cli.root_module.linkSystemLibrary("readline", .{});
        cli.root_module.addIncludePath(b.path("skynet-src"));
        cli.root_module.addCSourceFile(.{ .file = b.path(b.fmt("3rd/lua/{s}.c", .{name})), .flags = &lua_flags });
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
    skynet.root_module.addCSourceFiles(.{
        .root = b.path("skynet-src"),
        .flags = &skynet_flags,
        .files = &.{
            "skynet_main.c",   "skynet_handle.c", "skynet_module.c",  "skynet_mq.c",
            "skynet_server.c", "skynet_start.c",  "skynet_timer.c",   "skynet_error.c",
            "skynet_harbor.c", "skynet_env.c",    "skynet_monitor.c", "skynet_socket.c",
            "socket_server.c", "mem_info.c",      "malloc_hook.c",    "skynet_daemon.c",
            "skynet_log.c",
        },
    });
    b.installArtifact(skynet);

    for ([_][]const u8{ "snlua", "logger", "gate", "harbor" }) |name| {
        addPlugin(b, target, optimize, "cservice", name, "service-src", &.{b.fmt("service_{s}.c", .{name})}, &.{});
    }
    addPlugin(b, target, optimize, "luaclib", "skynet", "lualib-src", &.{
        "lua-skynet.c",    "lua-seri.c",      "lua-socket.c",       "lua-mongo.c",     "lua-netpack.c",
        "lua-memory.c",    "lua-multicast.c", "lua-cluster.c",      "lua-crypt.c",     "lsha1.c",
        "lua-sharedata.c", "lua-stm.c",       "lua-debugchannel.c", "lua-datasheet.c", "lua-sharetable.c",
    }, &.{"service-src"});
    addPlugin(b, target, optimize, "luaclib", "client", "lualib-src", &.{
        "lua-clientsocket.c", "lua-crypt.c", "lsha1.c",
    }, &.{});
    addPlugin(b, target, optimize, "luaclib", "bson", "lualib-src", &.{"lua-bson.c"}, &.{});
    addPlugin(b, target, optimize, "luaclib", "sproto", "lualib-src/sproto", &.{ "sproto.c", "lsproto.c" }, &.{});
    addPlugin(b, target, optimize, "luaclib", "md5", "3rd/lua-md5", &.{ "md5.c", "md5lib.c", "compat-5.2.c" }, &.{});
    addPlugin(b, target, optimize, "luaclib", "lpeg", "3rd/lpeg", &.{
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
) void {
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
}
