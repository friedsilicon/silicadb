//! Framing, TLV encode/decode, blocking frame i/o, crc32, clock.

const std = @import("std");
const c = std.c;
const proto = @import("proto.zig");

const Allocator = std.mem.Allocator;

pub const Hdr = struct {
    len: u32,
    op: u8,
    flags: u8,
    status: u16,
    rid: u64,
};

pub fn hdrWrite(h: *[proto.HDR_SIZE]u8, hdr: Hdr) void {
    std.mem.writeInt(u32, h[0..4], hdr.len, .little);
    h[4] = hdr.op;
    h[5] = hdr.flags;
    std.mem.writeInt(u16, h[6..8], hdr.status, .little);
    std.mem.writeInt(u64, h[8..16], hdr.rid, .little);
}

pub fn hdrRead(h: *const [proto.HDR_SIZE]u8) Hdr {
    return .{
        .len = std.mem.readInt(u32, h[0..4], .little),
        .op = h[4],
        .flags = h[5],
        .status = std.mem.readInt(u16, h[6..8], .little),
        .rid = std.mem.readInt(u64, h[8..16], .little),
    };
}

// ---- TLV encode ----

pub fn tlv(b: *std.ArrayList(u8), gpa: Allocator, tag: u16, v: []const u8) Allocator.Error!void {
    var h: [6]u8 = undefined;
    std.mem.writeInt(u16, h[0..2], tag, .little);
    std.mem.writeInt(u32, h[2..6], @intCast(v.len), .little);
    try b.appendSlice(gpa, &h);
    try b.appendSlice(gpa, v);
}

pub fn tlvU8(b: *std.ArrayList(u8), gpa: Allocator, tag: u16, v: u8) Allocator.Error!void {
    try tlv(b, gpa, tag, &.{v});
}

pub fn tlvU32(b: *std.ArrayList(u8), gpa: Allocator, tag: u16, v: u32) Allocator.Error!void {
    var t: [4]u8 = undefined;
    std.mem.writeInt(u32, &t, v, .little);
    try tlv(b, gpa, tag, &t);
}

pub fn tlvU64(b: *std.ArrayList(u8), gpa: Allocator, tag: u16, v: u64) Allocator.Error!void {
    var t: [8]u8 = undefined;
    std.mem.writeInt(u64, &t, v, .little);
    try tlv(b, gpa, tag, &t);
}

// ---- TLV decode ----

pub const Tlv = struct { tag: u16, val: []const u8 };

pub const Cur = struct {
    p: []const u8,
    off: usize = 0,

    pub fn next(self: *Cur) error{Malformed}!?Tlv {
        if (self.off == self.p.len) return null;
        if (self.p.len - self.off < 6) return error.Malformed;
        const tag = std.mem.readInt(u16, self.p[self.off..][0..2], .little);
        const l = std.mem.readInt(u32, self.p[self.off + 2 ..][0..4], .little);
        self.off += 6;
        if (self.p.len - self.off < l) return error.Malformed;
        const v = self.p[self.off..][0..l];
        self.off += l;
        return .{ .tag = tag, .val = v };
    }
};

pub fn find(pl: []const u8, tag: u16) error{Malformed}!?[]const u8 {
    var cur = Cur{ .p = pl };
    while (try cur.next()) |t| {
        if (t.tag == tag) return t.val;
    }
    return null;
}

/// String value: bounded, no embedded NUL. Returns slice into pl.
pub fn findStr(pl: []const u8, tag: u16, max: usize) error{Malformed}!?[]const u8 {
    const v = (try find(pl, tag)) orelse return null;
    if (v.len > max or std.mem.indexOfScalar(u8, v, 0) != null) return error.Malformed;
    return v;
}

pub fn findU8(pl: []const u8, tag: u16) error{Malformed}!?u8 {
    const v = (try find(pl, tag)) orelse return null;
    if (v.len != 1) return error.Malformed;
    return v[0];
}

pub fn findU64(pl: []const u8, tag: u16) error{Malformed}!?u64 {
    const v = (try find(pl, tag)) orelse return null;
    if (v.len != 8) return error.Malformed;
    return std.mem.readInt(u64, v[0..8], .little);
}

// ---- fd i/o ----

pub const IoError = error{ Io, Closed };

pub fn readFull(fd: c.fd_t, buf: []u8) IoError!void {
    var b = buf;
    while (b.len > 0) {
        const r = c.read(fd, b.ptr, b.len);
        if (r > 0) {
            b = b[@intCast(r)..];
            continue;
        }
        if (r == 0) return error.Closed;
        if (c.errno(r) == .INTR) continue;
        return error.Io;
    }
}

pub fn writeFull(fd: c.fd_t, buf: []const u8) IoError!void {
    var b = buf;
    while (b.len > 0) {
        const w = c.write(fd, b.ptr, b.len);
        if (w > 0) {
            b = b[@intCast(w)..];
            continue;
        }
        if (w < 0 and c.errno(w) == .INTR) continue;
        return error.Io;
    }
}

pub fn send(fd: c.fd_t, op: u8, flags: u8, status: u16, rid: u64, pl: []const u8) IoError!void {
    var h: [proto.HDR_SIZE]u8 = undefined;
    hdrWrite(&h, .{ .len = @intCast(pl.len), .op = op, .flags = flags, .status = status, .rid = rid });
    try writeFull(fd, &h);
    if (pl.len > 0) try writeFull(fd, pl);
}

pub const Frame = struct { hdr: Hdr, pl: []u8 };

pub fn recv(fd: c.fd_t, gpa: Allocator) (IoError || Allocator.Error)!Frame {
    var h: [proto.HDR_SIZE]u8 = undefined;
    try readFull(fd, &h);
    const hdr = hdrRead(&h);
    if (hdr.len > proto.MAX_PAYLOAD) return error.Io;
    const pl = try gpa.alloc(u8, hdr.len);
    errdefer gpa.free(pl);
    if (hdr.len > 0) try readFull(fd, pl);
    return .{ .hdr = hdr, .pl = pl };
}

// ---- misc ----

/// crc32 over record type byte ++ payload; identical to the C implementation
/// (standard IEEE reflected crc32), so logs are cross-readable.
pub fn crcRecord(rtype: u8, pl: []const u8) u32 {
    var h = std.hash.Crc32.init();
    h.update(&.{rtype});
    h.update(pl);
    return h.final();
}

pub fn nowNs() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.REALTIME, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}
