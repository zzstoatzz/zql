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

const std = @import("std");

/// max named parameters per query
pub const MAX_PARAMS = 32;

/// max columns per SELECT
pub const MAX_COLS = 64;

/// max sql string length
pub const MAX_SQL_LEN = 4096;

/// result of parsing a sql string at comptime
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

pub fn parse(sql: []const u8) @This() {
    var result: @This() = .{
        .positional = undefined,
        .positional_len = 0,
        .param_count = 0,
        .params = undefined,
        .params_len = 0,
        .columns = undefined,
        .columns_len = 0,
    };

    result.parseParams(sql);
    result.parseColumns(sql);

    return result;
}

pub fn parseComptime(comptime sql: []const u8) @This() {
    @setEvalBranchQuota(sql.len * 100);
    return comptime .parse(sql);
}

fn parseParams(result: *@This(), sql: []const u8) void {
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
            const end = for (start..sql.len) |j| {
                if (!isIdentChar(sql[j]))
                    break j;
            } else sql.len;
            result.params[result.params_len] = sql[start..end];
            result.params_len += 1;
            i = end - 1;
        } else {
            result.positional[result.positional_len] = sql[i];
            result.positional_len += 1;
        }
    }
}

fn parseColumns(result: *@This(), sql: []const u8) void {
    const select_start = findSelectStart(sql) orelse return;
    const from_pos = findFromPos(sql, select_start) orelse sql.len;

    // work directly with sql and offset, not a sub-slice
    const cols_start = select_start + countLeadingWhitespace(sql[select_start..from_pos]);
    const cols_end = from_pos - countTrailingWhitespace(sql[select_start..from_pos]);

    if (cols_start >= cols_end) return;
    if (std.mem.eql(u8, sql[cols_start..cols_end], "*")) return;

    var col_i = cols_start;
    var paren_depth: usize = 0;

    while (col_i < cols_end) {
        col_i = for (sql[col_i..cols_end], col_i..) |c, i| {
            if (!isWhitespace(c))
                break i;
        } else break;

        var last_id: ?struct { usize, usize } = null;

        while (col_i < cols_end) : (col_i += 1) {
            paren_check: {
                switch (sql[col_i]) {
                    '(' => paren_depth += 1,

                    ')' => paren_depth -|= 1,

                    else => if (paren_depth == 0) break :paren_check,
                }
                continue;
            }

            const is_quoted = is_quoted: switch (sql[col_i]) {
                ',' => break,

                '"' => {
                    col_i += 1;
                    if (col_i >= cols_end)
                        return; // should return an error
                    break :is_quoted true;
                },

                else => false,
            };

            if (!isIdentStart(sql[col_i])) continue;

            last_id = .{
                col_i,
                end: {
                    col_i = for (sql[col_i + 1 .. cols_end], col_i + 1..) |d, i| {
                        if (!isIdentChar(d))
                            break i;
                    } else cols_end;

                    if (is_quoted) {
                        if (col_i == cols_end or sql[col_i] != '"')
                            return; // should return an error
                        break :end col_i;
                    } else {
                        defer col_i -= 1;
                        break :end col_i;
                    }
                },
            };
        }

        if (last_id) |id| {
            result.columns[result.columns_len] = sql[id[0]..id[1]];
            result.columns_len += 1;
        }

        if (col_i < cols_end and sql[col_i] == ',')
            col_i += 1;
    }
}

fn countLeadingWhitespace(s: []const u8) usize {
    for (s, 0..) |c, i|
        if (!isWhitespace(c))
            return i;
    return s.len;
}

fn countTrailingWhitespace(s: []const u8) usize {
    for (0..s.len) |i|
        if (!isWhitespace(s[s.len - 1 - i]))
            return i;
    return s.len;
}

fn isIdentStart(c: u8) bool {
    return switch (c) {
        'a'...'z',
        'A'...'Z',
        '_',
        => true,

        else => false,
    };
}

fn isIdentChar(c: u8) bool {
    return switch (c) {
        '0'...'9' => true,

        else => isIdentStart(c),
    };
}

fn isWhitespace(c: u8) bool {
    return switch (c) {
        ' ',
        '\t',
        '\n',
        '\r',
        => true,

        else => false,
    };
}

fn findSelectStart(sql: []const u8) ?usize {
    if (sql.len < 52) {
        for (0..sql.len - "SELECT".len) |i| {
            if (caseInsensitiveAlphaPrefixMatch(sql[i..], "SELECT"))
                return i + "SELECT".len;
        }
    } else {
        const skip_table = boyerMooreHorspoolPreprocess("SELECT");
        var i: usize = 0;
        while (i <= sql.len - "SELECT".len) {
            if (caseInsensitiveAlphaPrefixMatch(sql[i..], "SELECT")) {
                return i + "SELECT".len;
            }
            i += skip_table[sql[i + "SELECT".len - 1] & uppercase_mask];
        }
    }
    return null;
}

/// asserts `sql.len - start >= "FROM".len`
fn findFromPos(sql: []const u8, start: usize) ?usize {
    var paren_depth: usize = 0;
    for (sql[start .. sql.len - "FROM".len], start..) |c, j| {
        switch (c) {
            '(' => paren_depth += 1,

            ')' => paren_depth -|= 1,

            else => {
                if (paren_depth == 0 and caseInsensitiveAlphaPrefixMatch(sql[j..], "FROM"))
                    return j;
            },
        }
    }
    return null;
}

// assert `prefix` is all uppercase alpha
fn caseInsensitiveAlphaPrefixMatch(haystick: []const u8, comptime prefix: []const u8) bool {
    const U = @Int(.unsigned, 8 * prefix.len);
    const val: U = @bitCast((haystick[0..prefix.len].*));
    const mask: U = @bitCast(@as([prefix.len]u8, @splat(uppercase_mask)));
    return val & mask == @as(U, @bitCast(prefix.*));
}

// adopted from `std.mem`
// the heuristics is `pattern.len > 4`
inline fn boyerMooreHorspoolPreprocess(pattern: []const u8) [256]usize {
    var table: [256]usize = @splat(pattern.len);
    for (pattern[0 .. pattern.len - 1], 0..) |c, i|
        table[c] = pattern.len - 1 - i;
    return table;
}

const uppercase_mask = 0b11011111;

// -----------------------------------------------------------------------------
// column extraction tests
// -----------------------------------------------------------------------------

test "columns: basic select" {
    const r = parse("SELECT id, name, age FROM users");
    try std.testing.expectEqual(3, r.columns_len);
    try std.testing.expectEqualStrings("id", r.columns[0]);
    try std.testing.expectEqualStrings("name", r.columns[1]);
    try std.testing.expectEqualStrings("age", r.columns[2]);
}

test "columns: case insensitive select" {
    const r = parse("sEleCt id, name, age fRoM users");
    try std.testing.expectEqual(3, r.columns_len);
    try std.testing.expectEqualStrings("id", r.columns[0]);
    try std.testing.expectEqualStrings("name", r.columns[1]);
    try std.testing.expectEqualStrings("age", r.columns[2]);
}

test "columns: quote escaped ids" {
    const r = parse("SELECT \"limit\", name, \"and\" FROM users");
    try std.testing.expectEqual(3, r.columns_len);
    try std.testing.expectEqualStrings("limit", r.columns[0]);
    try std.testing.expectEqualStrings("name", r.columns[1]);
    try std.testing.expectEqualStrings("and", r.columns[2]);
}

test "columns: with alias" {
    const r = parse("SELECT id, first_name AS name FROM users");
    try std.testing.expectEqual(2, r.columns_len);
    try std.testing.expectEqualStrings("id", r.columns[0]);
    try std.testing.expectEqualStrings("name", r.columns[1]);
}

test "columns: with function" {
    const r = parse("SELECT COUNT(*) AS total, MAX(age) AS oldest FROM users");
    try std.testing.expectEqual(2, r.columns_len);
    try std.testing.expectEqualStrings("total", r.columns[0]);
    try std.testing.expectEqualStrings("oldest", r.columns[1]);
}

test "columns: nested function" {
    const r = parse("SELECT COALESCE(name, 'unknown') AS name FROM users");
    try std.testing.expectEqual(1, r.columns_len);
    try std.testing.expectEqualStrings("name", r.columns[0]);
}

test "columns: table qualified" {
    const r = parse("SELECT u.id, u.name FROM users u");
    try std.testing.expectEqual(2, r.columns_len);
    try std.testing.expectEqualStrings("id", r.columns[0]);
    try std.testing.expectEqualStrings("name", r.columns[1]);
}

test "columns: case expression" {
    const r = parse("SELECT CASE WHEN x > 0 THEN 1 ELSE 0 END AS flag FROM t");
    try std.testing.expectEqual(1, r.columns_len);
    try std.testing.expectEqualStrings("flag", r.columns[0]);
}

test "columns: empty string literal" {
    const r = parse("SELECT id, '' AS empty FROM users");
    try std.testing.expectEqual(2, r.columns_len);
    try std.testing.expectEqualStrings("id", r.columns[0]);
    try std.testing.expectEqualStrings("empty", r.columns[1]);
}

test "columns: select star returns empty" {
    const r = parse("SELECT * FROM users");
    try std.testing.expectEqual(0, r.columns_len);
}

test "columns: multiline sql" {
    const r = parse(
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
    const r = parse(
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
    const r = parseComptime("SELECT * FROM users WHERE id = :id AND age > :min_age");
    try std.testing.expectEqual(2, r.params_len);
    try std.testing.expectEqualStrings("id", r.params[0]);
    try std.testing.expectEqualStrings("min_age", r.params[1]);
}

test "params: positional passthrough" {
    const r = parse("SELECT * FROM users WHERE id = ? AND age > ?");
    try std.testing.expectEqual(0, r.params_len); // no named params
    try std.testing.expectEqual(2, r.param_count); // but two positional
}

test "params: mixed named and positional" {
    const r = parse("SELECT * FROM users WHERE id = :id AND age > ?");
    try std.testing.expectEqual(1, r.params_len);
    try std.testing.expectEqualStrings("id", r.params[0]);
    try std.testing.expectEqual(2, r.param_count);
}

test "params: conversion to positional" {
    const r = parse("INSERT INTO users (name, age) VALUES (:name, :age)");
    try std.testing.expectEqualStrings(
        "INSERT INTO users (name, age) VALUES (?, ?)",
        r.positional[0..r.positional_len],
    );
}

test "params: underscore in name" {
    const r = parse("SELECT * FROM t WHERE x = :my_param_name");
    try std.testing.expectEqual(1, r.params_len);
    try std.testing.expectEqualStrings("my_param_name", r.params[0]);
}

test "params: no params" {
    const r = parse("SELECT id FROM users");
    try std.testing.expectEqual(0, r.params_len);
    try std.testing.expectEqual(0, r.param_count);
}

// stress tests

test "extra-long-sql" {
    comptime var sql: []const u8 = "SELECT * FROM users WHERE id = :id";
    inline for (0..31) |_|
        sql = sql ++ " AND ageageageageageageageageageage > :min_age";
    const r = parseComptime(sql);
    try std.testing.expectEqual(32, r.params_len);
    try std.testing.expectEqualStrings("id", r.params[0]);
    try std.testing.expectEqualStrings("min_age", r.params[1]);
}
