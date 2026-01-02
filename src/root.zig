//! zql - comptime sql ergonomics for zig
//!
//! backend-agnostic sql library with:
//! - comptime parameter validation
//! - comptime column name extraction
//! - zero-overhead named column access
//! - struct mapping
//!
//! example:
//! ```zig
//! const db = try zql.open(MyDriver, .{ .url = "..." });
//!
//! // named params - validated at comptime
//! try db.exec("INSERT INTO users (name, age) VALUES (:name, :age)", .{
//!     .name = "bob",
//!     .age = 30,
//! });
//!
//! // query with typed rows
//! var rows = try db.query("SELECT id, name, age FROM users WHERE age > :min", .{ .min = 18 });
//! defer rows.deinit();
//!
//! while (rows.next()) |row| {
//!     // named column access - validated at comptime
//!     const name = row.text(.name);
//!     const age = row.int(.age);
//! }
//!
//! // or map directly to struct
//! const User = struct { id: i64, name: []const u8, age: ?i64 };
//! const users = try db.queryAs(User, "SELECT id, name, age FROM users", .{});
//! ```

const std = @import("std");

pub const parse = @import("parse.zig");

test {
    _ = parse;
}
