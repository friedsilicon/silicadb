//! silica — CLI client for silicadbd.

const std = @import("std");
const c = std.c;
const proto = @import("proto.zig");
const wire = @import("wire.zig");
const load = @import("load.zig");

const gpa = std.heap.c_allocator;

var g_rid: u64 = 1;

extern "c" fn localtime_r(timer: *const i64, result: *Tm) ?*Tm;
const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};

fn outPrint(comptime fmt: []const u8, args: anytype) void {
    var b: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&b, fmt, args) catch return;
    wire.writeFull(1, s) catch {};
}

fn errPrint(comptime fmt: []const u8, args: anytype) void {
    var b: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&b, fmt, args) catch return;
    wire.writeFull(2, s) catch {};
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    errPrint("silica: " ++ fmt ++ "\n", args);
    c.exit(1);
}

fn usage() noreturn {
    errPrint(
        \\usage: silica <command> [args]
        \\
        \\  ping                                  round-trip check
        \\  put <key> [-k kind] [-t tags] [-s src] [body]
        \\                                        store record (no body: read stdin)
        \\  get <key> [-v] [-a ts]                print body (-v: meta; -a: as-of unix s|ns)
        \\  rm <key>                              delete record
        \\  ls [prefix]                           list keys
        \\  link <subj> <pred> <obj> [-w weight] [-s src]
        \\                                        add semantic triple (weight: f32, default 1)
        \\  links [key] [-p pred[,pred]]          list triples (touching key; -p: filter)
        \\  load                                  bulk ingest TSV lines from stdin (SPEC.md)
        \\  stats                                 store statistics
        \\
        \\kinds: note fact pref project ref (or 0-255)
        \\server: silicadbd   home: $SILICADB_HOME or ~/.silicadb
        \\
    , .{});
    c.exit(1);
}

fn getenvSlice(name: [*:0]const u8) ?[]const u8 {
    const v = c.getenv(name) orelse return null;
    return std.mem.span(v);
}

fn stStr(st: u16) []const u8 {
    return switch (st) {
        proto.ST_OK => "ok",
        proto.ST_NOTFOUND => "not found",
        proto.ST_BADREQ => "bad request",
        proto.ST_IO => "server i/o error",
        proto.ST_VERSION => "version mismatch",
        proto.ST_TOOBIG => "too big",
        else => "unknown error",
    };
}

const kindParse = load.kindParse;

fn kindName(k: u8, buf: []u8) []const u8 {
    if (k < load.kind_names.len) return load.kind_names[k];
    return std.fmt.bufPrint(buf, "{d}", .{k}) catch "?";
}

/// as-of argument: unix seconds or nanoseconds (values < 1e11 read as s).
fn asofParse(s: []const u8) ?u64 {
    const v = std.fmt.parseInt(u64, s, 10) catch return null;
    return if (v < 100_000_000_000) v * 1_000_000_000 else v;
}

fn fmtTs(ns: u64, buf: []u8) []const u8 {
    if (ns == 0) return "-";
    const t: i64 = @intCast(ns / 1_000_000_000);
    var tm: Tm = undefined;
    if (localtime_r(&t, &tm) == null) return "-";
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        @as(u32, @intCast(tm.year + 1900)),
        @as(u32, @intCast(tm.mon + 1)),
        @as(u32, @intCast(tm.mday)),
        @as(u32, @intCast(tm.hour)),
        @as(u32, @intCast(tm.min)),
    }) catch "-";
}

fn call(fd: c.fd_t, op: u8, req: []const u8) struct { st: u16, pl: []u8 } {
    const rid = g_rid;
    g_rid += 1;
    wire.send(fd, op, 0, 0, rid, req) catch die("send failed", .{});
    const f = wire.recv(fd, gpa) catch die("recv failed (server gone?)", .{});
    if (f.hdr.flags & proto.F_RESP == 0 or f.hdr.op != op or f.hdr.rid != rid)
        die("protocol error", .{});
    return .{ .st = f.hdr.status, .pl = f.pl };
}

fn cliConnect() c.fd_t {
    var pathbuf: [512]u8 = undefined;
    const path = blk: {
        if (getenvSlice("SILICADB_HOME")) |h| {
            break :blk std.fmt.bufPrintZ(&pathbuf, "{s}/silicadb.sock", .{h}) catch die("path too long", .{});
        }
        const h = getenvSlice("HOME") orelse die("HOME unset", .{});
        break :blk std.fmt.bufPrintZ(&pathbuf, "{s}/.silicadb/silicadb.sock", .{h}) catch die("path too long", .{});
    };

    const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (fd < 0) die("socket failed", .{});
    var sa: c.sockaddr.un = .{ .path = @splat(0) };
    if (path.len >= sa.path.len) die("socket path too long: {s}", .{path});
    @memcpy(sa.path[0..path.len], path);
    if (c.connect(fd, @ptrCast(&sa), @sizeOf(c.sockaddr.un)) != 0)
        die("cannot connect to {s}\n        start the server: silicadbd &", .{path});

    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    wire.tlvU32(&b, gpa, proto.T_VERSION, proto.VERSION) catch die("oom", .{});
    const r = call(fd, proto.OP_HELLO, b.items);
    defer gpa.free(r.pl);
    if (r.st == proto.ST_VERSION) die("protocol version mismatch (client v{d})", .{proto.VERSION});
    if (r.st != proto.ST_OK) die("hello failed: {s}", .{stStr(r.st)});
    return fd;
}

fn readStdin() []u8 {
    var b: std.ArrayList(u8) = .empty;
    var tmp: [65536]u8 = undefined;
    while (true) {
        const r = c.read(0, &tmp, tmp.len);
        if (r > 0) {
            if (b.items.len + @as(usize, @intCast(r)) > proto.MAX_PAYLOAD - 4096) die("body too big", .{});
            b.appendSlice(gpa, tmp[0..@intCast(r)]) catch die("oom", .{});
            continue;
        }
        if (r == 0) break;
        if (c.errno(r) == .INTR) continue;
        die("stdin read error", .{});
    }
    return b.items;
}

fn cmdPing(fd: c.fd_t) u8 {
    const t0 = wire.nowNs();
    const r = call(fd, proto.OP_PING, &.{});
    const t1 = wire.nowNs();
    gpa.free(r.pl);
    if (r.st != proto.ST_OK) die("ping: {s}", .{stStr(r.st)});
    outPrint("pong ({d} us)\n", .{(t1 - t0) / 1000});
    return 0;
}

fn cmdPut(fd: c.fd_t, args: []const []const u8) u8 {
    if (args.len < 1) usage();
    const key = args[0];
    var kind: u8 = proto.K_NOTE;
    var tags: ?[]const u8 = null;
    var src: ?[]const u8 = null;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    var have_words = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-k") and i + 1 < args.len) {
            i += 1;
            kind = kindParse(args[i]) orelse die("bad kind: {s}", .{args[i]});
        } else if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            i += 1;
            tags = args[i];
        } else if (std.mem.eql(u8, args[i], "-s") and i + 1 < args.len) {
            i += 1;
            src = args[i];
        } else {
            if (have_words) body.append(gpa, ' ') catch die("oom", .{});
            body.appendSlice(gpa, args[i]) catch die("oom", .{});
            have_words = true;
        }
    }

    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(gpa);
    wire.tlv(&req, gpa, proto.T_KEY, key) catch die("oom", .{});
    wire.tlvU8(&req, gpa, proto.T_KIND, kind) catch die("oom", .{});
    if (tags) |t| wire.tlv(&req, gpa, proto.T_TAGS, t) catch die("oom", .{});
    if (src) |s| wire.tlv(&req, gpa, proto.T_SRC, s) catch die("oom", .{});
    wire.tlvU64(&req, gpa, proto.T_TS, wire.nowNs()) catch die("oom", .{});
    if (have_words) {
        wire.tlv(&req, gpa, proto.T_BODY, body.items) catch die("oom", .{});
    } else {
        const sb = readStdin();
        defer gpa.free(sb);
        wire.tlv(&req, gpa, proto.T_BODY, sb) catch die("oom", .{});
    }

    const r = call(fd, proto.OP_PUT, req.items);
    gpa.free(r.pl);
    if (r.st != proto.ST_OK) die("put {s}: {s}", .{ key, stStr(r.st) });
    return 0;
}

fn cmdGet(fd: c.fd_t, args: []const []const u8) u8 {
    var key: ?[]const u8 = null;
    var verbose = false;
    var asof: ?u64 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, a, "-a") and i + 1 < args.len) {
            i += 1;
            asof = asofParse(args[i]) orelse die("bad as-of timestamp: {s}", .{args[i]});
        } else if (key == null) {
            key = a;
        } else usage();
    }
    const k = key orelse usage();

    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(gpa);
    wire.tlv(&req, gpa, proto.T_KEY, k) catch die("oom", .{});
    if (asof) |ts| wire.tlvU64(&req, gpa, proto.T_ASOF, ts) catch die("oom", .{});
    const r = call(fd, proto.OP_GET, req.items);
    defer gpa.free(r.pl);
    if (r.st == proto.ST_NOTFOUND) {
        errPrint("silica: {s}: not found\n", .{k});
        return 2;
    }
    if (r.st != proto.ST_OK) die("get {s}: {s}", .{ k, stStr(r.st) });

    var body_len: usize = 0;
    if (wire.find(r.pl, proto.T_BODY) catch null) |b| {
        body_len = b.len;
        if (b.len > 0) {
            wire.writeFull(1, b) catch {};
            if (c.isatty(1) != 0 and b[b.len - 1] != '\n') wire.writeFull(1, "\n") catch {};
        }
    }
    if (verbose) {
        const kind = (wire.findU8(r.pl, proto.T_KIND) catch null) orelse 0;
        const ts = (wire.findU64(r.pl, proto.T_TS) catch null) orelse 0;
        const tags = (wire.findStr(r.pl, proto.T_TAGS, proto.TAGS_MAX) catch null) orelse "";
        var kb: [8]u8 = undefined;
        var tb: [32]u8 = undefined;
        errPrint("key: {s}\nkind: {s}\ntags: {s}\nts: {s}\nbytes: {d}\n", .{
            k, kindName(kind, &kb), tags, fmtTs(ts, &tb), body_len,
        });
    }
    return 0;
}

fn cmdRm(fd: c.fd_t, args: []const []const u8) u8 {
    if (args.len != 1) usage();
    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(gpa);
    wire.tlv(&req, gpa, proto.T_KEY, args[0]) catch die("oom", .{});
    const r = call(fd, proto.OP_DEL, req.items);
    gpa.free(r.pl);
    if (r.st == proto.ST_NOTFOUND) {
        errPrint("silica: {s}: not found\n", .{args[0]});
        return 2;
    }
    if (r.st != proto.ST_OK) die("rm {s}: {s}", .{ args[0], stStr(r.st) });
    return 0;
}

fn cmdLs(fd: c.fd_t, args: []const []const u8) u8 {
    if (args.len > 1) usage();
    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(gpa);
    if (args.len == 1) wire.tlv(&req, gpa, proto.T_PREFIX, args[0]) catch die("oom", .{});
    const r = call(fd, proto.OP_LIST, req.items);
    defer gpa.free(r.pl);
    if (r.st != proto.ST_OK) die("ls: {s}", .{stStr(r.st)});

    var cur = wire.Cur{ .p = r.pl };
    var key: []const u8 = "";
    var kind: u8 = 0;
    while (cur.next() catch die("bad response", .{})) |t| {
        if (t.tag == proto.T_KEY) {
            key = t.val;
        } else if (t.tag == proto.T_KIND and t.val.len == 1) {
            kind = t.val[0];
        } else if (t.tag == proto.T_TS and t.val.len == 8) {
            var kb: [8]u8 = undefined;
            var tb: [32]u8 = undefined;
            const ts = std.mem.readInt(u64, t.val[0..8], .little);
            outPrint("{s:<8} {s:<17} {s}\n", .{ kindName(kind, &kb), fmtTs(ts, &tb), key });
        }
    }
    return 0;
}

fn cmdLink(fd: c.fd_t, args: []const []const u8) u8 {
    var pos: [3][]const u8 = undefined;
    var npos: usize = 0;
    var weight: f32 = 1.0;
    var src: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-w") and i + 1 < args.len) {
            i += 1;
            weight = std.fmt.parseFloat(f32, args[i]) catch die("bad weight: {s}", .{args[i]});
            if (!std.math.isFinite(weight)) die("bad weight: {s}", .{args[i]});
        } else if (std.mem.eql(u8, args[i], "-s") and i + 1 < args.len) {
            i += 1;
            src = args[i];
        } else if (npos < 3) {
            pos[npos] = args[i];
            npos += 1;
        } else usage();
    }
    if (npos != 3) usage();
    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(gpa);
    wire.tlv(&req, gpa, proto.T_SUBJ, pos[0]) catch die("oom", .{});
    wire.tlv(&req, gpa, proto.T_PRED, pos[1]) catch die("oom", .{});
    wire.tlv(&req, gpa, proto.T_OBJ, pos[2]) catch die("oom", .{});
    wire.tlvF32(&req, gpa, proto.T_WEIGHT, weight) catch die("oom", .{});
    if (src) |s| wire.tlv(&req, gpa, proto.T_SRC, s) catch die("oom", .{});
    const r = call(fd, proto.OP_LINK, req.items);
    gpa.free(r.pl);
    if (r.st != proto.ST_OK) die("link: {s}", .{stStr(r.st)});
    return 0;
}

fn cmdLinks(fd: c.fd_t, args: []const []const u8) u8 {
    var key: ?[]const u8 = null;
    var preds: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-p") and i + 1 < args.len) {
            i += 1;
            preds = args[i];
        } else if (key == null) {
            key = args[i];
        } else usage();
    }
    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(gpa);
    if (key) |k| wire.tlv(&req, gpa, proto.T_KEY, k) catch die("oom", .{});
    if (preds) |ps| {
        var it = std.mem.splitScalar(u8, ps, ',');
        while (it.next()) |p| {
            if (p.len > 0) wire.tlv(&req, gpa, proto.T_PRED, p) catch die("oom", .{});
        }
    }
    const r = call(fd, proto.OP_LINKS, req.items);
    defer gpa.free(r.pl);
    if (r.st != proto.ST_OK) die("links: {s}", .{stStr(r.st)});

    var cur = wire.Cur{ .p = r.pl };
    var s: []const u8 = "";
    var p: []const u8 = "";
    var o: []const u8 = "";
    var w: f32 = 1.0;
    var src: []const u8 = "";
    while (cur.next() catch die("bad response", .{})) |t| {
        if (t.tag == proto.T_SUBJ) {
            s = t.val;
        } else if (t.tag == proto.T_PRED) {
            p = t.val;
        } else if (t.tag == proto.T_OBJ) {
            o = t.val;
        } else if (t.tag == proto.T_WEIGHT and t.val.len == 4) {
            w = @bitCast(std.mem.readInt(u32, t.val[0..4], .little));
        } else if (t.tag == proto.T_SRC) {
            src = t.val;
        } else if (t.tag == proto.T_TS and t.val.len == 8) {
            var tb: [32]u8 = undefined;
            const ts = std.mem.readInt(u64, t.val[0..8], .little);
            if (src.len > 0) {
                outPrint("{s} -[{s}]-> {s}  w={d:.2}  src={s}  ({s})\n", .{ s, p, o, w, src, fmtTs(ts, &tb) });
            } else {
                outPrint("{s} -[{s}]-> {s}  w={d:.2}  ({s})\n", .{ s, p, o, w, fmtTs(ts, &tb) });
            }
            w = 1.0;
            src = "";
        }
    }
    return 0;
}

fn cmdLoad(fd: c.fd_t, args: []const []const u8) u8 {
    if (args.len != 0) usage();
    const input = readStdin();
    defer gpa.free(input);

    var nputs: u64 = 0;
    var nlinks: u64 = 0;
    var lineno: u64 = 0;
    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |raw| {
        lineno += 1;
        const parsed = (load.parseLine(raw) catch die("load: bad line {d}", .{lineno})) orelse continue;
        var req: std.ArrayList(u8) = .empty;
        defer req.deinit(gpa);
        switch (parsed) {
            .put => |p| {
                wire.tlv(&req, gpa, proto.T_KEY, p.key) catch die("oom", .{});
                wire.tlvU8(&req, gpa, proto.T_KIND, p.kind) catch die("oom", .{});
                if (p.tags.len > 0) wire.tlv(&req, gpa, proto.T_TAGS, p.tags) catch die("oom", .{});
                if (p.src.len > 0) wire.tlv(&req, gpa, proto.T_SRC, p.src) catch die("oom", .{});
                wire.tlvU64(&req, gpa, proto.T_TS, wire.nowNs()) catch die("oom", .{});
                wire.tlv(&req, gpa, proto.T_BODY, p.body) catch die("oom", .{});
                const r = call(fd, proto.OP_PUT, req.items);
                gpa.free(r.pl);
                if (r.st != proto.ST_OK) die("load: line {d}: put {s}: {s}", .{ lineno, p.key, stStr(r.st) });
                nputs += 1;
            },
            .link => |l| {
                wire.tlv(&req, gpa, proto.T_SUBJ, l.s) catch die("oom", .{});
                wire.tlv(&req, gpa, proto.T_PRED, l.p) catch die("oom", .{});
                wire.tlv(&req, gpa, proto.T_OBJ, l.o) catch die("oom", .{});
                wire.tlvF32(&req, gpa, proto.T_WEIGHT, l.w) catch die("oom", .{});
                if (l.src.len > 0) wire.tlv(&req, gpa, proto.T_SRC, l.src) catch die("oom", .{});
                const r = call(fd, proto.OP_LINK, req.items);
                gpa.free(r.pl);
                if (r.st != proto.ST_OK) die("load: line {d}: link: {s}", .{ lineno, stStr(r.st) });
                nlinks += 1;
            },
        }
    }
    outPrint("loaded {d} records, {d} links\n", .{ nputs, nlinks });
    return 0;
}

fn cmdStats(fd: c.fd_t) u8 {
    const r = call(fd, proto.OP_STATS, &.{});
    defer gpa.free(r.pl);
    if (r.st != proto.ST_OK) die("stats: {s}", .{stStr(r.st)});
    const nk = (wire.findU64(r.pl, proto.T_NKEYS) catch null) orelse 0;
    const nl = (wire.findU64(r.pl, proto.T_NLINKS) catch null) orelse 0;
    const by = (wire.findU64(r.pl, proto.T_BYTES) catch null) orelse 0;
    outPrint("keys: {d}\nlinks: {d}\nlog bytes: {d}\n", .{ nk, nl, by });
    return 0;
}

pub export fn main(argc: c_int, argv: [*][*:0]u8) c_int {
    const n: usize = @intCast(argc);
    if (n < 2) usage();

    var argbuf: [64][]const u8 = undefined;
    if (n > argbuf.len) die("too many arguments", .{});
    for (0..n) |i| argbuf[i] = std.mem.span(argv[i]);
    const cmd = argbuf[1];
    const rest = argbuf[2..n];

    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help"))
        usage();

    const fd = cliConnect();
    defer _ = c.close(fd);

    if (std.mem.eql(u8, cmd, "ping")) return cmdPing(fd);
    if (std.mem.eql(u8, cmd, "put")) return cmdPut(fd, rest);
    if (std.mem.eql(u8, cmd, "get")) return cmdGet(fd, rest);
    if (std.mem.eql(u8, cmd, "rm")) return cmdRm(fd, rest);
    if (std.mem.eql(u8, cmd, "ls")) return cmdLs(fd, rest);
    if (std.mem.eql(u8, cmd, "link")) return cmdLink(fd, rest);
    if (std.mem.eql(u8, cmd, "links")) return cmdLinks(fd, rest);
    if (std.mem.eql(u8, cmd, "load")) return cmdLoad(fd, rest);
    if (std.mem.eql(u8, cmd, "stats")) return cmdStats(fd);
    usage();
}
