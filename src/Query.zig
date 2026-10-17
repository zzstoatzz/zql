//! Query - comptime sql metadata extraction
//!
//! extracts parameter names, column names, and provides
//! struct mapping utilities at compile time.

const std = @import("std");
const ParseResult = @import("ParseResult.zig");

/// query metadata extracted at comptime
pub fn Query(sql: []const u8) type {
    const parsed: ParseResult = .parseComptime(sql);

    return enum {
        pub const raw = sql;
        pub const positional = parsed.positional[0..parsed.positional_len];
        pub const param_count = parsed.param_count;
        pub const params = parsed.params[0..parsed.params_len];
        pub const columns = parsed.columns[0..parsed.columns_len];
        pub const columns_len = parsed.columns_len;
        pub const Columns = if (parsed.columns_len == 0) @Enum(noreturn, .exhaustive, &.{}, &.{}) else blk: {
            const TagInt = std.math.IntFittingRange(0, parsed.columns_len - 1);
            var values: [parsed.columns_len]TagInt = undefined;
            for (&values, 0..) |*value, i|
                value.* = i;
            break :blk @Enum(
                TagInt,
                .exhaustive,
                parsed.columns[0..parsed.columns_len],
                &values,
            );
        };

        const Q = @This();

        /// validate that args struct has all required params
        pub inline fn validateArgs(Args: type) void {
            comptime for (params) |p| {
                if (!@hasField(Args, p)) {
                    @compileError("missing param :" ++ p ++ " in args struct");
                }
                const F = @FieldType(Args, p);
                switch (F) {
                    bool,
                    ?bool,
                    comptime_int,
                    ?comptime_int,
                    @TypeOf(null),
                    => continue,

                    else => switch (@typeInfo(F)) {
                        .int => continue,

                        .optional => |info| if (@typeInfo(info.child) == .int) continue,

                        else => {},
                    },
                }
                if (!isStringCoercible(F))
                    @compileError("args struct's field '" ++ p ++ "' is of an invalid type " ++ @typeName(F));
            };
        }

        inline fn isStringCoercible(T: type) bool {
            comptime var is_opt_unwrapped = false;
            return info: switch (@typeInfo(T)) {
                .optional => |info| if (is_opt_unwrapped) false else {
                    is_opt_unwrapped = true;
                    continue :info @typeInfo(info.child);
                },

                .pointer => |info| switch (info.size) {
                    .one => switch (@typeInfo(info.child)) {
                        .array => |arr_info| arr_info.child == u8,

                        .vector => |vec_info| vec_info.child == u8,

                        else => false,
                    },

                    .slice => info.child == u8,

                    else => false,
                },

                else => false,
            };
        }

        /// validate that struct fields match query columns
        pub inline fn validateStruct(T: type) void {
            const struct_info = @typeInfo(T).@"struct";
            comptime for (struct_info.field_names, struct_info.field_types) |name, F| {
                if (!@hasField(Columns, name))
                    @compileError("struct field '" ++ name ++ "' not found in query columns");

                switch (F) {
                    ?i64,
                    i64,
                    bool,
                    ?bool,
                    []const u8,
                    ?[]const u8,
                    => {},

                    else => @compileError("struct field '" ++ name ++ "' is of an invalid type " ++ @typeName(F)),
                }
            };
        }

        /// get column index by name
        pub inline fn columnIndex(name: []const u8) ?std.meta.Tag(Columns) {
            if (@inComptime()) {
                const column = @field(Columns, name);
                return @backingInt(column);
            } else {
                const column = std.meta.stringToEnum(Columns, name) orelse return null;
                return @backingInt(column);
            }
        }

        /// map row data to a struct using column names
        /// row must have .text(idx) and .int(idx) methods
        pub fn fromRow(row: anytype, T: type) T {
            validateStruct(T);
            var result: T = undefined;
            const info = @typeInfo(T).@"struct";
            inline for (info.field_names, info.field_types) |name, F| {
                const idx = comptime columnIndex(name).?;
                @field(result, name) = switch (F) {
                    ?[]const u8,
                    []const u8,
                    => row.text(idx),

                    ?i64,
                    i64,
                    => row.int(idx),

                    ?bool => blk: {
                        const raw_i = row.int(idx);
                        const i = if (@TypeOf(raw_i) == ?i64)
                            raw_i orelse break :blk null
                        else
                            raw_i;
                        break :blk i != 0;
                    },

                    bool => row.int(idx) != 0,

                    else => comptime unreachable,
                };
            }
            return result;
        }

        /// bind args struct to positional tuple in param order
        pub fn bind(args: anytype) Bind(@TypeOf(args)).Tuple {
            validateArgs(@TypeOf(args));
            return Bind(@TypeOf(args)).toTuple(args);
        }

        fn Bind(Args: type) type {
            return enum {
                const Tuple = blk: {
                    var types: [param_count]type = undefined;
                    for (params, &types) |p, *T| {
                        const F = @FieldType(Args, p);
                        T.* = switch (@typeInfo(F)) {
                            .int,
                            .comptime_int,
                            => i64,

                            .optional => |info| switch (@typeInfo(info.child)) {
                                .int,
                                .comptime_int,
                                => ?i64,

                                .pointer => ?[]const u8,

                                else => F,
                            },

                            // TODO: handle NULL literal in prepared statements
                            .null => void,

                            .pointer => []const u8,

                            else => F,
                        };
                    }
                    break :blk @Tuple(&types);
                };

                fn toTuple(args: Args) Tuple {
                    var result: Tuple = undefined;
                    inline for (params, 0..) |p, i| {
                        const f = @field(args, p);
                        result[i] = switch (@TypeOf(result[i])) {
                            i64 => @intCast(f),

                            ?i64 => if (@field(args, p)) |v| @intCast(v) else null,

                            []const u8,
                            ?[]const u8,
                            => @ptrCast(f),

                            void => {},

                            else => f,
                        };
                    }
                    return result;
                }
            };
        }
    };
}

test "columns" {
    const Q = Query("SELECT id, name, age FROM users");
    try std.testing.expectEqual(3, Q.columns_len);
    try std.testing.expectEqual(0, @backingInt(Q.Columns.id));
    try std.testing.expectEqual(1, @backingInt(Q.Columns.name));
    try std.testing.expectEqual(2, @backingInt(Q.Columns.age));
}

test "named params" {
    const Q = Query("SELECT * FROM users WHERE id = :id AND age > :min_age");
    try std.testing.expectEqual(2, Q.param_count);
    try std.testing.expectEqualStrings("id", Q.params[0]);
    try std.testing.expectEqualStrings("min_age", Q.params[1]);
}

test "positional conversion" {
    const Q = Query("SELECT * FROM users WHERE id = :id AND age > :min_age");
    try std.testing.expectEqualStrings("SELECT * FROM users WHERE id = ? AND age > ?", Q.positional);
}

test "columns with alias" {
    const Q = Query("SELECT id, first_name AS name FROM users");
    try std.testing.expectEqual(2, Q.columns_len);
    try std.testing.expectEqual(0, @backingInt(Q.Columns.id));
    try std.testing.expectEqual(1, @backingInt(Q.Columns.name));
}

test "columns with function" {
    const Q = Query("SELECT COUNT(*) AS count, MAX(age) AS max_age FROM users");
    try std.testing.expectEqual(2, Q.columns_len);
    try std.testing.expectEqual(0, @backingInt(Q.Columns.count));
    try std.testing.expectEqual(1, @backingInt(Q.Columns.max_age));
}

test "columnIndex" {
    const Q = Query("SELECT id, name, age FROM users");
    // first verify columns work directly
    try std.testing.expectEqual(3, Q.columns_len);
    try std.testing.expectEqual(0, @backingInt(Q.Columns.id));

    // now try columnIndex
    try std.testing.expectEqual(0, Q.columnIndex("id"));
    try std.testing.expectEqual(1, Q.columnIndex("name"));
    try std.testing.expectEqual(2, Q.columnIndex("age"));
}

test "validateStruct" {
    const Q = Query("SELECT id, name, age FROM users");
    // verify columns first
    try std.testing.expectEqual(3, Q.columns_len);

    const User = struct { id: i64, name: []const u8, age: i64 };
    comptime Q.validateStruct(User);

    const Partial = struct { id: i64, name: []const u8 };
    comptime Q.validateStruct(Partial);
}

test "bind" {
    const Q = Query("INSERT INTO users (name, age) VALUES (:name, :age)");
    try std.testing.expectEqualStrings("INSERT INTO users (name, age) VALUES (?, ?)", Q.positional);

    const args = Q.bind(.{ .name = "alice", .age = @as(?i64, 25) });
    try std.testing.expectEqualStrings("alice", args[0]);
    try std.testing.expectEqual(25, args[1]);

    // order doesn't matter in input struct
    const args2 = Q.bind(.{ .age = null, .name = @as(?*const [3]u8, &[_]u8{ 'b', 'o', 'b' }) });
    try std.testing.expectEqualStrings("bob", args2[0].?);
    try std.testing.expectEqual({}, args2[1]);
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

        const as = Q.fromRow;
    };

    const row = MockRow{
        .texts = .{ "42", "alice", "25" },
        .ints = .{ 42, 0, 25 },
    };

    const User = struct {
        id: i64,
        name: []const u8,
        age: i64,
    };
    const user = row.as(User);

    try std.testing.expectEqual(42, user.id);
    try std.testing.expectEqualStrings("alice", user.name);
    try std.testing.expectEqual(25, user.age);
}

test "nested expressions parse within eval quota" {
    const Q = Query(
        \\SELECT r.did AS did,
        \\  COUNT(DISTINCT CASE
        \\    WHEN DATE(COALESCE(NULLIF(r.created_at, ''), r.indexed_at)) >= DATE('now', ?)
        \\    THEN r.uri END) AS recommend_count,
        \\  COUNT(DISTINCT r.uri) AS total_recommends,
        \\  COUNT(DISTINCT r.document_uri) AS unique_docs,
        \\  MAX(COALESCE(NULLIF(r.created_at, ''), r.indexed_at)) AS last_at
        \\FROM recommends r
        \\GROUP BY r.did
        \\ORDER BY recommend_count DESC, last_at DESC
    );
    try std.testing.expectEqual(5, Q.columns_len);
    try std.testing.expectEqual(1, Q.columnIndex("recommend_count"));
    try std.testing.expectEqual(4, Q.columnIndex("last_at"));
}

test "query without columns" {
    const Q = Query("DELETE FROM users WHERE id = :id");
    try std.testing.expectEqual(0, Q.columns.len);
    try std.testing.expectEqual(0, @typeInfo(Q.Columns).@"enum".field_names.len);
    try std.testing.expectEqual(null, Q.columnIndex("id"));
}
