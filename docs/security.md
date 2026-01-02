# security model

zql's design prevents sql injection by construction.

## the pattern

like python's t-strings (PEP 750), zql separates template structure from values:

```zig
// sql is comptime - fixed at compile time
const Q = zql.Query("SELECT * FROM users WHERE id = :id");

// values are separate - passed to prepared statement
c.query(Q.positional, Q.bind(.{ .id = user_id }));
```

the key insight from t-strings: **deferred composition**. don't combine template and values immediately - let a domain-specific processor (the database driver) do it safely.

## why comptime makes this safe

in python, t-strings are opt-in. you can still write:

```python
f"SELECT * FROM users WHERE id = {user_id}"  # dangerous
```

in zig with zql, **comptime enforces the separation**:

```zig
// this doesn't compile - user_id isn't comptime
const Q = zql.Query("SELECT * FROM users WHERE id = '" ++ user_id ++ "'");
```

you literally cannot concatenate runtime values into the sql string.

## the flow

1. **comptime**: sql string parsed, `:name` → `?`, columns extracted
2. **comptime**: `bind()` validates struct has required params
3. **runtime**: `bind()` returns values as tuple in param order
4. **runtime**: database driver uses prepared statement

user input never touches the sql string. it's bound as parameters.

## what zql doesn't protect against

- sql logic bugs (wrong WHERE clause, etc.)
- authorization issues (query returns data user shouldn't see)
- denial of service (expensive queries)
- the database driver not using prepared statements properly

zql prevents injection. it doesn't prevent bad queries.

## comparison

| approach | injection risk |
|----------|---------------|
| string concat | high - user input in sql |
| f-strings (python) | high - opt-in safety |
| t-strings (python) | low - deferred composition |
| zql (zig) | **none** - comptime enforces separation |

## references

- [PEP 750 - Template Strings](https://peps.python.org/pep-0750/)
- [OWASP SQL Injection Prevention](https://cheatsheetseries.owasp.org/cheatsheets/SQL_Injection_Prevention_Cheat_Sheet.html)
