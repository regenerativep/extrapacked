const std = @import("std");
const math = std.math;
const assert = std.debug.assert;
const testing = std.testing;

pub fn ExtraPacked(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .Int => Int(T),
        .Enum => Enum(T),
        .Optional => Optional(T),
        .Struct => Struct(T),
        .Void => Void,
        .Bool => Bool,
        .Array => Array(T),
        .Union => Union(T),
        else => @compileError("Unimplemented extrapacked type " ++ @typeName(T)),
    };
}

pub fn Int(comptime T: type) type {
    return struct {
        pub const bits = switch (@typeInfo(T)) {
            .Float => |d| d.bits,
            .Int => |d| d.bits,
            else => @compileError("Expected int or float, not " ++ @typeName(T)),
        };
        pub const P = 1 << bits;
        pub const UT = @Type(.{ .Int = .{ .signedness = .unsigned, .bits = bits } });

        pub fn pack(value: T) UT {
            return @bitCast(value);
        }
        pub fn unpack(in: UT) T {
            return @bitCast(in);
        }
    };
}

pub fn Enum(comptime T: type) type {
    const info = @typeInfo(T).Enum;
    return if (info.is_exhaustive) struct {
        pub const P = @as(comptime_int, info.fields.len);
        pub const UT = math.IntFittingRange(0, info.fields.len - 1);

        const FieldEnum = std.meta.FieldEnum(T);

        pub fn pack(value: T) UT {
            return @intFromEnum(switch (value) {
                inline else => |v| @field(FieldEnum, @tagName(v)),
            });
        }
        pub fn unpack(in: UT) T {
            return switch (@as(FieldEnum, @enumFromInt(in))) {
                inline else => |v| @field(T, @tagName(v)),
            };
        }
    } else struct { // int backing for non-exhaustive
        pub const Backing = Int(info.tag_type);
        pub const P = Backing.P;
        pub const UT = Backing.UT;

        pub fn pack(value: T) UT {
            return Backing.pack(@intFromEnum(value));
        }
        pub fn unpack(in: UT) T {
            return @enumFromInt(Backing.unpack(in));
        }
    };
}

pub fn Optional(comptime T: type) type {
    const info = @typeInfo(T).Optional;
    return struct {
        pub const Child = ExtraPacked(info.child);
        pub const P = Child.P + 1;
        pub const UT = math.IntFittingRange(0, P - 1);

        pub fn pack(value: T) UT {
            return if (value) |inner| @as(UT, Child.pack(inner)) + 1 else 0;
        }
        pub fn unpack(in: UT) T {
            return if (in == 0) null else Child.unpack(@intCast(in - 1));
        }
    };
}

pub fn Struct(comptime T: type) type {
    const info = @typeInfo(T).Struct;
    return struct {
        pub const P = blk: {
            var p = 1;
            for (info.fields) |field| p *= ExtraPacked(field.type).P;
            break :blk p;
        };
        pub const UT = math.IntFittingRange(0, P - 1);

        pub fn pack(value: T) UT {
            var out: UT = 0;
            comptime var i = info.fields.len;
            inline while (i > 0) {
                i -= 1;
                const field = info.fields[i];
                const S = ExtraPacked(field.type);
                out *= S.P;
                out += S.pack(@field(value, field.name));
            }
            return out;
        }

        pub fn unpack(in_: UT) T {
            var in = in_;
            var result: T = undefined;
            inline for (info.fields) |field| {
                const S = ExtraPacked(field.type);
                @field(result, field.name) = S.unpack(@intCast(in % S.P));
                in /= S.P;
            }
            return result;
        }
    };
}

pub const Void = struct {
    pub const P = 1;
    pub const UT = u0;
    pub fn pack(_: void) UT {
        return 0;
    }
    pub fn unpack(_: UT) void {
        return {};
    }
};

pub const Bool = struct {
    pub const P = 2;
    pub const UT = u1;
    pub fn pack(value: bool) UT {
        return @intFromBool(value);
    }
    pub fn unpack(in: UT) bool {
        return in != 0;
    }
};

pub fn Array(comptime T: type) type {
    const info = @typeInfo(T).Array;
    return struct {
        pub const Child = ExtraPacked(info.child);
        pub const P = blk: {
            var p = 1;
            for (0..info.len) |_| p *= Child.P;
            break :blk p;
        };
        pub const UT = math.IntFittingRange(0, P - 1);
        pub fn pack(value: T) UT {
            var out: UT = 0;
            var i = value.len;
            while (i > 0) {
                i -= 1;
                out *= Child.P;
                out += Child.pack(value[i]);
            }
            return out;
        }
        pub fn unpack(in_: UT) T {
            var result: T = undefined;
            var in = in_;
            for (&result) |*v| {
                v.* = Child.unpack(@intCast(in % Child.P));
                in /= Child.P;
            }
            return result;
        }
    };
}

pub fn Union(comptime T: type) type {
    const info = @typeInfo(T).Union;
    return struct {
        pub const P = blk: {
            var p = 0;
            for (info.fields) |field| p += ExtraPacked(field.type).P;
            break :blk p;
        };
        pub const UT = math.IntFittingRange(0, P - 1);

        const cumulative = blk: {
            var c: [info.fields.len - 1]UT = undefined;
            c[0] = ExtraPacked(info.fields[0].type).P;
            for (1..c.len) |i| c[i] = c[i - 1] + ExtraPacked(info.fields[i].type).P;
            break :blk c;
        };
        const FieldEnum = std.meta.FieldEnum(T);

        pub fn pack(value: T) UT {
            switch (value) {
                inline else => |d, v| {
                    const i = @intFromEnum(@field(FieldEnum, @tagName(v)));
                    return (if (i == 0) 0 else cumulative[i - 1]) + ExtraPacked(info.fields[i].type).pack(d);
                },
            }
        }
        pub fn unpack(in: UT) T {
            inline for (info.fields, 0..) |field, i| {
                if (i == cumulative.len or in < cumulative[i])
                    return @unionInit(T, field.name, ExtraPacked(field.type).unpack(
                        @intCast(in - if (i == 0) 0 else cumulative[i - 1]),
                    ));
            }
            unreachable;
        }
    };
}

pub fn doTest(comptime T: type, value: T, in: ExtraPacked(T).UT) !void {
    const S = ExtraPacked(T);
    try testing.expectEqualDeep(in, S.pack(value));
    try testing.expectEqualDeep(value, S.unpack(in));
    try testing.expectEqualDeep(in, S.pack(S.unpack(in)));
    try testing.expectEqualDeep(value, S.unpack(S.pack(value)));
}

test "enum" {
    const T = enum(u8) {
        a = 0,
        b = 1,
        c = 5,
        d = 10,
        e = 11,
    };
    try doTest(T, .a, 0);
    try doTest(T, .c, 2);
    try doTest(T, .e, 4);
}

test "optional" {
    const T1 = ?u7;
    const S1 = ExtraPacked(T1);
    try testing.expectEqual(1, @sizeOf(S1.UT));
    try doTest(T1, 5, 6);
    try doTest(T1, null, 0);

    const T2 = ?enum(u4) { a = 2, b = 3 };
    const S2 = ExtraPacked(T2);
    try testing.expectEqual(1, @sizeOf(S2.UT));
    try doTest(T2, .a, 1);
    try doTest(T2, .b, 2);
    try doTest(T2, null, 0);
}

test "struct" {
    const T = struct { a: i3, b: enum(u2) { a, b, c, d }, c: ?u2 };
    const S = ExtraPacked(T);
    try testing.expectEqual(1, @sizeOf(S.UT));
    try doTest(
        T,
        .{ .a = -2, .b = .d, .c = 1 },
        @as(S.UT, (2 * 4 + 3) * 8) + @as(u3, @bitCast(@as(i3, -2))),
    );
}

test "union" {
    const T = union(enum) {
        a: ?u3,
        b: enum { a, b, c, d, e },
        c: bool,
    };
    const S = ExtraPacked(T);
    try testing.expectEqual(16, S.P);
    try testing.expectEqual(u4, S.UT);
    inline for (.{
        .{ .{ .a = null }, 0 },
        .{ .{ .a = 4 }, 5 },
        .{ .{ .b = .a }, 9 },
        .{ .{ .b = .e }, 13 },
        .{ .{ .c = false }, 14 },
        .{ .{ .c = true }, 15 },
    }) |pair| {
        try doTest(T, pair[0], pair[1]);
    }
}
