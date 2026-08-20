const std = @import("std");

/// Eigenstaendiger Bau aus dem Manifest.
///
/// `zig build` erzeugt das Modul allein aus diesem Verzeichnis, ohne den Rest
/// von R4OS. Die Datei zeigt nur auf module.R4MF - Name, Klasse, Quellen,
/// Ziel, Imports und Metadaten stehen dort und nirgends sonst.
pub fn build(b: *std.Build) void {
    const sdk_build = b.lazyImport(@This(), "r4os_sdk") orelse return;
    const sdk_dep = b.dependencyFromBuildZig(sdk_build, .{});
    const sdk = sdk_build.sdk(b, sdk_dep, .{});
    _ = sdk.addR4MF(b.path("module.R4MF"));

    const pattern_tests_module = b.createModule(.{
        .root_source_file = b.path("src/pattern.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const pattern_tests = b.addTest(.{ .root_module = pattern_tests_module });
    const run_pattern_tests = b.addRunArtifact(pattern_tests);

    const test_step = b.step("test", "Run deterministic PCM pattern tests");
    test_step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_pattern_tests.step);
}
