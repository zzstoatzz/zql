# zig comptime

internal research on zig's compile-time execution for informing zql's design.

## core mechanisms

### comptime parameters (generics)

functions accept `comptime` parameters that must be known at compile time:

```zig
fn max(comptime T: type, a: T, b: T) T {
    return if (a > b) a else b;
}
```

this implements compile-time duck typing - if `T` doesn't support `>`, error at call site.

### comptime variables

```zig
comptime var y: i32 = 1;
y += 1; // evaluated during compilation
```

### inline loops

`inline for` and `inline while` unroll at compile time:

```zig
inline for (std.meta.fields(T)) |field| {
    @field(value, field.name) = processField(field);
}
```

## type-level programming

types are first-class values at comptime. functions can return types:

```zig
fn ArrayList(comptime T: type) type {
    return struct {
        items: []T,
        len: usize,

        const Self = @This();

        fn append(self: *Self, item: T) !void {
            // ...
        }
    };
}
```

## reflection via @typeInfo

inspect type structure at compile time:

```zig
fn GetBiggerInt(comptime T: type) type {
    const info = @typeInfo(T).Int;
    return @Type(.{
        .Int = .{
            .bits = info.bits + 1,
            .signedness = info.signedness,
        },
    });
}
```

## key builtins

| builtin | purpose |
|---------|---------|
| `@typeInfo(T)` | returns tagged union describing type structure |
| `@Type(info)` | reifies a type from `@typeInfo` output |
| `@TypeOf(expr)` | returns expression's type |
| `@field(obj, name)` | dynamic field access (name must be comptime) |
| `@hasField(T, name)` | checks if type has named field |
| `@hasDecl(T, name)` | checks if type has named declaration |
| `@compileError(msg)` | generates compile error with custom message |

## std.meta utilities

- `std.meta.fields(T)` - returns struct/union/enum field information
- `std.meta.fieldNames(T)` - returns slice of field name strings
- `std.meta.FieldEnum(T)` - generates enum matching struct fields
- `std.meta.hasFn(T, name)` - checks if type has a function declaration
- `std.meta.eql(a, b)` - recursive structural equality
- `std.meta.Tuple(&types)` - creates tuple type from array of types

## limitations

| limitation | reason | workaround |
|------------|--------|------------|
| no I/O | hermetic, reproducible builds | use `build.zig` for external I/O |
| no heap allocation | currently unsupported | proposals exist (#5873, #5881) |
| `@Type` incomplete | not implemented for enums, unions, functions | use simpler type construction |
| no runtime type info | types only exist at comptime | build custom RTTI at comptime |

## gotchas

1. **comptime doesn't cross function boundaries** without explicit marking
2. **`@field` requires comptime-known strings** - can't use runtime strings
3. **comptime pollution** - once something is comptime, everything it uses must be too
4. **branch quota** - loops default to 1000 backward branches, use `@setEvalBranchQuota()`
5. **no declaration-site type checking** - errors appear at call sites, not generic definitions

## patterns relevant to zql

### comptime string parsing

std.fmt parses format strings at comptime, validating types before runtime:

```zig
std.debug.print("Value: {d}, Name: {s}\n", .{ value, name });
// format string parsed at compile time; type mismatches caught during compilation
```

this is what zql does with SQL strings.

### perfect hash generation

andrew kelley demonstrated O(1) string switches via comptime perfect hash search:

```zig
const ph = perfectHash(&.{ "a", "ab", "abc" });
switch (ph.hash(target)) {
    ph.case("a") => handleA(),
    ph.case("ab") => handleAb(),
    else => unreachable,
}
```

could be useful for column name lookups.

### comptime string interning

leverage memoization to deduplicate strings:

```zig
fn internString(comptime str: []const u8) []const u8 {
    return internStringBuffer(str.len, str[0..str.len].*);
}

fn internStringBuffer(comptime len: comptime_int, comptime items: [len]u8) []const u8 {
    comptime var storage: [len]u8 = items;
    return &storage;
}
```

since comptime calls are memoized, identical strings return the same address.

### schema/orm patterns (tigerbeetle)

```zig
fn DBType(comptime schema: Schema) type {
    return struct {
        tables: generateTables(schema),
        indexes: generateIndexes(schema),

        pub fn query(self: *@This(), comptime filter: Filter) Iterator {
            // ...
        }
    };
}
```

this is where zql could go - define schema once, generate queries.

## sources

### official
- [zig language reference - comptime](https://ziglang.org/documentation/master/#comptime)

### andrew kelley
- [string matching based on compile time perfect hashing](https://andrewkelley.me/post/string-matching-comptime-perfect-hashing-zig.html)
- [zig blurs the line between compile-time and run-time](https://andrewkelley.me/post/zig-programming-language-blurs-line-compile-time-run-time.html)

### community
- [what is zig's comptime? - loris cro](https://kristoff.it/blog/what-is-zig-comptime/)
- [comptime zig orm - matklad](https://matklad.github.io/2025/03/19/comptime-zig-orm.html)
- [things zig comptime won't do - matklad](https://matklad.github.io/2025/04/19/things-zig-comptime-wont-do.html)
- [zig metaprogramming - openmymind](https://www.openmymind.net/Basic-MetaProgramming-in-Zig/)

### std library source
- [std/meta.zig](https://github.com/ziglang/zig/blob/master/lib/std/meta.zig)
- [std/fmt.zig](https://github.com/ziglang/zig/blob/master/lib/std/fmt.zig)
