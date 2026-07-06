const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    inline for (.{
        .{ "silicadbd", "src/silicadbd.zig" },
        .{ "silica", "src/silica.zig" },
    }) |e| {
        const exe = b.addExecutable(.{
            .name = e[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path(e[1]),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        b.installArtifact(exe);
    }
}
