//! Append-only log + in-memory index + link triples. Format: SPEC.md.

const std = @import("std");
const c = std.c;
const proto = @import("proto.zig");
const wire = @import("wire.zig");

const Allocator = std.mem.Allocator;

const LOG_MAGIC: u32 = 0x42444C53; // "SLDB" little-endian
const LOG_VERSION: u32 = 1;
const REC_HDR: usize = 9;

const R_PUT: u8 = 1;
const R_DEL: u8 = 2;
const R_LINK: u8 = 3;

pub const Slot = struct { off: u64, len: u32, kind: u8, ts: u64 };
pub const Link = struct { s: []u8, pid: u16, o: []u8, ts: u64, w: f32, src: []u8 };

pub const Store = struct {
    gpa: Allocator,
    fd: c.fd_t,
    end: u64,
    idx: std.StringHashMapUnmanaged(Slot) = .empty,
    links: std.ArrayList(Link) = .empty,
    // derived, rebuilt on replay: predicate intern table + per-subject adjacency
    preds: std.ArrayList([]u8) = .empty,
    pred_ids: std.StringHashMapUnmanaged(u16) = .empty,
    adj: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(u32)) = .empty,

    pub const Error = error{ Io, BadPayload, OutOfMemory };

    pub fn open(gpa: Allocator, path: [:0]const u8) Error!Store {
        const fd = c.open(path.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .APPEND = true }, @as(c_int, 0o600));
        if (fd < 0) return error.Io;
        var st = Store{ .gpa = gpa, .fd = fd, .end = 0 };
        errdefer st.close();

        const szr = c.lseek(fd, 0, c.SEEK.END);
        if (szr < 0) return error.Io;
        const sz: u64 = @intCast(szr);

        if (sz == 0) {
            var h: [8]u8 = undefined;
            std.mem.writeInt(u32, h[0..4], LOG_MAGIC, .little);
            std.mem.writeInt(u32, h[4..8], LOG_VERSION, .little);
            wire.writeFull(fd, &h) catch return error.Io;
            if (c.fsync(fd) != 0) return error.Io;
            st.end = 8;
            return st;
        }

        var h: [8]u8 = undefined;
        if (sz < 8 or c.pread(fd, &h, 8, 0) != 8 or
            std.mem.readInt(u32, h[0..4], .little) != LOG_MAGIC or
            std.mem.readInt(u32, h[4..8], .little) != LOG_VERSION)
        {
            warn("bad log header: {s}", .{path});
            return error.Io;
        }

        var off: u64 = 8;
        var buf: []u8 = &.{};
        defer gpa.free(buf);
        while (off + REC_HDR <= sz) {
            var rh: [REC_HDR]u8 = undefined;
            if (c.pread(fd, &rh, REC_HDR, @intCast(off)) != REC_HDR) break;
            const n = std.mem.readInt(u32, rh[0..4], .little);
            const crc = std.mem.readInt(u32, rh[4..8], .little);
            const rtype = rh[8];
            if (n > proto.MAX_PAYLOAD or off + REC_HDR + n > sz) break;
            if (n > buf.len) buf = try gpa.realloc(buf, n);
            const pl = buf[0..n];
            if (n > 0 and c.pread(fd, pl.ptr, n, @intCast(off + REC_HDR)) != n) break;
            if (wire.crcRecord(rtype, pl) != crc) break;
            st.apply(rtype, pl, off + REC_HDR) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => warn("skipping bad record at {d}", .{off}),
            };
            off += REC_HDR + n;
        }
        if (off < sz) {
            warn("truncating corrupt log tail at {d} (size was {d})", .{ off, sz });
            if (c.ftruncate(fd, @intCast(off)) != 0) return error.Io;
        }
        st.end = off;
        return st;
    }

    pub fn close(st: *Store) void {
        var it = st.idx.iterator();
        while (it.next()) |e| st.gpa.free(e.key_ptr.*);
        st.idx.deinit(st.gpa);
        for (st.links.items) |l| {
            st.gpa.free(l.s);
            st.gpa.free(l.o);
            st.gpa.free(l.src);
        }
        st.links.deinit(st.gpa);
        for (st.preds.items) |p| st.gpa.free(p);
        st.preds.deinit(st.gpa);
        st.pred_ids.deinit(st.gpa);
        var ait = st.adj.iterator();
        while (ait.next()) |e| {
            st.gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(st.gpa);
        }
        st.adj.deinit(st.gpa);
        _ = c.close(st.fd);
    }

    /// pl must contain T_KEY; stored verbatim.
    pub fn put(st: *Store, pl: []const u8) Error!void {
        const key = (wire.findStr(pl, proto.T_KEY, proto.KEY_MAX) catch return error.BadPayload) orelse
            return error.BadPayload;
        if (key.len == 0) return error.BadPayload;
        const kind = (wire.findU8(pl, proto.T_KIND) catch return error.BadPayload) orelse 0;
        const ts = (wire.findU64(pl, proto.T_TS) catch return error.BadPayload) orelse 0;
        const off = try st.append(R_PUT, pl);
        try st.idxSet(key, .{ .off = off, .len = @intCast(pl.len), .kind = kind, .ts = ts });
    }

    /// Returns stored payload (caller frees with gpa) or null if missing.
    pub fn get(st: *Store, gpa: Allocator, key: []const u8) Error!?[]u8 {
        const sl = st.idx.get(key) orelse return null;
        const b = try gpa.alloc(u8, sl.len);
        errdefer gpa.free(b);
        if (sl.len > 0 and c.pread(st.fd, b.ptr, sl.len, @intCast(sl.off)) != sl.len) return error.Io;
        return b;
    }

    /// true if deleted, false if missing.
    pub fn del(st: *Store, key: []const u8) Error!bool {
        if (!st.idx.contains(key)) return false;
        var b: std.ArrayList(u8) = .empty;
        defer b.deinit(st.gpa);
        try wire.tlv(&b, st.gpa, proto.T_KEY, key);
        _ = try st.append(R_DEL, b.items);
        if (st.idx.fetchRemove(key)) |kv| st.gpa.free(kv.key);
        return true;
    }

    pub fn link(st: *Store, s: []const u8, p: []const u8, o: []const u8, w: f32, src: []const u8, ts: u64) Error!void {
        var b: std.ArrayList(u8) = .empty;
        defer b.deinit(st.gpa);
        try wire.tlv(&b, st.gpa, proto.T_SUBJ, s);
        try wire.tlv(&b, st.gpa, proto.T_PRED, p);
        try wire.tlv(&b, st.gpa, proto.T_OBJ, o);
        try wire.tlvF32(&b, st.gpa, proto.T_WEIGHT, w);
        if (src.len > 0) try wire.tlv(&b, st.gpa, proto.T_SRC, src);
        try wire.tlvU64(&b, st.gpa, proto.T_TS, ts);
        _ = try st.append(R_LINK, b.items);
        try st.linksAdd(s, p, o, ts, w, src);
    }

    pub fn predName(st: *const Store, pid: u16) []const u8 {
        return st.preds.items[pid];
    }

    pub fn npreds(st: *Store) u64 {
        return st.preds.items.len;
    }

    pub fn nkeys(st: *Store) u64 {
        return st.idx.count();
    }

    pub fn nlinks(st: *Store) u64 {
        return st.links.items.len;
    }

    pub fn bytes(st: *Store) u64 {
        return st.end;
    }

    // ---- internals ----

    fn append(st: *Store, rtype: u8, pl: []const u8) Error!u64 {
        const total = REC_HDR + pl.len;
        const rec = try st.gpa.alloc(u8, total);
        defer st.gpa.free(rec);
        std.mem.writeInt(u32, rec[0..4], @intCast(pl.len), .little);
        std.mem.writeInt(u32, rec[4..8], wire.crcRecord(rtype, pl), .little);
        rec[8] = rtype;
        @memcpy(rec[REC_HDR..], pl);
        wire.writeFull(st.fd, rec) catch return error.Io;
        if (c.fsync(st.fd) != 0) return error.Io;
        const pay = st.end + REC_HDR;
        st.end += total;
        return pay;
    }

    fn idxSet(st: *Store, key: []const u8, slot: Slot) Error!void {
        if (st.idx.getPtr(key)) |v| {
            v.* = slot;
            return;
        }
        const k = try st.gpa.dupe(u8, key);
        errdefer st.gpa.free(k);
        try st.idx.put(st.gpa, k, slot);
    }

    fn predIntern(st: *Store, name: []const u8) Error!u16 {
        if (st.pred_ids.get(name)) |id| return id;
        if (st.preds.items.len > std.math.maxInt(u16)) return error.BadPayload;
        const d = try st.gpa.dupe(u8, name);
        errdefer st.gpa.free(d);
        const id: u16 = @intCast(st.preds.items.len);
        try st.preds.append(st.gpa, d);
        errdefer _ = st.preds.pop();
        try st.pred_ids.put(st.gpa, d, id);
        return id;
    }

    /// Dedup key is (subject, predicate, object); a repeat updates ts/w/src.
    fn linksAdd(st: *Store, s: []const u8, p: []const u8, o: []const u8, ts: u64, w: f32, src: []const u8) Error!void {
        const pid = try st.predIntern(p);
        if (st.adj.getPtr(s)) |bucket| {
            for (bucket.items) |li| {
                const l = &st.links.items[li];
                if (l.pid == pid and std.mem.eql(u8, l.o, o)) {
                    if (!std.mem.eql(u8, l.src, src)) {
                        const dsrc = try st.gpa.dupe(u8, src);
                        st.gpa.free(l.src);
                        l.src = dsrc;
                    }
                    l.ts = ts;
                    l.w = w;
                    return;
                }
            }
        }
        const ds = try st.gpa.dupe(u8, s);
        errdefer st.gpa.free(ds);
        const dobj = try st.gpa.dupe(u8, o);
        errdefer st.gpa.free(dobj);
        const dsrc = try st.gpa.dupe(u8, src);
        errdefer st.gpa.free(dsrc);
        const li: u32 = @intCast(st.links.items.len);
        try st.links.append(st.gpa, .{ .s = ds, .pid = pid, .o = dobj, .ts = ts, .w = w, .src = dsrc });
        errdefer _ = st.links.pop();
        const gop = try st.adj.getOrPut(st.gpa, s);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
            gop.key_ptr.* = st.gpa.dupe(u8, s) catch |e| {
                st.adj.removeByPtr(gop.key_ptr);
                return e;
            };
        }
        try gop.value_ptr.append(st.gpa, li);
    }

    fn apply(st: *Store, rtype: u8, pl: []const u8, off: u64) Error!void {
        switch (rtype) {
            R_PUT => {
                const key = (wire.findStr(pl, proto.T_KEY, proto.KEY_MAX) catch return error.BadPayload) orelse
                    return error.BadPayload;
                if (key.len == 0) return error.BadPayload;
                const kind = (wire.findU8(pl, proto.T_KIND) catch return error.BadPayload) orelse 0;
                const ts = (wire.findU64(pl, proto.T_TS) catch return error.BadPayload) orelse 0;
                try st.idxSet(key, .{ .off = off, .len = @intCast(pl.len), .kind = kind, .ts = ts });
            },
            R_DEL => {
                const key = (wire.findStr(pl, proto.T_KEY, proto.KEY_MAX) catch return error.BadPayload) orelse
                    return error.BadPayload;
                if (st.idx.fetchRemove(key)) |kv| st.gpa.free(kv.key);
            },
            R_LINK => {
                const s = (wire.findStr(pl, proto.T_SUBJ, proto.KEY_MAX) catch return error.BadPayload) orelse
                    return error.BadPayload;
                const p = (wire.findStr(pl, proto.T_PRED, proto.KEY_MAX) catch return error.BadPayload) orelse
                    return error.BadPayload;
                const o = (wire.findStr(pl, proto.T_OBJ, proto.KEY_MAX) catch return error.BadPayload) orelse
                    return error.BadPayload;
                const ts = (wire.findU64(pl, proto.T_TS) catch return error.BadPayload) orelse 0;
                const w = (wire.findF32(pl, proto.T_WEIGHT) catch return error.BadPayload) orelse 1.0;
                const src = (wire.findStr(pl, proto.T_SRC, proto.SRC_MAX) catch return error.BadPayload) orelse "";
                try st.linksAdd(s, p, o, ts, w, src);
            },
            else => return error.BadPayload,
        }
    }
};

fn warn(comptime fmt: []const u8, args: anytype) void {
    var b: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&b, "silicadb: " ++ fmt ++ "\n", args) catch return;
    wire.writeFull(2, s) catch {};
}
