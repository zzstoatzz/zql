# zql

comptime sql bindings for zig.

```zig
const zql = @import("zql");

const User = struct { id: i32, name: []const u8 };

const Q = zql.Query("SELECT id, name FROM users WHERE id = :id");

// Q.positional = "SELECT id, name FROM users WHERE id = ?"
// Q.columns = .{ "id", "name" }
// Q.params = .{ "id" }

pub fn getUser(db: anytype, user_id: i32) ?User {
    const row = db.query(Q.positional, Q.bind(.{ .id = user_id })) orelse return null;
    return Q.fromRow(row, User);
}
```

The injection style.
```zig
const SomeDbRow = struct {
    // ... fields
    const as = Q.fromRow;
};

const UserParam = struct {
    id: i32,

    const asParam = Q.bind;

    fn getUser(self: @This(), db: anytype) ?User {
        const row: SomeDbRow = db.query(Q.positional, self.asParam()) orelse return null;
        return row.as(User);
    }
};
```

## what it does

| | |
|-|-|
| `Q.positional` | `:name` → `?` |
| `Q.bind(.{...})` | struct → tuple in param order |
| `Q.columns` | column names from SELECT |
| `Q.fromRow(row, T)` | row → struct |

## install

```sh
zig fetch --save https://tangled.org/zzstoatzz.io/zql/archive/v0.1.0-alpha.0.tar.gz
```

```zig
// build.zig
exe.root_module.addImport("zql", b.dependency("zql", .{}).module("zql"));
```
