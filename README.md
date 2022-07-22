# ExtraPacked

ever look at a `?u7` and think, "hey why cant this just be a u8 and not take up 2 bytes?"

now you can:

```zig
const EPInt = ExtraPacked(?u7);

const my_int: ?u7 = 122;

const packed_my_int = EPInt.pack(my_int);
assert(@TypeOf(packed_my_int) == u8);

const got_back_my_int: ?u7 = EPInt.unpack(packed_my_int);
assert(got_back_my_int.? == 122);
```

we can even do some crazier stuff:

```zig
const MyData = union(enum) {
    a: ?u3,
    b: enum { a, b, c, d, e },
    c: bool,
};
const EPData = ExtraPacked(MyData);

const my_data = MyData{ .a = 7 };
const packed_my_data = EPData.pack(my_data);

assert(@TypeOf(packed_my_data) == u4);

const got_back_my_data: MyData = EPData.unpack(packed_my_data);
assert(meta.eql(my_data, got_back_my_data));

```

this entire tagged union is stored entirely within a `u4`. yes, including the `?u3` field.

how's this work? a given type has a number of possible different states. a `u3` has 8 different possible states. a `?u3` just has one extra state to store a null. `enum { a, b, c, d, e }` has 5 different states. `bool` has 2 different states. therefore, adding up all of the possible states in the tagged union, you get 16, which fits nicely in a `u4`.

you can count the number of possible states with

```zig
assert(EPData.Possibilities == 16);
```

what's the catch? probably more expensive moving between packed and unpacked than just using zig's own `packed` types. this also uses zig's integer type for backing the packed data, so you are also limited by how big zig can make its ints.

