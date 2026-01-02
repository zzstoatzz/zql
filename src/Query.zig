//! Query - comptime sql metadata extraction
//!
//! extracts parameter names, column names, and provides
//! struct mapping utilities at compile time.

const std = @import("std");
const parser = @import("parse.zig");

/// query metadata extracted at comptime
pub fn Query(comptime sql: []const u8) type {
    comptime {
        const parsed = parser.parse(sql);
        return struct {
            pub const raw = sql;
            pub const positional: []const u8 = parsed.positional[0..parsed.positional_len];
            pub const param_count = parsed.param_count;
            pub const params: []const []const u8 = parsed.params[0..parsed.params_len];
            pub const columns: []const []const u8 = parsed.columns[0..parsed.columns_len];

            /// validate that args struct has all required params
            pub fn validateArgs(comptime Args: type) void {
                const fields = @typeInfo(Args).@"struct".fields;
                inline for (params) |p| {
                    if (!hasField(fields, p)) {
                        @compileError("missing param :" ++ p ++ " in args struct");
                    }
                }
            }

            /// validate that struct fields match query columns
            pub fn validateStruct(comptime T: type) void {
                const fields = @typeInfo(T).@"struct".fields;
                inline for (fields) |f| {
                    if (!hasColumn(f.name)) {
                        @compileError("struct field '" ++ f.name ++ "' not found in query columns");
                    }
                }
            }

            /// get column index by name at comptime
            pub inline fn columnIndex(comptime name: []const u8) comptime_int {
                inline for (columns, 0..) |col, i| {
                    if (comptime std.mem.eql(u8, col, name)) {
                        return i;
                    }
                }
                @compileError("column '" ++ name ++ "' not found in query");
            }

            /// map row data to a struct using column names
            /// row must have .text(idx) and .int(idx) methods
            pub fn fromRow(comptime T: type, row: anytype) T {
                comptime validateStruct(T);
                var result: T = undefined;
                const fields = @typeInfo(T).@"struct".fields;
                inline for (fields) |f| {
                    const idx = comptime columnIndex(f.name);
                    @field(result, f.name) = switch (f.type) {
                        []const u8 => row.text(idx),
                        i64 => row.int(idx),
                        bool => row.int(idx) != 0,
                        else => @compileError("unsupported field type: " ++ @typeName(f.type)),
                    };
                }
                return result;
            }

            /// bind args struct to positional tuple in param order
            pub fn bind(args: anytype) BindTuple(@TypeOf(args)) {
                comptime validateArgs(@TypeOf(args));
                var result: BindTuple(@TypeOf(args)) = undefined;
                inline for (params, 0..) |p, i| {
                    result[i] = @field(args, p);
                }
                return result;
            }

            fn BindTuple(comptime Args: type) type {
                const fields = @typeInfo(Args).@"struct".fields;
                var types: [param_count]type = undefined;
                inline for (params, 0..) |p, i| {
                    for (fields) |f| {
                        if (std.mem.eql(u8, f.name, p)) {
                            types[i] = f.type;
                            break;
                        }
                    }
                }
                return std.meta.Tuple(&types);
            }

            fn hasField(fields: anytype, name: []const u8) bool {
                inline for (fields) |f| {
                    if (std.mem.eql(u8, f.name, name)) return true;
                }
                return false;
            }

            fn hasColumn(comptime name: []const u8) bool {
                const cols = @This().columns;
                inline for (cols) |col| {
                    if (std.mem.eql(u8, col, name)) return true;
                }
                return false;
            }
        };
    }
}

test "columns" {
    const Q = Query("SELECT id, name, age FROM users");
    try std.testing.expectEqual(3, Q.columns.len);
    try std.testing.expectEqualStrings("id", Q.columns[0]);
    try std.testing.expectEqualStrings("name", Q.columns[1]);
    try std.testing.expectEqualStrings("age", Q.columns[2]);
}

test "named params" {
    const Q = Query("SELECT * FROM users WHERE id = :id AND age > :min_age");
    try std.testing.expectEqual(2, Q.params.len);
    try std.testing.expectEqualStrings("id", Q.params[0]);
    try std.testing.expectEqualStrings("min_age", Q.params[1]);
}

test "positional conversion" {
    const Q = Query("SELECT * FROM users WHERE id = :id AND age > :min_age");
    try std.testing.expectEqualStrings("SELECT * FROM users WHERE id = ? AND age > ?", Q.positional);
}

test "columns with alias" {
    const Q = Query("SELECT id, first_name AS name FROM users");
    try std.testing.expectEqual(2, Q.columns.len);
    try std.testing.expectEqualStrings("id", Q.columns[0]);
    try std.testing.expectEqualStrings("name", Q.columns[1]);
}

test "columns with function" {
    const Q = Query("SELECT COUNT(*) AS count, MAX(age) AS max_age FROM users");
    try std.testing.expectEqual(2, Q.columns.len);
    try std.testing.expectEqualStrings("count", Q.columns[0]);
    try std.testing.expectEqualStrings("max_age", Q.columns[1]);
}

test "columnIndex" {
    const Q = Query("SELECT id, name, age FROM users");
    // first verify columns work directly
    try std.testing.expectEqual(3, Q.columns.len);
    try std.testing.expectEqualStrings("id", Q.columns[0]);

    // now try columnIndex
    try std.testing.expectEqual(0, Q.columnIndex("id"));
    try std.testing.expectEqual(1, Q.columnIndex("name"));
    try std.testing.expectEqual(2, Q.columnIndex("age"));
}

test "validateStruct" {
    const Q = Query("SELECT id, name, age FROM users");
    // verify columns first
    try std.testing.expectEqual(3, Q.columns.len);

    const User = struct { id: i64, name: []const u8, age: i64 };
    comptime Q.validateStruct(User);

    const Partial = struct { id: i64, name: []const u8 };
    comptime Q.validateStruct(Partial);
}

test "bind" {
    const Q = Query("INSERT INTO users (name, age) VALUES (:name, :age)");
    try std.testing.expectEqualStrings("INSERT INTO users (name, age) VALUES (?, ?)", Q.positional);

    const args = Q.bind(.{ .name = "alice", .age = @as(i64, 25) });
    try std.testing.expectEqualStrings("alice", args[0]);
    try std.testing.expectEqual(25, args[1]);

    // order doesn't matter in input struct
    const args2 = Q.bind(.{ .age = @as(i64, 30), .name = "bob" });
    try std.testing.expectEqualStrings("bob", args2[0]);
    try std.testing.expectEqual(30, args2[1]);
}

test "fromRow" {
    const Q = Query("SELECT id, name, age FROM users");

    // mock row matching leaflet-search's Row interface
    const MockRow = struct {
        texts: [3][]const u8,
        ints: [3]i64,

        pub fn text(self: @This(), idx: usize) []const u8 {
            return self.texts[idx];
        }
        pub fn int(self: @This(), idx: usize) i64 {
            return self.ints[idx];
        }
    };

    const row = MockRow{
        .texts = .{ "42", "alice", "25" },
        .ints = .{ 42, 0, 25 },
    };

    const User = struct { id: i64, name: []const u8, age: i64 };
    const user = Q.fromRow(User, row);

    try std.testing.expectEqual(42, user.id);
    try std.testing.expectEqualStrings("alice", user.name);
    try std.testing.expectEqual(25, user.age);
}
