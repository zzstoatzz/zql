# zql

comptime sql ergonomics for zig.

## features

- **named parameters**: `:name` syntax with comptime validation
- **column extraction**: parse SELECT columns at comptime
- **zero runtime overhead**: all parsing happens at compile time

## usage

```zig
const zql = @import("zql");

// query metadata extracted at comptime
const Q = zql.parse.Query("SELECT id, name, age FROM users WHERE age > :min_age");

// access parsed info
_ = Q.raw;        // original sql
_ = Q.positional; // "SELECT id, name, age FROM users WHERE age > ?"
_ = Q.params;     // ["min_age"]
_ = Q.columns;    // ["id", "name", "age"]

// validate args struct has required params (comptime error if missing)
Q.validateArgs(struct { min_age: i64 });
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

early development. contributions welcome.
