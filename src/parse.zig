//! comptime sql parsing
//!
//! extracts metadata from sql strings at compile time:
//! - column names from SELECT clauses
//! - named parameter names (:name -> ?)
//! - positional sql with named params converted
//!
//! sql injection safety:
//! - sql strings are comptime, so user input cannot be concatenated
//! - parameters are bound via prepared statements, not interpolated
//! - the :name syntax reinforces parameterized query patterns
//!
//! limitations:
//! - SELECT * returns empty columns (can't know schema)
//! - no subquery support in column extraction
//! - no quoted identifier support ("column name")

const std = @import("std");

/// max named parameters per query
pub const MAX_PARAMS = 32;

/// max columns per SELECT
pub const MAX_COLS = 64;

/// max sql string length
pub const MAX_SQL_LEN = 4096;

/// result of parsing a sql string at comptime
pub const ParseResult = struct {
    /// sql with :name params replaced by ?
    positional: [MAX_SQL_LEN]u8,
    positional_len: usize,

    /// total parameter count (named + positional)
    param_count: usize,

    /// extracted named parameter names in order
    params: [MAX_PARAMS][]const u8,
    params_len: usize,

    /// extracted column names/aliases from SELECT
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

// -----------------------------------------------------------------------------
// column extraction tests
// -----------------------------------------------------------------------------

test "columns: basic select" {
    const r = comptime parse("SELECT id, name, age FROM users");
    try std.testing.expectEqual(3, r.columns_len);
    try std.testing.expectEqualStrings("id", r.columns[0]);
    try std.testing.expectEqualStrings("name", r.columns[1]);
    try std.testing.expectEqualStrings("age", r.columns[2]);
}

test "columns: with alias" {
    const r = comptime parse("SELECT id, first_name AS name FROM users");
    try std.testing.expectEqual(2, r.columns_len);
    try std.testing.expectEqualStrings("id", r.columns[0]);
    try std.testing.expectEqualStrings("name", r.columns[1]);
}

test "columns: with function" {
    const r = comptime parse("SELECT COUNT(*) AS total, MAX(age) AS oldest FROM users");
    try std.testing.expectEqual(2, r.columns_len);
    try std.testing.expectEqualStrings("total", r.columns[0]);
    try std.testing.expectEqualStrings("oldest", r.columns[1]);
}

test "columns: nested function" {
    const r = comptime parse("SELECT COALESCE(name, 'unknown') AS name FROM users");
    try std.testing.expectEqual(1, r.columns_len);
    try std.testing.expectEqualStrings("name", r.columns[0]);
}

test "columns: table qualified" {
    const r = comptime parse("SELECT u.id, u.name FROM users u");
    try std.testing.expectEqual(2, r.columns_len);
    try std.testing.expectEqualStrings("id", r.columns[0]);
    try std.testing.expectEqualStrings("name", r.columns[1]);
}

test "columns: case expression" {
    const r = comptime parse("SELECT CASE WHEN x > 0 THEN 1 ELSE 0 END AS flag FROM t");
    try std.testing.expectEqual(1, r.columns_len);
    try std.testing.expectEqualStrings("flag", r.columns[0]);
}

test "columns: empty string literal" {
    const r = comptime parse("SELECT id, '' AS empty FROM users");
    try std.testing.expectEqual(2, r.columns_len);
    try std.testing.expectEqualStrings("id", r.columns[0]);
    try std.testing.expectEqualStrings("empty", r.columns[1]);
}

test "columns: select star returns empty" {
    const r = comptime parse("SELECT * FROM users");
    try std.testing.expectEqual(0, r.columns_len);
}

test "columns: multiline sql" {
    const r = comptime parse(
        \\SELECT id, name,
        \\  created_at
        \\FROM users
    );
    try std.testing.expectEqual(3, r.columns_len);
    try std.testing.expectEqualStrings("id", r.columns[0]);
    try std.testing.expectEqualStrings("name", r.columns[1]);
    try std.testing.expectEqualStrings("created_at", r.columns[2]);
}

test "columns: snippet function (fts5)" {
    const r = comptime parse(
        \\SELECT uri, snippet(docs_fts, 1, '<b>', '</b>', '...', 32) AS snippet
        \\FROM docs_fts
    );
    try std.testing.expectEqual(2, r.columns_len);
    try std.testing.expectEqualStrings("uri", r.columns[0]);
    try std.testing.expectEqualStrings("snippet", r.columns[1]);
}

// -----------------------------------------------------------------------------
// parameter extraction tests
// -----------------------------------------------------------------------------

test "params: named" {
    const r = comptime parse("SELECT * FROM users WHERE id = :id AND age > :min_age");
    try std.testing.expectEqual(2, r.params_len);
    try std.testing.expectEqualStrings("id", r.params[0]);
    try std.testing.expectEqualStrings("min_age", r.params[1]);
}

test "params: positional passthrough" {
    const r = comptime parse("SELECT * FROM users WHERE id = ? AND age > ?");
    try std.testing.expectEqual(0, r.params_len); // no named params
    try std.testing.expectEqual(2, r.param_count); // but two positional
}

test "params: mixed named and positional" {
    const r = comptime parse("SELECT * FROM users WHERE id = :id AND age > ?");
    try std.testing.expectEqual(1, r.params_len);
    try std.testing.expectEqualStrings("id", r.params[0]);
    try std.testing.expectEqual(2, r.param_count);
}

test "params: conversion to positional" {
    const r = comptime parse("INSERT INTO users (name, age) VALUES (:name, :age)");
    try std.testing.expectEqualStrings(
        "INSERT INTO users (name, age) VALUES (?, ?)",
        r.positional[0..r.positional_len],
    );
}

test "params: underscore in name" {
    const r = comptime parse("SELECT * FROM t WHERE x = :my_param_name");
    try std.testing.expectEqual(1, r.params_len);
    try std.testing.expectEqualStrings("my_param_name", r.params[0]);
}

test "params: no params" {
    const r = comptime parse("SELECT id FROM users");
    try std.testing.expectEqual(0, r.params_len);
    try std.testing.expectEqual(0, r.param_count);
}
