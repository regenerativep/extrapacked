const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    //const target = b.standardTargetOptions(.{});
    //const optimize = b.standardOptimizeOption(.{});
    _ = b.addModule("extrapacked", .{ .source_file = .{ .path = "src/extrapacked.zig" } });
}
