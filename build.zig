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
    var child = std.process.Child.init(&[_][]const u8{
        "pkg-config", "--exists", libname,
    }, allocator);

    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    const result = child.spawnAndWait() catch return false;

    if (result == .Exited and result.Exited == 0) {
        exe.linkSystemLibrary(libname);
        return true;
    }
    return false;
}
