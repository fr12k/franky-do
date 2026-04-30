//! franky-do build — single executable depending on `franky` (sibling
//! path) and `websocket.zig` (URL-pinned). The franky module is
//! imported as `franky`, the websocket library as `websocket`.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // macOS LLD doesn't link Mach-O in Zig 0.17 — same flag dance as
    // franky's build.zig so the two projects share the same defaults.
    const use_llvm = b.option(bool, "use-llvm", "Use the LLVM backend (default: target-dependent)");
    const use_lld_opt = b.option(bool, "use-lld", "Use LLD for linking (default: false on macOS, target-dependent elsewhere)");
    const use_lld: ?bool = if (target.result.os.tag == .macos and use_lld_opt == null)
        false
    else
        use_lld_opt;

    // ── Dependencies ──
    const franky_dep = b.dependency("franky", .{
        .target = target,
        .optimize = optimize,
    });
    const ws_dep = b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    });

    // ── Executable module ──
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addImport("franky", franky_dep.module("franky"));
    exe_module.addImport("websocket", ws_dep.module("websocket"));

    const exe = b.addExecutable(.{
        .name = "franky-do",
        .root_module = exe_module,
        .use_llvm = use_llvm,
        .use_lld = use_lld,
    });
    b.installArtifact(exe);

    // ── `zig build run -- <args>` ──
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run franky-do");
    run_step.dependOn(&run_cmd.step);

    // ── `zig build test` ──
    const exe_tests = b.addTest(.{
        .root_module = exe_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);
}
