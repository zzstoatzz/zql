//! sql parsing utilities

const std = @import("std");

pub const MAX_PARAMS = 32;
pub const MAX_COLS = 64;
pub const MAX_SQL_LEN = 4096;

pub const ParseResult = struct {
    positional: [MAX_SQL_LEN]u8,
    positional_len: usize,
    param_count: usize,
    params: [MAX_PARAMS][]const u8,
    params_len: usize,
    columns: [MAX_COLS][]const u8,
    columns_len: usize,
};

pub fn parse(comptime sql: []const u8) ParseResult {
    @setEvalBranchQuota(sql.len * 100);
    var result = ParseResult{
        .positional = undefined,
        .positional_len = 0,
        .param_count = 0,
        .params = undefined,
        .params_len = 0,
        .columns = undefined,
        .columns_len = 0,
    };

    parseParams(sql, &result);
    parseColumns(sql, &result);

    return result;
}

fn parseParams(comptime sql: []const u8, result: *ParseResult) void {
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
}

fn parseColumns(comptime sql: []const u8, result: *ParseResult) void {
    const select_start = findSelectStart(sql) orelse return;
    const from_pos = findFromPos(sql, select_start) orelse sql.len;

    // work directly with sql and offset, not a sub-slice
    const cols_start = select_start + countLeadingWhitespace(sql[select_start..from_pos]);
    const cols_end = from_pos - countTrailingWhitespace(sql[select_start..from_pos]);

    if (cols_start >= cols_end) return;
    if (std.mem.eql(u8, sql[cols_start..cols_end], "*")) return;

    var col_i: usize = cols_start;
    var paren_depth: usize = 0;

    while (col_i < cols_end) {
        while (col_i < cols_end and isWhitespace(sql[col_i])) : (col_i += 1) {}
        if (col_i >= cols_end) break;

        var last_ident_start: ?usize = null;
        var last_ident_end: ?usize = null;

        while (col_i < cols_end) : (col_i += 1) {
            const c = sql[col_i];
            if (c == '(') {
                paren_depth += 1;
            } else if (c == ')') {
                paren_depth -|= 1;
            } else if (c == ',' and paren_depth == 0) {
                break;
            } else if (isIdentStart(c) and paren_depth == 0) {
                last_ident_start = col_i;
                while (col_i < cols_end and isIdentChar(sql[col_i])) : (col_i += 1) {}
                last_ident_end = col_i;
                col_i -= 1;
            }
        }

        if (last_ident_start) |s| {
            result.columns[result.columns_len] = sql[s..last_ident_end.?];
            result.columns_len += 1;
        }

        if (col_i < cols_end and sql[col_i] == ',') col_i += 1;
    }
}

fn countLeadingWhitespace(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len and isWhitespace(s[i])) : (i += 1) {}
    return i;
}

fn countTrailingWhitespace(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len and isWhitespace(s[s.len - 1 - i])) : (i += 1) {}
    return i;
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

test "parse columns" {
    const result = comptime parse("SELECT id, name, age FROM users");
    try std.testing.expectEqual(3, result.columns_len);
    try std.testing.expectEqualStrings("id", result.columns[0]);
    try std.testing.expectEqualStrings("name", result.columns[1]);
    try std.testing.expectEqualStrings("age", result.columns[2]);

    // test slicing works correctly
    const cols: []const []const u8 = result.columns[0..result.columns_len];
    try std.testing.expectEqual(3, cols.len);
    try std.testing.expectEqualStrings("id", cols[0]);
}
