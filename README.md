# zql

comptime sql ergonomics for zig. **alpha** - api may change.

## features

- **named parameters**: `:name` syntax with comptime validation
- **column extraction**: parse SELECT columns at comptime
- **struct mapping**: map rows to structs with comptime validation
- **zero runtime overhead**: all parsing happens at compile time

## usage

```zig
const zql = @import("zql");

const Q = zql.Query("SELECT id, name, age FROM users WHERE age > :min_age");

// access parsed metadata
_ = Q.raw;        // original sql
_ = Q.positional; // "SELECT id, name, age FROM users WHERE age > ?"
_ = Q.params;     // ["min_age"]
_ = Q.columns;    // ["id", "name", "age"]

// comptime validation
Q.validateArgs(struct { min_age: i64 });  // error if param missing
Q.validateStruct(User);                    // error if field not in columns

// struct mapping (with any row type that has .get(idx))
const User = struct { id: i64, name: []const u8 };
const user = Q.fromRow(User, row_data);

// column index lookup
const idx = Q.columnIndex("name");  // 1
```

## install

```zig
// build.zig.zon
.dependencies = .{
    .zql = .{
        .url = "https://github.com/zzstoatzz/zql/archive/main.tar.gz",
    },
},
```

## status

alpha. contributions welcome.
