const std = @import("std");
const math = std.math;
const meta = std.meta;
const assert = std.debug.assert;
const testing = std.testing;

/// Minimize space used for the type provided as much as possible
/// Returns a type with some functions and decls:
/// - const `Possibilities`
///     `comptime_int` of all of the possible states of the data
/// - const `PackedType`
///     the backing integer for the packed data
/// - fn `pack`(`unpacked_data`: `T`) `PackedType`
///     converts the unpacked `T` into the packed `PackedType`
/// - fn `unpack`(`packed_data`: `PackedType`) `T`
///     converts the packed `PackedType` into the unpacked `T`
pub fn ExtraPacked(comptime T: type) type {
    const info = @typeInfo(T);
    return switch (info) {
        .Int => ExtraPackedInt(T),
        .Optional => ExtraPackedOptional(T),
        .Enum => ExtraPackedEnum(T),
        .Struct => ExtraPackedStruct(T),
        .Void => ExtraPackedVoid,
        .Bool => ExtraPackedBool,
        .Union => ExtraPackedUnion(T),
        .Array => ExtraPackedArray(T),
        else => @compileError("type " ++ @typeName(T) ++ " unsupported for ExtraPacked"),
    };
}
pub fn ExtraPackedInt(comptime T: type) type {
    // an int cannot be optimized without further information about its contents
    const bits = switch (@typeInfo(T)) {
        .Float => |info| info.bits,
        .Int => |info| info.bits,
        else => @compileError("This is supposed to be an int or a float"),
    };
    return struct {
        pub const Possibilities = @as(comptime_int, math.powi(usize, 2, bits) catch unreachable);
        pub const PackedType = meta.Int(.unsigned, bits);
        pub fn pack(unpacked_data: T) PackedType {
            return @bitCast(PackedType, unpacked_data);
        }
        pub fn unpack(packed_data: PackedType) T {
            return @bitCast(T, packed_data);
        }
    };
}
pub fn ExtraPackedEnum(comptime T: type) type {
    const info = @typeInfo(T).Enum;
    return if (info.is_exhaustive) struct {
        pub const Possibilities = @as(comptime_int, info.fields.len);
        pub const PackedType = math.IntFittingRange(0, info.fields.len - 1);
        pub fn pack(unpacked_data: T) PackedType {
            const as_int = @enumToInt(unpacked_data);
            inline for (info.fields) |field, i| if (field.value == as_int) return i;
            unreachable;
        }
        pub fn unpack(packed_data: PackedType) T {
            inline for (info.fields) |field, i| if (packed_data == i) return @field(T, field.name);
            unreachable;
        }
    } else struct {
        // if it is not exhaustive, then we cant optimize this further
        pub const Backing = ExtraPackedInt(info.tag_type);
        pub const Possibilities = Backing.Possibilities;
        pub const PackedType = Backing.PackedType;
        pub fn pack(unpacked_data: T) PackedType {
            return Backing.pack(@enumToInt(unpacked_data));
        }
        pub fn unpack(packed_data: PackedType) T {
            return @intToEnum(T, Backing.unpack(packed_data));
        }
    };
}
pub fn ExtraPackedOptional(comptime T: type) type {
    const info = @typeInfo(T).Optional;
    return struct {
        pub const Child = ExtraPacked(info.child);
        pub const Possibilities = Child.Possibilities + 1;
        pub const PackedType = math.IntFittingRange(0, Possibilities - 1);
        pub fn pack(unpacked_data: T) PackedType {
            if (unpacked_data) |inner| {
                return Child.pack(inner) + 1;
            } else {
                return 0;
            }
        }
        pub fn unpack(packed_data: PackedType) T {
            if (packed_data == 0) {
                return null;
            } else {
                return Child.unpack(@intCast(Child.PackedType, packed_data - 1));
            }
        }
    };
}
pub fn ExtraPackedStruct(comptime T: type) type {
    const info = @typeInfo(T).Struct;
    comptime var specs = [_]type{undefined} ** info.fields.len;
    inline for (specs) |*spec, i| spec.* = ExtraPacked(info.fields[i].field_type);
    comptime var p = 1;
    inline for (specs) |spec| p *= spec.Possibilities;
    return struct {
        pub const Specs = specs;
        pub const Possibilities = p;
        pub const PackedType = math.IntFittingRange(0, Possibilities - 1);
        pub fn pack(unpacked_data: T) PackedType {
            var current_p: PackedType = 0;
            comptime var i = Specs.len;
            inline while (i > 0) {
                i -= 1;
                current_p *= Specs[i].Possibilities;
                current_p += Specs[i].pack(@field(unpacked_data, info.fields[i].name));
            }
            return current_p;
        }
        pub fn unpack(packed_data: PackedType) T {
            var result: T = undefined;
            var current_p = packed_data;
            inline for (Specs) |spec, i| {
                @field(result, info.fields[i].name) = spec.unpack(
                    @intCast(spec.PackedType, current_p % spec.Possibilities),
                );
                current_p /= spec.Possibilities;
            }
            return result;
        }

        pub const FieldEnum = meta.FieldEnum(T);
        pub fn getField(
            comptime field_name: FieldEnum,
            packed_data: PackedType,
        ) info.fields[@enumToInt(field_name)].field_type {
            const field_ind = @enumToInt(field_name);
            comptime var skip_p = 1;
            comptime var i = 0;
            inline while (i < field_ind) : (i += 1) {
                skip_p *= Specs[i].Possibilities;
            }
            const spec = Specs[field_ind];
            return spec.unpack(@intCast(
                spec.PackedType,
                (packed_data / skip_p) % spec.Possibilities,
            ));
        }
        pub fn setField(
            comptime field_name: FieldEnum,
            packed_data: *PackedType,
            unpacked_field: info.fields[@enumToInt(field_name)].field_type,
        ) void {
            const field_ind = @enumToInt(field_name);
            comptime var skip_p = 1;
            comptime var i = 0;
            inline while (i < field_ind) : (i += 1) {
                skip_p *= Specs[i].Possibilities;
            }
            const spec = Specs[field_ind];
            const existing_data = packed_data.* % skip_p;
            packed_data.* = ((packed_data.* / (skip_p * spec.Possibilities)) * spec.Possibilities +
                @intCast(PackedType, spec.pack(unpacked_field))) * skip_p + existing_data;
        }
    };
}
pub const ExtraPackedVoid = struct {
    pub const Possibilities = 1;
    pub const PackedType = u0;
    pub fn pack(unpacked_data: void) PackedType {
        _ = unpacked_data;
        return 0;
    }
    pub fn unpack(packed_data: PackedType) void {
        _ = packed_data;
        return {};
    }
};
pub const ExtraPackedBool = struct {
    pub const Possibilities = 2;
    pub const PackedType = u1;
    pub fn pack(unpacked_data: bool) PackedType {
        return @boolToInt(unpacked_data);
    }
    pub fn unpack(packed_data: PackedType) bool {
        return packed_data != 0;
    }
};
pub fn ExtraPackedArray(comptime T: type) type {
    const info = @typeInfo(T).Array;
    const spec = ExtraPacked(info.child);
    comptime var p = 1;
    {
        comptime var i = 0;
        inline while (i < info.len) : (i += 1) p *= spec.Possibilities;
    }
    return struct {
        pub const Spec = spec;
        pub const Possibilities = p;
        pub const PackedType = math.IntFittingRange(0, Possibilities - 1);
        pub fn pack(unpacked_data: T) PackedType {
            var current_p: PackedType = 0;
            var i: usize = unpacked_data.len;
            while (i > 0) {
                i -= 1;
                current_p *= Spec.Possibilities;
                current_p += Spec.pack(unpacked_data[i]);
            }
            return current_p;
        }
        pub fn unpack(packed_data: PackedType) T {
            var result: T = undefined;
            var current_p = packed_data;
            inline for (result) |*elem| {
                elem.* = Spec.unpack(@intCast(spec.PackedType, current_p % spec.Possibilities));
                current_p /= Spec.Possibilities;
            }
            return result;
        }
    };
}
/// Provided union must be tagged
pub fn ExtraPackedUnion(comptime T: type) type {
    const info = @typeInfo(T).Union;
    comptime var specs = [_]type{undefined} ** info.fields.len;
    inline for (specs) |*spec, i| spec.* = ExtraPacked(info.fields[i].field_type);
    comptime var cumulative_p = [_]comptime_int{undefined} ** info.fields.len;
    inline for (cumulative_p) |*val, i| {
        const last = if (i == 0) 0 else cumulative_p[i - 1];
        val.* = last + specs[i].Possibilities;
    }
    return struct {
        pub const Tag = info.tag_type.?;
        pub const Specs = specs;
        pub const CumulativePossibilities = cumulative_p;
        pub const Possibilities = cumulative_p[cumulative_p.len - 1];
        pub const PackedType = math.IntFittingRange(0, Possibilities - 1);
        pub fn pack(unpacked_data: T) PackedType {
            const tag = @as(Tag, unpacked_data);
            inline for (Specs) |spec, i| {
                if (@field(Tag, info.fields[i].name) == tag) {
                    const from = if (i == 0) 0 else CumulativePossibilities[i - 1];
                    return from + @as(PackedType, spec.pack(@field(unpacked_data, info.fields[i].name)));
                }
            }
            unreachable;
        }
        pub fn unpack(packed_data: PackedType) T {
            inline for (Specs) |spec, i| {
                if (packed_data < CumulativePossibilities[i]) {
                    const last = if (i == 0) 0 else CumulativePossibilities[i - 1];
                    return @unionInit(
                        T,
                        info.fields[i].name,
                        spec.unpack(@intCast(
                            spec.PackedType,
                            (packed_data - last) % spec.Possibilities,
                        )),
                    );
                }
            }
            unreachable;
        }
        pub const FieldEnum = meta.FieldEnum(T);
        pub fn getField(
            comptime field_name: FieldEnum,
            packed_data: PackedType,
        ) info.fields[@enumToInt(field_name)].field_type {
            const field_ind = @enumToInt(field_name);
            const from = if (field_ind == 0) 0 else CumulativePossibilities[field_ind - 1];
            const to = CumulativePossibilities[field_ind];
            assert(packed_data >= from and packed_data < to);
            const spec = Specs[field_ind];
            return spec.unpack(@intCast(
                spec.PackedType,
                (packed_data - from) % spec.Possibilities,
            ));
        }
    };
}

test "enum" {
    const T = ExtraPacked(enum(u8) {
        a = 0,
        b = 1,
        c = 5,
        d = 10,
        e = 11,
    });
    {
        const p = T.pack(.c);
        try testing.expect(p == 2);
        const r = T.unpack(p);
        try testing.expect(r == .c);
    }
}
test "optional" {
    const T = ExtraPacked(?u7);
    try testing.expect(@sizeOf(T.PackedType) == 1);
    {
        const p = T.pack(5);
        try testing.expect(p == 6);
        const r = T.unpack(p);
        try testing.expect(r.? == 5);
    }
    {
        const p = T.pack(null);
        try testing.expect(p == 0);
        const r = T.unpack(p);
        try testing.expect(r == null);
    }
    const Enum = enum(u4) {
        a = 2,
        b = 3,
    };
    const E = ExtraPacked(?Enum);
    try testing.expect(@sizeOf(E.PackedType) == 1);
    {
        const p = E.pack(Enum.a);
        try testing.expect(p == 1);
        const r = E.unpack(p);
        try testing.expect(r.? == Enum.a);
    }
    {
        const p = E.pack(null);
        try testing.expect(p == 0);
        const r = E.unpack(p);
        try testing.expect(r == null);
    }
}
test "struct" {
    const Unpacked = struct {
        a: i3,
        b: enum(u2) { a, b, c, d },
        c: ?u2,
    };
    const T = ExtraPacked(Unpacked);
    try testing.expect(@sizeOf(T.PackedType) == 1);
    {
        const expected = Unpacked{
            .a = -2,
            .b = .d,
            .c = 1,
        };
        const p = T.pack(expected);
        const expected_packed = (((0 * 5) + 1 + 1) * 4 + 3) * 8 + @as(T.PackedType, @bitCast(u3, @as(i3, -2)));
        try testing.expectEqual(p, expected_packed);
        const r = T.unpack(p);
        try testing.expect(meta.eql(expected, r));
    }
    {
        const expected = Unpacked{
            .a = -2,
            .b = .d,
            .c = 1,
        };
        const new_expected = Unpacked{
            .a = -2,
            .b = .c,
            .c = 1,
        };
        var p = T.pack(expected);
        T.setField(.b, &p, .c);
        try testing.expectEqual(T.getField(.c, p), 1);
        const r = T.unpack(p);
        try testing.expect(meta.eql(r, new_expected));
    }
}
test "union" {
    const Unpacked = union(enum) {
        a: ?u3,
        b: enum { a, b, c, d, e },
        c: bool,
    };
    const T = ExtraPacked(Unpacked);
    try testing.expectEqual(16, T.Possibilities);
    try testing.expect(T.PackedType == u4);
    inline for ([_]Unpacked{
        .{ .a = null },
        .{ .a = 4 },
        .{ .b = .a },
        .{ .b = .e },
        .{ .c = false },
        .{ .c = true },
    }) |expected| {
        const p = T.pack(expected);
        const r = T.unpack(p);
        try testing.expect(meta.eql(expected, r));
    }
    {
        const expected = Unpacked{ .b = .c };
        const p = T.pack(expected);
        try testing.expectEqual(T.getField(.b, p), expected.b);
    }
}
