#include <errno.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "proto.h"
#include "wire.h"

static uint64_t g_rid = 1;

static void die(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fputs("silica: ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
    exit(1);
}

static void usage(void) {
    fputs("usage: silica <command> [args]\n"
          "\n"
          "  ping                                  round-trip check\n"
          "  put <key> [-k kind] [-t tags] [body]  store record (no body: read stdin)\n"
          "  get <key> [-v]                        print body (-v: meta to stderr)\n"
          "  rm <key>                              delete record\n"
          "  ls [prefix]                           list keys\n"
          "  link <subj> <pred> <obj>              add semantic triple\n"
          "  links [key]                           list triples (touching key)\n"
          "  stats                                 store statistics\n"
          "\n"
          "kinds: note fact pref project ref (or 0-255)\n"
          "server: silicadbd   home: $SILICADB_HOME or ~/.silicadb\n",
          stderr);
    exit(1);
}

static void home_path(char *out, size_t cap, const char *leaf) {
    const char *env = getenv("SILICADB_HOME");
    if (env && *env) {
        snprintf(out, cap, "%s/%s", env, leaf);
        return;
    }
    const char *h = getenv("HOME");
    if (!h) die("HOME unset");
    snprintf(out, cap, "%s/.silicadb/%s", h, leaf);
}

static uint16_t call(int fd, uint8_t op, const buf_t *req, uint8_t **pl, uint32_t *pln) {
    uint64_t rid = g_rid++;
    if (wire_send(fd, op, 0, 0, rid, req ? req->p : NULL, req ? (uint32_t)req->len : 0))
        die("send failed: %s", strerror(errno));
    uint8_t rop, rfl;
    uint16_t st;
    uint64_t rrid;
    if (wire_recv(fd, &rop, &rfl, &st, &rrid, pl, pln))
        die("recv failed (server gone?)");
    if (!(rfl & F_RESP) || rop != op || rrid != rid) die("protocol error");
    return st;
}

static int cli_connect(void) {
    char path[512];
    home_path(path, sizeof path, "silicadb.sock");
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) die("socket: %s", strerror(errno));
    struct sockaddr_un sa;
    if (strlen(path) >= sizeof sa.sun_path) die("socket path too long: %s", path);
    memset(&sa, 0, sizeof sa);
    sa.sun_family = AF_UNIX;
    strcpy(sa.sun_path, path);
    if (connect(fd, (struct sockaddr *)&sa, sizeof sa))
        die("cannot connect to %s: %s\n        start the server: silicadbd &", path, strerror(errno));
    buf_t b;
    buf_init(&b);
    buf_tlv_u32(&b, T_VERSION, SLDB_VERSION);
    uint8_t *pl;
    uint32_t pln;
    uint16_t st = call(fd, OP_HELLO, &b, &pl, &pln);
    buf_free(&b);
    free(pl);
    if (st == ST_VERSION) die("protocol version mismatch (client v%u)", SLDB_VERSION);
    if (st != ST_OK) die("hello failed (status %u)", st);
    return fd;
}

static const char *st_str(uint16_t st) {
    switch (st) {
    case ST_OK:       return "ok";
    case ST_NOTFOUND: return "not found";
    case ST_BADREQ:   return "bad request";
    case ST_IO:       return "server i/o error";
    case ST_VERSION:  return "version mismatch";
    case ST_TOOBIG:   return "too big";
    default:          return "unknown error";
    }
}

static const char *kind_names[] = { "note", "fact", "pref", "project", "ref" };
#define NKINDS (sizeof kind_names / sizeof kind_names[0])

static int kind_parse(const char *s) {
    for (size_t i = 0; i < NKINDS; i++)
        if (!strcmp(s, kind_names[i])) return (int)i;
    char *end;
    long v = strtol(s, &end, 10);
    if (*end || end == s || v < 0 || v > 255) return -1;
    return (int)v;
}

static const char *kind_name(uint8_t k) {
    static char num[8];
    if (k < NKINDS) return kind_names[k];
    snprintf(num, sizeof num, "%u", k);
    return num;
}

static void fmt_ts(uint64_t ns, char *out, size_t cap) {
    if (!ns) {
        snprintf(out, cap, "-");
        return;
    }
    time_t t = (time_t)(ns / 1000000000ull);
    struct tm tm;
    localtime_r(&t, &tm);
    strftime(out, cap, "%Y-%m-%d %H:%M", &tm);
}

static uint8_t *read_stdin(uint32_t *n) {
    size_t cap = 65536, len = 0;
    uint8_t *b = malloc(cap);
    if (!b) die("out of memory");
    for (;;) {
        if (len == cap) {
            cap *= 2;
            if (cap > SLDB_MAX_PAYLOAD) die("body too big");
            uint8_t *nb = realloc(b, cap);
            if (!nb) die("out of memory");
            b = nb;
        }
        size_t r = fread(b + len, 1, cap - len, stdin);
        len += r;
        if (r == 0) {
            if (feof(stdin)) break;
            die("stdin read error");
        }
    }
    *n = (uint32_t)len;
    return b;
}

static int cmd_ping(int fd) {
    uint64_t t0 = now_ns();
    uint8_t *pl;
    uint32_t pln;
    uint16_t st = call(fd, OP_PING, NULL, &pl, &pln);
    uint64_t t1 = now_ns();
    free(pl);
    if (st != ST_OK) die("ping: %s", st_str(st));
    printf("pong (%llu us)\n", (unsigned long long)((t1 - t0) / 1000));
    return 0;
}

static int cmd_put(int fd, int argc, char **argv) {
    if (argc < 1) usage();
    const char *key = argv[0], *tags = NULL;
    int kind = K_NOTE, have_words = 0;
    buf_t body;
    buf_init(&body);
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-k") && i + 1 < argc) {
            kind = kind_parse(argv[++i]);
            if (kind < 0) die("bad kind: %s", argv[i]);
        } else if (!strcmp(argv[i], "-t") && i + 1 < argc) {
            tags = argv[++i];
        } else {
            if (have_words) buf_put(&body, " ", 1);
            buf_put(&body, argv[i], strlen(argv[i]));
            have_words = 1;
        }
    }
    buf_t req;
    buf_init(&req);
    buf_tlv_str(&req, T_KEY, key);
    buf_tlv_u8(&req, T_KIND, (uint8_t)kind);
    if (tags) buf_tlv_str(&req, T_TAGS, tags);
    buf_tlv_u64(&req, T_TS, now_ns());
    if (have_words) {
        buf_tlv(&req, T_BODY, body.p, (uint32_t)body.len);
    } else {
        uint32_t sn;
        uint8_t *sb = read_stdin(&sn);
        buf_tlv(&req, T_BODY, sb, sn);
        free(sb);
    }
    buf_free(&body);
    uint8_t *pl;
    uint32_t pln;
    uint16_t st = call(fd, OP_PUT, &req, &pl, &pln);
    buf_free(&req);
    free(pl);
    if (st != ST_OK) die("put %s: %s", key, st_str(st));
    return 0;
}

static int cmd_get(int fd, int argc, char **argv) {
    const char *key = NULL;
    int verbose = 0;
    for (int i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "-v")) verbose = 1;
        else if (!key) key = argv[i];
        else usage();
    }
    if (!key) usage();
    buf_t req;
    buf_init(&req);
    buf_tlv_str(&req, T_KEY, key);
    uint8_t *pl;
    uint32_t pln;
    uint16_t st = call(fd, OP_GET, &req, &pl, &pln);
    buf_free(&req);
    if (st == ST_NOTFOUND) {
        free(pl);
        fprintf(stderr, "silica: %s: not found\n", key);
        return 2;
    }
    if (st != ST_OK) die("get %s: %s", key, st_str(st));
    const uint8_t *b = NULL;
    uint32_t bn = 0;
    if (tlv_find(pl, pln, T_BODY, &b, &bn) == 1 && bn) {
        fwrite(b, 1, bn, stdout);
        if (isatty(1) && b[bn - 1] != '\n') fputc('\n', stdout);
    }
    if (verbose) {
        char tags[SLDB_TAGS_MAX + 1] = "", tsbuf[32];
        uint8_t kind = 0;
        uint64_t ts = 0;
        tlv_find_u8(pl, pln, T_KIND, &kind);
        tlv_find_u64(pl, pln, T_TS, &ts);
        tlv_find_str(pl, pln, T_TAGS, tags, sizeof tags);
        fmt_ts(ts, tsbuf, sizeof tsbuf);
        fprintf(stderr, "key: %s\nkind: %s\ntags: %s\nts: %s\nbytes: %u\n",
                key, kind_name(kind), tags, tsbuf, bn);
    }
    free(pl);
    return 0;
}

static int cmd_rm(int fd, int argc, char **argv) {
    if (argc != 1) usage();
    buf_t req;
    buf_init(&req);
    buf_tlv_str(&req, T_KEY, argv[0]);
    uint8_t *pl;
    uint32_t pln;
    uint16_t st = call(fd, OP_DEL, &req, &pl, &pln);
    buf_free(&req);
    free(pl);
    if (st == ST_NOTFOUND) {
        fprintf(stderr, "silica: %s: not found\n", argv[0]);
        return 2;
    }
    if (st != ST_OK) die("rm %s: %s", argv[0], st_str(st));
    return 0;
}

static int cmd_ls(int fd, int argc, char **argv) {
    if (argc > 1) usage();
    buf_t req;
    buf_init(&req);
    if (argc == 1) buf_tlv_str(&req, T_PREFIX, argv[0]);
    uint8_t *pl;
    uint32_t pln;
    uint16_t st = call(fd, OP_LIST, &req, &pl, &pln);
    buf_free(&req);
    if (st != ST_OK) die("ls: %s", st_str(st));
    cur_t c = { pl, pln, 0 };
    uint16_t tag;
    const uint8_t *v;
    uint32_t n;
    char key[SLDB_KEY_MAX + 1] = "", tsbuf[32];
    uint8_t kind = 0;
    while (tlv_next(&c, &tag, &v, &n) == 1) {
        if (tag == T_KEY && n <= SLDB_KEY_MAX) {
            memcpy(key, v, n);
            key[n] = 0;
        } else if (tag == T_KIND && n == 1) {
            kind = v[0];
        } else if (tag == T_TS && n == 8) {
            fmt_ts(le64r(v), tsbuf, sizeof tsbuf);
            printf("%-8s %-17s %s\n", kind_name(kind), tsbuf, key);
        }
    }
    free(pl);
    return 0;
}

static int cmd_link(int fd, int argc, char **argv) {
    if (argc != 3) usage();
    buf_t req;
    buf_init(&req);
    buf_tlv_str(&req, T_SUBJ, argv[0]);
    buf_tlv_str(&req, T_PRED, argv[1]);
    buf_tlv_str(&req, T_OBJ, argv[2]);
    uint8_t *pl;
    uint32_t pln;
    uint16_t st = call(fd, OP_LINK, &req, &pl, &pln);
    buf_free(&req);
    free(pl);
    if (st != ST_OK) die("link: %s", st_str(st));
    return 0;
}

static int cmd_links(int fd, int argc, char **argv) {
    if (argc > 1) usage();
    buf_t req;
    buf_init(&req);
    if (argc == 1) buf_tlv_str(&req, T_KEY, argv[0]);
    uint8_t *pl;
    uint32_t pln;
    uint16_t st = call(fd, OP_LINKS, &req, &pl, &pln);
    buf_free(&req);
    if (st != ST_OK) die("links: %s", st_str(st));
    cur_t c = { pl, pln, 0 };
    uint16_t tag;
    const uint8_t *v;
    uint32_t n;
    char s[SLDB_KEY_MAX + 1] = "", p[SLDB_KEY_MAX + 1] = "", o[SLDB_KEY_MAX + 1] = "", tsbuf[32];
    while (tlv_next(&c, &tag, &v, &n) == 1) {
        if (n > SLDB_KEY_MAX && tag != T_TS) continue;
        if (tag == T_SUBJ) {
            memcpy(s, v, n);
            s[n] = 0;
        } else if (tag == T_PRED) {
            memcpy(p, v, n);
            p[n] = 0;
        } else if (tag == T_OBJ) {
            memcpy(o, v, n);
            o[n] = 0;
        } else if (tag == T_TS && n == 8) {
            fmt_ts(le64r(v), tsbuf, sizeof tsbuf);
            printf("%s -[%s]-> %s  (%s)\n", s, p, o, tsbuf);
        }
    }
    free(pl);
    return 0;
}

static int cmd_stats(int fd) {
    uint8_t *pl;
    uint32_t pln;
    uint16_t st = call(fd, OP_STATS, NULL, &pl, &pln);
    if (st != ST_OK) die("stats: %s", st_str(st));
    uint64_t nk = 0, nl = 0, by = 0;
    tlv_find_u64(pl, pln, T_NKEYS, &nk);
    tlv_find_u64(pl, pln, T_NLINKS, &nl);
    tlv_find_u64(pl, pln, T_BYTES, &by);
    printf("keys: %llu\nlinks: %llu\nlog bytes: %llu\n",
           (unsigned long long)nk, (unsigned long long)nl, (unsigned long long)by);
    free(pl);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) usage();
    signal(SIGPIPE, SIG_IGN);
    const char *cmd = argv[1];
    if (!strcmp(cmd, "help") || !strcmp(cmd, "-h") || !strcmp(cmd, "--help")) usage();

    int fd = cli_connect();
    int rc;
    if (!strcmp(cmd, "ping"))       rc = cmd_ping(fd);
    else if (!strcmp(cmd, "put"))   rc = cmd_put(fd, argc - 2, argv + 2);
    else if (!strcmp(cmd, "get"))   rc = cmd_get(fd, argc - 2, argv + 2);
    else if (!strcmp(cmd, "rm"))    rc = cmd_rm(fd, argc - 2, argv + 2);
    else if (!strcmp(cmd, "ls"))    rc = cmd_ls(fd, argc - 2, argv + 2);
    else if (!strcmp(cmd, "link"))  rc = cmd_link(fd, argc - 2, argv + 2);
    else if (!strcmp(cmd, "links")) rc = cmd_links(fd, argc - 2, argv + 2);
    else if (!strcmp(cmd, "stats")) rc = cmd_stats(fd);
    else usage(), rc = 1;
    close(fd);
    return rc;
}
