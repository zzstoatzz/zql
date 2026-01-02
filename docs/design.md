# zql design notes

## current state

zql provides comptime utilities for SQL:

1. **parse** - extract column names and param names from SQL strings
2. **bind** - convert named struct args to positional tuple
3. **fromRow** - map row data to typed struct with validation

```zig
const Q = zql.Query("SELECT id, name FROM users WHERE id = :id");

// bind: struct -> tuple in param order
c.query(Q.positional, Q.bind(.{ .id = user_id }));

// fromRow: row -> typed struct
const user = Q.fromRow(User, row);
```

## what comptime enables

based on research (see comptime.md), zig's comptime can:

- parse and validate strings at compile time
- generate types from data
- create perfect hash functions for O(1) lookups
- build complex data structures via type functions

## potential directions

### 1. table definitions (orm-lite)

define schema once, generate queries:

```zig
const User = zql.Table("users", struct {
    id: i64,
    name: []const u8,
    email: []const u8,
});

// generates: INSERT INTO users (id, name, email) VALUES (?, ?, ?)
User.insert(.{ .id = 1, .name = "alice", .email = "a@b.com" });

// generates: SELECT id, name, email FROM users WHERE id = ?
User.select().where(.{ .id = 1 });

// generates: UPDATE users SET name = ? WHERE id = ?
User.update(.{ .name = "bob" }).where(.{ .id = 1 });
```

pros:
- single source of truth for schema
- no manual SQL writing for CRUD
- compile-time validation

cons:
- scope creep into ORM territory
- complex queries still need raw SQL
- migration story unclear

### 2. query composition (options struct pattern)

zig idiom: use options structs, not fluent builders.

```zig
// NOT idiomatic zig:
zql.Select("id").from("users").where("x = :x")

// idiomatic zig - options struct:
const Q = zql.Query(.{
    .select = "d.uri, d.did, d.title, d.created_at",
    .from = "documents d",
    .joins = &.{
        "LEFT JOIN publications p ON d.publication_uri = p.uri",
    },
    .where = "d.uri = :uri",
    .order_by = "d.created_at DESC",
    .limit = 40,
});
```

for variants, use comptime conditionals:

```zig
fn DocQuery(comptime opts: struct {
    fts: bool = false,
    tag: bool = false,
}) type {
    return zql.Query(.{
        .select = if (opts.fts) fts_columns else basic_columns,
        .from = if (opts.fts) "documents_fts f" else "documents d",
        .joins = buildJoins(opts),
        .where = buildWhere(opts),
        .order_by = if (opts.fts) "rank" else "d.created_at DESC",
    });
}

// usage:
const DocsByFts = DocQuery(.{ .fts = true });
const DocsByTag = DocQuery(.{ .tag = true });
const DocsByFtsAndTag = DocQuery(.{ .fts = true, .tag = true });
```

pros:
- follows zig idioms (options struct pattern)
- explicit, readable
- comptime conditional logic is clear
- type-returning function pattern from std

cons:
- more verbose than current raw SQL strings
- query structure must fit the options model

### 3. schema validation

define schema, validate queries reference real columns:

```zig
const schema = zql.Schema{
    .tables = .{
        .users = .{ .id = .int, .name = .text, .email = .text },
        .posts = .{ .id = .int, .user_id = .int, .title = .text },
    },
};

// compile error if 'users' table doesn't have 'name' column
const Q = schema.Query("SELECT name FROM users");
```

pros:
- catches typos at compile time
- documents schema in code

cons:
- schema must be maintained in zig (duplication from DB)
- no runtime schema introspection in zig

### 4. better parsing

current parser is basic. could add:

- sql syntax validation (not just name extraction)
- join detection
- subquery handling
- aggregate function recognition

### 5. perfect hash for columns

use comptime perfect hashing for O(1) column lookups:

```zig
const Q = zql.Query("SELECT id, name, age FROM users");
// Q.columnIndex("name") could use perfect hash instead of linear search
```

probably premature optimization for typical column counts.

## zig idioms (from research)

the zig community prefers:

1. **options structs** over fluent builders
2. **type-returning functions** for generics
3. **explicit code** over clever patterns
4. **comptime validation** via @compileError

from the zig zen:
- "favor reading code over writing code"
- "only one obvious way to do things"
- "communicate intent precisely"

## recommendation

**keep the current simple approach.** three explicit Query constants is more readable than a factory function with options.

```zig
// current - explicit, clear
const DocsByTag = zql.Query("SELECT ... WHERE tag = :tag ...");
const DocsByFts = zql.Query("SELECT ... WHERE MATCH :query ...");
const DocsByFtsAndTag = zql.Query("SELECT ... WHERE MATCH :query AND tag = :tag ...");
```

this follows zig's preference for explicit over clever. the "duplication" is actually meaningful - these queries have different semantics.

if we do add composition, use the **type-returning function pattern**:

```zig
fn DocQuery(comptime opts: struct { fts: bool = false, tag: bool = false }) type {
    // comptime conditionals to build SQL
    return zql.Query(sql);
}
```

but only if the duplication becomes a real maintenance burden.

## open questions

1. how to handle dynamic WHERE clauses? (optional filters)
2. how to compose queries that return different column sets?
3. should zql own the execution layer or just generate SQL?
4. how to handle database-specific SQL dialects?
