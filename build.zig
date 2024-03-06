const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("extrapacked", .{
        .root_source_file = .{ .path = "src/extrapacked.zig" },
    });
}
