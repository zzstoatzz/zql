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

### 2. query composition

build queries from reusable fragments:

```zig
const base = zql.Select("d.uri, d.title, d.created_at")
    .from("documents d");

const withFts = base
    .join("documents_fts f ON d.uri = f.uri")
    .where("documents_fts MATCH :query");

const withTag = base
    .join("document_tags dt ON d.uri = dt.document_uri")
    .where("dt.tag = :tag");

const withBoth = withFts.and(withTag);
```

pros:
- reduces duplication (DocsByTag, DocsByFts, DocsByFtsAndTag -> composable)
- still explicit SQL, just structured

cons:
- complex API
- might not cover all SQL patterns

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

## recommendation

start with **query composition** (#2). it:

- solves a real pain point (duplicated query variants in leaflet-search)
- stays close to SQL (no abstraction leap)
- is incrementally adoptable
- doesn't require schema definition

table definitions (#1) are valuable but bigger scope. schema validation (#3) requires maintaining schema twice.

## open questions

1. how to handle dynamic WHERE clauses? (optional filters)
2. how to compose queries that return different column sets?
3. should zql own the execution layer or just generate SQL?
4. how to handle database-specific SQL dialects?
