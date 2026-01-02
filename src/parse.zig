//! comptime sql parsing utilities

const std = @import("std");

/// query metadata extracted at comptime
pub fn Query(comptime sql: []const u8) type {
    comptime {
        const parsed = parse(sql);
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
                    var found = false;
                    inline for (fields) |f| {
                        if (std.mem.eql(u8, f.name, p)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        @compileError("missing param :" ++ p ++ " in args struct");
                    }
                }
            }
        };
    }
}

const MAX_PARAMS = 32;
const MAX_COLS = 64;

const ParseResult = struct {
    positional: [4096]u8,
    positional_len: usize,
    param_count: usize,
    params: [MAX_PARAMS][]const u8,
    params_len: usize,
    columns: [MAX_COLS][]const u8,
    columns_len: usize,
};

fn parse(comptime sql: []const u8) ParseResult {
    var result = ParseResult{
        .positional = undefined,
        .positional_len = 0,
        .param_count = 0,
        .params = undefined,
        .params_len = 0,
        .columns = undefined,
        .columns_len = 0,
    };

    // convert :name to ? and extract param names
    var i: usize = 0;
    while (i < sql.len) : (i += 1) {
        if (sql[i] == '?') {
            result.positional[result.positional_len] = '?';
            result.positional_len += 1;
            result.param_count += 1;
        } else if (sql[i] == ':' and i + 1 < sql.len and isIdentStart(sql[i + 1])) {
            result.positional[result.positional_len] = '?';
            result.positional_len += 1;
            result.param_count += 1;

            const start = i + 1;
            var end = start;
            while (end < sql.len and isIdentChar(sql[end])) : (end += 1) {}
            result.params[result.params_len] = sql[start..end];
            result.params_len += 1;
            i = end - 1;
        } else {
            result.positional[result.positional_len] = sql[i];
            result.positional_len += 1;
        }
    }

    // extract columns from SELECT
    const select_start = findSelectStart(sql);
    if (select_start) |start| {
        const from_pos = findFromPos(sql, start) orelse sql.len;
        const cols_str = std.mem.trim(u8, sql[start..from_pos], " \t\n\r");

        if (cols_str.len > 0 and !std.mem.eql(u8, cols_str, "*")) {
            var col_i: usize = 0;
            var paren_depth: usize = 0;

            while (col_i < cols_str.len) {
                while (col_i < cols_str.len and isWhitespace(cols_str[col_i])) : (col_i += 1) {}
                if (col_i >= cols_str.len) break;

                var last_ident_start: ?usize = null;
                var last_ident_end: ?usize = null;

                while (col_i < cols_str.len) : (col_i += 1) {
                    const c = cols_str[col_i];
                    if (c == '(') {
                        paren_depth += 1;
                    } else if (c == ')') {
                        paren_depth -|= 1;
                    } else if (c == ',' and paren_depth == 0) {
                        break;
                    } else if (isIdentStart(c) and paren_depth == 0) {
                        last_ident_start = col_i;
                        while (col_i < cols_str.len and isIdentChar(cols_str[col_i])) : (col_i += 1) {}
                        last_ident_end = col_i;
                        col_i -= 1;
                    }
                }

                if (last_ident_start) |s| {
                    result.columns[result.columns_len] = cols_str[s..last_ident_end.?];
                    result.columns_len += 1;
                }

                if (col_i < cols_str.len and cols_str[col_i] == ',') col_i += 1;
            }
        }
    }

    return result;
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn findSelectStart(comptime sql: []const u8) ?usize {
    var upper: [sql.len]u8 = undefined;
    for (sql, 0..) |c, idx| {
        upper[idx] = if (c >= 'a' and c <= 'z') c - 32 else c;
    }
    const idx = std.mem.indexOf(u8, &upper, "SELECT") orelse return null;
    return idx + 6;
}

fn findFromPos(comptime sql: []const u8, start: usize) ?usize {
    var upper: [sql.len]u8 = undefined;
    for (sql, 0..) |c, idx| {
        upper[idx] = if (c >= 'a' and c <= 'z') c - 32 else c;
    }
    var paren_depth: usize = 0;
    var j = start;
    while (j + 4 <= sql.len) : (j += 1) {
        if (upper[j] == '(') {
            paren_depth += 1;
        } else if (upper[j] == ')') {
            paren_depth -|= 1;
        } else if (paren_depth == 0 and std.mem.eql(u8, upper[j .. j + 4], "FROM")) {
            return j;
        }
    }
    return null;
}

// tests

test "Query - named params" {
    const Q = Query("SELECT * FROM users WHERE id = :id AND age > :min_age");
    try std.testing.expectEqual(2, Q.params.len);
    try std.testing.expectEqualStrings("id", Q.params[0]);
    try std.testing.expectEqualStrings("min_age", Q.params[1]);
}

test "Query - positional conversion" {
    const Q = Query("SELECT * FROM users WHERE id = :id AND age > :min_age");
    try std.testing.expectEqualStrings("SELECT * FROM users WHERE id = ? AND age > ?", Q.positional);
}

test "Query - columns" {
    const Q = Query("SELECT id, name, age FROM users");
    try std.testing.expectEqual(3, Q.columns.len);
    try std.testing.expectEqualStrings("id", Q.columns[0]);
    try std.testing.expectEqualStrings("name", Q.columns[1]);
    try std.testing.expectEqualStrings("age", Q.columns[2]);
}

test "Query - columns with alias" {
    const Q = Query("SELECT id, first_name AS name FROM users");
    try std.testing.expectEqual(2, Q.columns.len);
    try std.testing.expectEqualStrings("id", Q.columns[0]);
    try std.testing.expectEqualStrings("name", Q.columns[1]);
}

test "Query - columns with function" {
    const Q = Query("SELECT COUNT(*) AS count, MAX(age) AS max_age FROM users");
    try std.testing.expectEqual(2, Q.columns.len);
    try std.testing.expectEqualStrings("count", Q.columns[0]);
    try std.testing.expectEqualStrings("max_age", Q.columns[1]);
}

test "Query - param extraction for INSERT" {
    const Q = Query("INSERT INTO users (name, age) VALUES (:name, :age)");
    try std.testing.expectEqual(2, Q.params.len);
    try std.testing.expectEqualStrings("name", Q.params[0]);
    try std.testing.expectEqualStrings("age", Q.params[1]);
}

test "Query - no params" {
    const Q = Query("SELECT * FROM users");
    try std.testing.expectEqual(0, Q.params.len);
    try std.testing.expectEqual(0, Q.param_count);
}
