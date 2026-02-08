const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zpoweralertd",
        .root_module = exe_mod,
    });

    const exe_options = b.addOptions();

    const opt_version_string = b.option([]const u8, "version-string", "Override version string");
    const v = if (opt_version_string) |version| version else "0.0.0";
    exe_options.addOption([]const u8, "version", v);

    exe.linkLibC();

    const dbusLib = detectLib(b.allocator, exe);
    exe_options.addOption(i32, "dbuslib", dbusLib);

    exe.root_module.addOptions("build_options", exe_options);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}

fn detectLib(allocator: std.mem.Allocator, exe: *std.Build.Step.Compile) i32 {
    if (tryPkgConfig(allocator, exe, "basu")) return 0;
    if (tryPkgConfig(allocator, exe, "libelogind")) return 1;
    if (tryPkgConfig(allocator, exe, "libsystemd")) return 2;

    std.debug.panic("No supported system library found (basu, elogind, systemd)", .{});
}

fn tryPkgConfig(allocator: std.mem.Allocator, exe: *std.Build.Step.Compile, libname: []const u8) bool {
    const output = runPkgConfig(allocator, &.{ "pkg-config", "--cflags", "--libs", libname }) orelse return false;

    // Add -L library paths from pkg-config output. Include paths (-I)
    // are intentionally NOT added here to avoid conflicts with Zig's
    // internal pkg-config integration which seems to add them as -I. 
    // Manually adding the same paths seem to cause a build error.
    var it = std.mem.tokenizeScalar(u8, std.mem.trim(u8, output, " \n\t\r"), ' ');
    while (it.next()) |flag| {
        if (flag.len < 3) continue;
        if (std.mem.startsWith(u8, flag, "-L")) {
            exe.addLibraryPath(.{ .cwd_relative = flag[2..] });
        }
    }

    // Also add explicit libdir for musl-based systems where Zig has no
    // default library search paths and pkg-config omits -L for paths it
    // considers default (e.g. /usr/lib).
    if (runPkgConfig(allocator, &.{ "pkg-config", "--variable=libdir", libname })) |dir| {
        const trimmed = std.mem.trim(u8, dir, " \n\t\r");
        if (trimmed.len > 0) exe.addLibraryPath(.{ .cwd_relative = trimmed });
    }

    // Link using the pkg-config module name. Zig's linkSystemLibrary
    // appears to handle include paths...?
    exe.linkSystemLibrary(libname);
    return true;
}

fn runPkgConfig(allocator: std.mem.Allocator, args: []const []const u8) ?[]const u8 {
    var child = std.process.Child.init(args, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return null;

    const stdout = child.stdout orelse {
        _ = child.wait() catch {};
        return null;
    };

    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = stdout.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }

    const result = child.wait() catch return null;
    if (result == .Exited and result.Exited == 0) {
        return allocator.dupe(u8, buf[0..total]) catch return null;
    }
    return null;
}
