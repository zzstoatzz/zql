//! zql - comptime sql ergonomics for zig (alpha)
//!
//! status: alpha - api may change
//!
//! usage:
//! ```zig
//! const zql = @import("zql");
//!
//! const Q = zql.Query("SELECT id, name FROM users WHERE age > :min_age");
//!
//! // comptime validation
//! Q.validateArgs(struct { min_age: i64 });
//!
//! // access parsed metadata
//! _ = Q.positional; // "SELECT id, name FROM users WHERE age > ?"
//! _ = Q.params;     // ["min_age"]
//! _ = Q.columns;    // ["id", "name"]
//!
//! // struct mapping
//! const User = struct { id: i64, name: []const u8 };
//! Q.validateStruct(User);
//! const user = Q.fromRow(User, row_data);
//! ```

pub const Query = @import("Query.zig").Query;

test {
    _ = @import("Query.zig");
}
