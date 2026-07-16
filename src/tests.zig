//! Unit smoke tests: wire round-trips, store put/get/del/link + log replay.
//! Run with `zig build test`. End-to-end daemon test is scripts/smoke.sh.

const std = @import("std");
const proto = @import("proto.zig");
const wire = @import("wire.zig");
const Store = @import("store.zig").Store;

const t = std.testing;

test "hdr round-trip" {
    var h: [proto.HDR_SIZE]u8 = undefined;
    wire.hdrWrite(&h, .{ .len = 42, .op = proto.OP_PUT, .flags = proto.F_RESP, .status = proto.ST_OK, .rid = 0x0123456789abcdef });
    const rt = wire.hdrRead(&h);
    try t.expectEqual(@as(u32, 42), rt.len);
    try t.expectEqual(proto.OP_PUT, rt.op);
    try t.expectEqual(proto.F_RESP, rt.flags);
    try t.expectEqual(proto.ST_OK, rt.status);
    try t.expectEqual(@as(u64, 0x0123456789abcdef), rt.rid);
}

test "tlv encode/decode round-trip" {
    const gpa = t.allocator;
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    try wire.tlv(&b, gpa, proto.T_KEY, "some/key");
    try wire.tlvU8(&b, gpa, proto.T_KIND, proto.K_FACT);
    try wire.tlvU64(&b, gpa, proto.T_TS, 12345);
    try wire.tlvF32(&b, gpa, proto.T_WEIGHT, 0.75);

    try t.expectEqualStrings("some/key", (try wire.findStr(b.items, proto.T_KEY, proto.KEY_MAX)).?);
    try t.expectEqual(proto.K_FACT, (try wire.findU8(b.items, proto.T_KIND)).?);
    try t.expectEqual(@as(u64, 12345), (try wire.findU64(b.items, proto.T_TS)).?);
    try t.expectEqual(@as(f32, 0.75), (try wire.findF32(b.items, proto.T_WEIGHT)).?);
    try t.expectEqual(@as(?[]const u8, null), try wire.find(b.items, proto.T_BODY));
}

test "findF32 rejects non-finite" {
    const gpa = t.allocator;
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    try wire.tlvF32(&b, gpa, proto.T_WEIGHT, std.math.nan(f32));
    try t.expectError(error.Malformed, wire.findF32(b.items, proto.T_WEIGHT));
}

test "tlv rejects malformed input" {
    // header claims more bytes than present
    var bad: [7]u8 = undefined;
    std.mem.writeInt(u16, bad[0..2], proto.T_KEY, .little);
    std.mem.writeInt(u32, bad[2..6], 100, .little);
    bad[6] = 'x';
    try t.expectError(error.Malformed, wire.find(&bad, proto.T_KEY));
    // truncated header
    try t.expectError(error.Malformed, wire.find(bad[0..3], proto.T_KEY));
    // embedded NUL rejected by findStr
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(t.allocator);
    try wire.tlv(&b, t.allocator, proto.T_KEY, "a\x00b");
    try t.expectError(error.Malformed, wire.findStr(b.items, proto.T_KEY, proto.KEY_MAX));
}

test "crcRecord is deterministic and type-sensitive" {
    try t.expectEqual(wire.crcRecord(1, "hello"), wire.crcRecord(1, "hello"));
    try t.expect(wire.crcRecord(1, "hello") != wire.crcRecord(2, "hello"));
    try t.expect(wire.crcRecord(1, "hello") != wire.crcRecord(1, "hellp"));
}

fn putKey(st: *Store, gpa: std.mem.Allocator, key: []const u8, body: []const u8) !void {
    var pl: std.ArrayList(u8) = .empty;
    defer pl.deinit(gpa);
    try wire.tlv(&pl, gpa, proto.T_KEY, key);
    try wire.tlvU8(&pl, gpa, proto.T_KIND, proto.K_NOTE);
    try wire.tlvU64(&pl, gpa, proto.T_TS, wire.nowNs());
    try wire.tlv(&pl, gpa, proto.T_BODY, body);
    try st.put(pl.items);
}

test "store put/get/del/link and replay across reopen" {
    const gpa = std.heap.c_allocator; // Store frees via same allocator it dups with
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var logbuf: [512]u8 = undefined;
    const logp = try std.fmt.bufPrintZ(&logbuf, ".zig-cache/tmp/{s}/memory.log", .{tmp.sub_path});

    {
        var st = try Store.open(gpa, logp);
        defer st.close();

        try putKey(&st, gpa, "a/one", "first");
        try putKey(&st, gpa, "a/two", "second");
        try st.link("a/one", "refines", "a/two", 1.0, "", wire.nowNs());

        const got = (try st.get(gpa, "a/one")).?;
        defer gpa.free(got);
        try t.expectEqualStrings("first", (try wire.find(got, proto.T_BODY)).?);

        try t.expectEqual(@as(?[]u8, null), try st.get(gpa, "missing"));
        try t.expect(try st.del("a/one"));
        try t.expect(!try st.del("a/one"));
        try t.expectEqual(@as(u64, 1), st.nkeys());
        try t.expectEqual(@as(u64, 1), st.nlinks());
    }

    // reopen: state must replay from log
    {
        var st = try Store.open(gpa, logp);
        defer st.close();
        try t.expectEqual(@as(u64, 1), st.nkeys());
        try t.expectEqual(@as(u64, 1), st.nlinks());
        try t.expectEqual(@as(?[]u8, null), try st.get(gpa, "a/one"));
        const got = (try st.get(gpa, "a/two")).?;
        defer gpa.free(got);
        try t.expectEqualStrings("second", (try wire.find(got, proto.T_BODY)).?);
    }
}

test "link weight/src persist, dedup updates in place, predicates intern" {
    const gpa = std.heap.c_allocator;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var logbuf: [512]u8 = undefined;
    const logp = try std.fmt.bufPrintZ(&logbuf, ".zig-cache/tmp/{s}/memory.log", .{tmp.sub_path});

    {
        var st = try Store.open(gpa, logp);
        defer st.close();
        try st.link("a", "refines", "b", 0.25, "session-1", 100);
        try st.link("a", "refines", "c", 1.0, "", 200);
        try st.link("a", "depends-on", "b", 0.5, "", 300);
        try st.link("x", "refines", "a", 1.0, "", 400);
        try t.expectEqual(@as(u64, 4), st.nlinks());
        try t.expectEqual(@as(u64, 2), st.npreds()); // refines, depends-on

        // dedup: same (s,p,o) updates weight/ts/src, count unchanged
        try st.link("a", "refines", "b", 0.9, "session-2", 500);
        try t.expectEqual(@as(u64, 4), st.nlinks());
        const l = st.links.items[0];
        try t.expectEqual(@as(f32, 0.9), l.w);
        try t.expectEqual(@as(u64, 500), l.ts);
        try t.expectEqualStrings("session-2", l.src);
        try t.expectEqualStrings("refines", st.predName(l.pid));

        // adjacency: subject "a" has exactly 3 outgoing links
        try t.expectEqual(@as(usize, 3), st.adj.get("a").?.items.len);
        try t.expectEqual(@as(usize, 1), st.adj.get("x").?.items.len);
    }

    // replay must rebuild weights, sources, intern table, adjacency
    {
        var st = try Store.open(gpa, logp);
        defer st.close();
        try t.expectEqual(@as(u64, 4), st.nlinks());
        try t.expectEqual(@as(u64, 2), st.npreds());
        const l = st.links.items[0];
        try t.expectEqual(@as(f32, 0.9), l.w);
        try t.expectEqualStrings("session-2", l.src);
        try t.expectEqual(@as(usize, 3), st.adj.get("a").?.items.len);
    }
}

test "store rejects put without key" {
    const gpa = std.heap.c_allocator;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var logbuf: [512]u8 = undefined;
    const logp = try std.fmt.bufPrintZ(&logbuf, ".zig-cache/tmp/{s}/memory.log", .{tmp.sub_path});

    var st = try Store.open(gpa, logp);
    defer st.close();

    var pl: std.ArrayList(u8) = .empty;
    defer pl.deinit(gpa);
    try wire.tlv(&pl, gpa, proto.T_BODY, "no key here");
    try t.expectError(error.BadPayload, st.put(pl.items));
}

test "store truncates corrupt log tail" {
    const gpa = std.heap.c_allocator;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var logbuf: [512]u8 = undefined;
    const logp = try std.fmt.bufPrintZ(&logbuf, ".zig-cache/tmp/{s}/memory.log", .{tmp.sub_path});

    {
        var st = try Store.open(gpa, logp);
        defer st.close();
        try putKey(&st, gpa, "keep/me", "survivor");
    }
    // append garbage — a torn write
    {
        const c = std.c;
        const fd = c.open(logp.ptr, .{ .ACCMODE = .WRONLY, .APPEND = true }, @as(c_int, 0));
        try t.expect(fd >= 0);
        defer _ = c.close(fd);
        try wire.writeFull(fd, &[_]u8{ 0xde, 0xad, 0xbe, 0xef, 0x01 });
    }
    {
        var st = try Store.open(gpa, logp);
        defer st.close();
        try t.expectEqual(@as(u64, 1), st.nkeys());
        const got = (try st.get(gpa, "keep/me")).?;
        defer gpa.free(got);
        try t.expectEqualStrings("survivor", (try wire.find(got, proto.T_BODY)).?);
    }
}
