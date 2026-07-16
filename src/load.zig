//! `silica load` bulk-ingest line format — the sodl-compiler↔db contract.
//! Normative definition: SPEC.md "Bulk load". Tab-separated, one op per line:
//!
//!   put   <key> <kind> <tags> <src> <body...>
//!   link  <subj> <pred> <obj> <weight> <src>
//!
//! Empty fields take defaults (kind note, weight 1.0, tags/src omitted).
//! `put` body is everything after the fifth tab and may itself contain tabs.
//! Blank lines and lines starting with `#` are skipped.

const std = @import("std");

pub const kind_names = [_][]const u8{ "note", "fact", "pref", "project", "ref" };

pub fn kindParse(s: []const u8) ?u8 {
    for (kind_names, 0..) |n, i| {
        if (std.mem.eql(u8, s, n)) return @intCast(i);
    }
    return std.fmt.parseInt(u8, s, 10) catch null;
}

pub const Put = struct { key: []const u8, kind: u8, tags: []const u8, src: []const u8, body: []const u8 };
pub const Link = struct { s: []const u8, p: []const u8, o: []const u8, w: f32, src: []const u8 };
pub const Line = union(enum) { put: Put, link: Link };

/// Parse one line (no trailing newline). null = blank/comment, skip it.
/// Slices point into `line`.
pub fn parseLine(line: []const u8) error{Malformed}!?Line {
    const l = std.mem.trimEnd(u8, line, "\r");
    if (l.len == 0 or l[0] == '#') return null;

    var it = std.mem.splitScalar(u8, l, '\t');
    const op = it.next() orelse return error.Malformed;

    if (std.mem.eql(u8, op, "put")) {
        const key = it.next() orelse return error.Malformed;
        const kinds = it.next() orelse return error.Malformed;
        const tags = it.next() orelse return error.Malformed;
        const src = it.next() orelse return error.Malformed;
        const body = it.rest();
        if (key.len == 0) return error.Malformed;
        const kind: u8 = if (kinds.len == 0) 0 else kindParse(kinds) orelse return error.Malformed;
        return .{ .put = .{ .key = key, .kind = kind, .tags = tags, .src = src, .body = body } };
    }
    if (std.mem.eql(u8, op, "link")) {
        const s = it.next() orelse return error.Malformed;
        const p = it.next() orelse return error.Malformed;
        const o = it.next() orelse return error.Malformed;
        const ws = it.next() orelse "";
        const src = it.next() orelse "";
        if (it.next() != null) return error.Malformed; // trailing fields
        if (s.len == 0 or p.len == 0 or o.len == 0) return error.Malformed;
        var w: f32 = 1.0;
        if (ws.len > 0) {
            w = std.fmt.parseFloat(f32, ws) catch return error.Malformed;
            if (!std.math.isFinite(w)) return error.Malformed;
        }
        return .{ .link = .{ .s = s, .p = p, .o = o, .w = w, .src = src } };
    }
    return error.Malformed;
}
