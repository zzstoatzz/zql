# zql

comptime sql bindings for zig.

```zig
const Q = zql.Query("SELECT id, name FROM users WHERE id = :id");

db.query(Q.positional, Q.bind(.{ .id = user_id }));

const user = Q.fromRow(User, row);
```

## what it does

| | |
|-|-|
| `Q.positional` | `:name` → `?` |
| `Q.bind(.{...})` | struct → tuple in param order |
| `Q.columns` | column names from SELECT |
| `Q.fromRow(T, row)` | row → struct |

## install

```zig
// build.zig.zon
.zql = .{
    .url = "https://github.com/zzstoatzz/zql/archive/main.tar.gz",
    .hash = "zql-0.0.1-alpha-xNRI4IRNAABUb9gLat5FWUaZDD5HvxAxet_-elgR_A_y",
},

// build.zig
exe.root_module.addImport("zql", b.dependency("zql", .{}).module("zql"));
```
