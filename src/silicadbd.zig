//! silicadbd — memory daemon. poll(2) loop over a unix stream socket.

const std = @import("std");
const c = std.c;
const proto = @import("proto.zig");
const wire = @import("wire.zig");
const store_mod = @import("store.zig");
const Store = store_mod.Store;

const gpa = std.heap.c_allocator;
const MAXC = 64;

extern "c" fn signal(sig: c_int, handler: ?*const fn (c_int) callconv(.c) void) ?*const fn (c_int) callconv(.c) void;
fn sigNop(_: c_int) callconv(.c) void {}
const SIGINT: c_int = 2;
const SIGPIPE: c_int = 13;
const SIGTERM: c_int = 15;

var g_stop: bool = false;
fn onSig(_: c_int) callconv(.c) void {
    g_stop = true;
}

var g_st: Store = undefined;

const Conn = struct {
    fd: c.fd_t = -1,
    in: std.ArrayList(u8) = .empty,
    out: std.ArrayList(u8) = .empty,
};

fn errPrint(comptime fmt: []const u8, args: anytype) void {
    var b: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&b, fmt, args) catch return;
    wire.writeFull(2, s) catch {};
}

fn respond(conn: *Conn, op: u8, rid: u64, status: u16, pl: []const u8) void {
    var h: [proto.HDR_SIZE]u8 = undefined;
    wire.hdrWrite(&h, .{ .len = @intCast(pl.len), .op = op, .flags = proto.F_RESP, .status = status, .rid = rid });
    conn.out.appendSlice(gpa, &h) catch {};
    conn.out.appendSlice(gpa, pl) catch {};
}

fn stFromErr(e: Store.Error) u16 {
    return switch (e) {
        error.BadPayload => proto.ST_BADREQ,
        error.Io, error.OutOfMemory => proto.ST_IO,
    };
}

fn dispatch(conn: *Conn, op: u8, rid: u64, pl: []const u8) void {
    var r: std.ArrayList(u8) = .empty;
    defer r.deinit(gpa);
    var status: u16 = proto.ST_OK;

    blk: {
        switch (op) {
            proto.OP_HELLO => {
                var ver: u32 = 0;
                if (wire.find(pl, proto.T_VERSION) catch null) |v| {
                    if (v.len == 4) ver = std.mem.readInt(u32, v[0..4], .little);
                }
                if (ver != proto.VERSION) status = proto.ST_VERSION;
                wire.tlvU32(&r, gpa, proto.T_VERSION, proto.VERSION) catch {};
            },
            proto.OP_PING => {},
            proto.OP_PUT => {
                const has_ts = wire.findU64(pl, proto.T_TS) catch {
                    status = proto.ST_BADREQ;
                    break :blk;
                };
                if (has_ts != null) {
                    g_st.put(pl) catch |e| {
                        status = stFromErr(e);
                    };
                } else {
                    var p2: std.ArrayList(u8) = .empty;
                    defer p2.deinit(gpa);
                    p2.appendSlice(gpa, pl) catch {
                        status = proto.ST_IO;
                        break :blk;
                    };
                    wire.tlvU64(&p2, gpa, proto.T_TS, wire.nowNs()) catch {
                        status = proto.ST_IO;
                        break :blk;
                    };
                    g_st.put(p2.items) catch |e| {
                        status = stFromErr(e);
                    };
                }
            },
            proto.OP_GET => {
                const key = (wire.findStr(pl, proto.T_KEY, proto.KEY_MAX) catch null) orelse {
                    status = proto.ST_BADREQ;
                    break :blk;
                };
                if (key.len == 0) {
                    status = proto.ST_BADREQ;
                    break :blk;
                }
                const stored = g_st.get(gpa, key) catch |e| {
                    status = stFromErr(e);
                    break :blk;
                };
                if (stored) |s| {
                    defer gpa.free(s);
                    r.appendSlice(gpa, s) catch {
                        status = proto.ST_IO;
                    };
                } else {
                    status = proto.ST_NOTFOUND;
                }
            },
            proto.OP_DEL => {
                const key = (wire.findStr(pl, proto.T_KEY, proto.KEY_MAX) catch null) orelse {
                    status = proto.ST_BADREQ;
                    break :blk;
                };
                if (key.len == 0) {
                    status = proto.ST_BADREQ;
                    break :blk;
                }
                const deleted = g_st.del(key) catch |e| {
                    status = stFromErr(e);
                    break :blk;
                };
                if (!deleted) status = proto.ST_NOTFOUND;
            },
            proto.OP_LIST => {
                const pfx = wire.findStr(pl, proto.T_PREFIX, proto.KEY_MAX) catch {
                    status = proto.ST_BADREQ;
                    break :blk;
                };
                var it = g_st.idx.iterator();
                while (it.next()) |e| {
                    const key = e.key_ptr.*;
                    if (pfx) |p| {
                        if (!std.mem.startsWith(u8, key, p)) continue;
                    }
                    wire.tlv(&r, gpa, proto.T_KEY, key) catch break;
                    wire.tlvU8(&r, gpa, proto.T_KIND, e.value_ptr.kind) catch break;
                    wire.tlvU64(&r, gpa, proto.T_TS, e.value_ptr.ts) catch break;
                }
            },
            proto.OP_LINK => {
                const s = (wire.findStr(pl, proto.T_SUBJ, proto.KEY_MAX) catch null) orelse "";
                const p = (wire.findStr(pl, proto.T_PRED, proto.KEY_MAX) catch null) orelse "";
                const o = (wire.findStr(pl, proto.T_OBJ, proto.KEY_MAX) catch null) orelse "";
                if (s.len == 0 or p.len == 0 or o.len == 0) {
                    status = proto.ST_BADREQ;
                    break :blk;
                }
                const w = (wire.findF32(pl, proto.T_WEIGHT) catch {
                    status = proto.ST_BADREQ;
                    break :blk;
                }) orelse 1.0;
                const src = (wire.findStr(pl, proto.T_SRC, proto.SRC_MAX) catch {
                    status = proto.ST_BADREQ;
                    break :blk;
                }) orelse "";
                g_st.link(s, p, o, w, src, wire.nowNs()) catch |e| {
                    status = stFromErr(e);
                };
            },
            proto.OP_LINKS => {
                const key = wire.findStr(pl, proto.T_KEY, proto.KEY_MAX) catch {
                    status = proto.ST_BADREQ;
                    break :blk;
                };
                for (g_st.links.items) |l| {
                    if (key) |k| {
                        if (!std.mem.eql(u8, l.s, k) and !std.mem.eql(u8, l.o, k)) continue;
                    }
                    wire.tlv(&r, gpa, proto.T_SUBJ, l.s) catch break;
                    wire.tlv(&r, gpa, proto.T_PRED, g_st.predName(l.pid)) catch break;
                    wire.tlv(&r, gpa, proto.T_OBJ, l.o) catch break;
                    wire.tlvF32(&r, gpa, proto.T_WEIGHT, l.w) catch break;
                    if (l.src.len > 0) wire.tlv(&r, gpa, proto.T_SRC, l.src) catch break;
                    wire.tlvU64(&r, gpa, proto.T_TS, l.ts) catch break;
                }
            },
            proto.OP_STATS => {
                wire.tlvU64(&r, gpa, proto.T_NKEYS, g_st.nkeys()) catch {};
                wire.tlvU64(&r, gpa, proto.T_NLINKS, g_st.nlinks()) catch {};
                wire.tlvU64(&r, gpa, proto.T_BYTES, g_st.bytes()) catch {};
            },
            else => {
                status = proto.ST_BADREQ;
                wire.tlv(&r, gpa, proto.T_MSG, "unknown op") catch {};
            },
        }
    }

    respond(conn, op, rid, status, r.items);
}

/// false = close connection
fn connProcess(conn: *Conn) bool {
    while (true) {
        if (conn.in.items.len < proto.HDR_SIZE) return true;
        const hdr = wire.hdrRead(conn.in.items[0..proto.HDR_SIZE]);
        if (hdr.len > proto.MAX_PAYLOAD) return false;
        const total = proto.HDR_SIZE + @as(usize, hdr.len);
        if (conn.in.items.len < total) return true;
        dispatch(conn, hdr.op, hdr.rid, conn.in.items[proto.HDR_SIZE..total]);
        std.mem.copyForwards(u8, conn.in.items[0 .. conn.in.items.len - total], conn.in.items[total..]);
        conn.in.items.len -= total;
    }
}

fn connRead(conn: *Conn) bool {
    var tmp: [65536]u8 = undefined;
    var eof = false;
    while (true) {
        const r = c.read(conn.fd, &tmp, tmp.len);
        if (r > 0) {
            conn.in.appendSlice(gpa, tmp[0..@intCast(r)]) catch return false;
            if (r < tmp.len) break;
            continue;
        }
        if (r == 0) {
            eof = true;
            break;
        }
        const e = c.errno(r);
        if (e == .AGAIN) break;
        if (e == .INTR) continue;
        return false;
    }
    if (!connProcess(conn)) return false;
    return !eof;
}

fn connFlush(conn: *Conn) bool {
    while (conn.out.items.len > 0) {
        const w = c.write(conn.fd, conn.out.items.ptr, conn.out.items.len);
        if (w > 0) {
            const n: usize = @intCast(w);
            std.mem.copyForwards(u8, conn.out.items[0 .. conn.out.items.len - n], conn.out.items[n..]);
            conn.out.items.len -= n;
            continue;
        }
        const e = c.errno(w);
        if (e == .AGAIN) return true;
        if (e == .INTR) continue;
        return false;
    }
    return true;
}

fn connClose(conn: *Conn) void {
    _ = connFlush(conn); // best effort
    _ = c.close(conn.fd);
    conn.fd = -1;
    conn.in.deinit(gpa);
    conn.out.deinit(gpa);
    conn.in = .empty;
    conn.out = .empty;
}

fn setNonblock(fd: c.fd_t) void {
    const nb: c_int = @intCast(@as(u32, @bitCast(c.O{ .NONBLOCK = true })));
    _ = c.fcntl(fd, c.F.SETFL, nb);
}

fn getenvSlice(name: [*:0]const u8) ?[]const u8 {
    const v = c.getenv(name) orelse return null;
    return std.mem.span(v);
}

pub export fn main(argc: c_int, argv: [*][*:0]u8) c_int {
    var dir: ?[]const u8 = null;
    var i: usize = 1;
    const n: usize = @intCast(argc);
    while (i < n) : (i += 1) {
        const a = std.mem.span(argv[i]);
        if (std.mem.eql(u8, a, "-d") and i + 1 < n) {
            i += 1;
            dir = std.mem.span(argv[i]);
        } else {
            errPrint("usage: silicadbd [-d dir]\n", .{});
            return 1;
        }
    }

    var homebuf: [512]u8 = undefined;
    const home: []const u8 = dir orelse getenvSlice("SILICADB_HOME") orelse blk: {
        const h = getenvSlice("HOME") orelse {
            errPrint("silicadbd: HOME unset\n", .{});
            return 1;
        };
        break :blk std.fmt.bufPrint(&homebuf, "{s}/.silicadb", .{h}) catch return 1;
    };

    var logbuf: [600]u8 = undefined;
    var sockbuf: [600]u8 = undefined;
    const logp = std.fmt.bufPrintZ(&logbuf, "{s}/memory.log", .{home}) catch return 1;
    const sockp = std.fmt.bufPrintZ(&sockbuf, "{s}/silicadb.sock", .{home}) catch return 1;

    var homez: [512]u8 = undefined;
    const homeZ = std.fmt.bufPrintZ(&homez, "{s}", .{home}) catch return 1;
    _ = c.mkdir(homeZ.ptr, 0o700);

    g_st = Store.open(gpa, logp) catch {
        errPrint("silicadbd: cannot open {s}\n", .{logp});
        return 1;
    };
    defer g_st.close();

    var sa: c.sockaddr.un = .{ .path = @splat(0) };
    if (sockp.len >= sa.path.len) {
        errPrint("silicadbd: socket path too long: {s}\n", .{sockp});
        return 1;
    }
    const lfd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (lfd < 0) {
        errPrint("silicadbd: socket failed\n", .{});
        return 1;
    }
    @memcpy(sa.path[0..sockp.len], sockp);
    _ = c.unlink(sockp.ptr);
    if (c.bind(lfd, @ptrCast(&sa), @sizeOf(c.sockaddr.un)) != 0 or c.listen(lfd, 64) != 0) {
        errPrint("silicadbd: bind/listen failed on {s}\n", .{sockp});
        return 1;
    }
    setNonblock(lfd);

    _ = signal(SIGPIPE, sigNop);
    _ = signal(SIGINT, onSig);
    _ = signal(SIGTERM, onSig);

    errPrint("silicadbd: {d} keys, {d} links; listening on {s}\n", .{ g_st.nkeys(), g_st.nlinks(), sockp });

    var conns: [MAXC]Conn = @splat(.{});

    while (!g_stop) {
        var pf: [MAXC + 1]c.pollfd = undefined;
        var map: [MAXC + 1]usize = undefined;
        var np: usize = 1;
        pf[0] = .{ .fd = lfd, .events = c.POLL.IN, .revents = 0 };
        for (&conns, 0..) |*conn, ci| {
            if (conn.fd < 0) continue;
            var ev: i16 = c.POLL.IN;
            if (conn.out.items.len > 0) ev |= c.POLL.OUT;
            pf[np] = .{ .fd = conn.fd, .events = ev, .revents = 0 };
            map[np] = ci;
            np += 1;
        }
        const pr = c.poll(&pf, @intCast(np), -1);
        if (pr < 0) {
            if (c.errno(pr) == .INTR) continue;
            errPrint("silicadbd: poll failed\n", .{});
            break;
        }
        if (pf[0].revents & c.POLL.IN != 0) {
            while (true) {
                const fd = c.accept(lfd, null, null);
                if (fd < 0) break;
                setNonblock(fd);
                var slot: ?usize = null;
                for (&conns, 0..) |*conn, ci| {
                    if (conn.fd < 0) {
                        slot = ci;
                        break;
                    }
                }
                if (slot) |sl| {
                    conns[sl] = .{ .fd = fd };
                } else {
                    _ = c.close(fd);
                }
            }
        }
        for (pf[1..np], map[1..np]) |*p, ci| {
            const conn = &conns[ci];
            if (conn.fd < 0) continue;
            var alive = true;
            if (p.revents & (c.POLL.ERR | c.POLL.NVAL) != 0) alive = false;
            if (alive and p.revents & (c.POLL.IN | c.POLL.HUP) != 0) alive = connRead(conn);
            if (alive and conn.out.items.len > 0) alive = connFlush(conn);
            if (!alive) connClose(conn);
        }
    }

    for (&conns) |*conn| {
        if (conn.fd >= 0) connClose(conn);
    }
    _ = c.close(lfd);
    _ = c.unlink(sockp.ptr);
    errPrint("silicadbd: bye\n", .{});
    return 0;
}
