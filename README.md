# ExtraPacked

Ever look at a `?u7` and think, "Hey, why can't this be stored in a single byte instead
    of 2?"

With this library, you can:

```zig
const S = ExtraPacked(?u7);

const my_int: ?u7 = 122;

const packed_my_int = S.pack(my_int);
assert(@sizeOf(@TypeOf(packed_my_int)) == 1);

const got_back_my_int = S.unpack(packed_my_int);
assert(got_back_my_int != null and got_back_my_int.? == 122);
```

You can even pack some fancier types, such as this tagged union that is stored entirely
    within a `u4`:

```zig
const T = union(enum) {
    a: ?u3,
    b: enum { a, b, c, d, e },
    c: bool,
};
const S = ExtraPacked(T);

const my_data = T{ .a = 7 };

const packed_my_data = S.pack(my_data);
assert(@TypeOf(packed_my_data) == u4);

const got_back_my_data = S.unpack(packed_my_data);
assert(meta.eql(my_data, got_back_my_data));

```

