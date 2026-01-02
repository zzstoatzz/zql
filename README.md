# zql

comptime sql bindings for zig.

```zig
const Q = zql.Query("SELECT id, name FROM users WHERE id = :id");

// named params -> prepared statement
db.query(Q.positional, Q.bind(.{ .id = user_id }));

// type-safe row mapping
const user = Q.fromRow(User, row);
```

## why

sql injection is prevented by construction. the sql string is comptime - you can't concatenate runtime values into it. parameters are bound separately via prepared statements.

```zig
// this doesn't compile - user_input isn't comptime
const Q = zql.Query("SELECT * FROM users WHERE id = '" ++ user_input ++ "'");
```

## features

| feature | what it does |
|---------|--------------|
| `Q.positional` | sql with `:name` converted to `?` |
| `Q.bind(.{...})` | struct args → tuple in param order |
| `Q.columns` | column names extracted from SELECT |
| `Q.fromRow(T, row)` | map row to struct with comptime validation |

## install

```zig
// build.zig.zon
.zql = .{
    .url = "https://github.com/zzstoatzz/zql/archive/main.tar.gz",
    .hash = "...",  // zig build will tell you
},

// build.zig
exe.root_module.addImport("zql", b.dependency("zql", .{}).module("zql"));
```

## status

alpha. api may change.
