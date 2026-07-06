#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include "proto.h"
#include "store.h"
#include "wire.h"

#define MAXC 64

typedef struct {
    int fd;
    buf_t in, out;
} conn_t;

static volatile sig_atomic_t g_stop;
static void on_sig(int s) { (void)s; g_stop = 1; }

static store_t *g_st;

static void respond(conn_t *c, uint8_t op, uint64_t rid, uint16_t status, const buf_t *pl) {
    uint8_t h[SLDB_HDR_SIZE];
    uint32_t n = pl ? (uint32_t)pl->len : 0;
    hdr_write(h, n, op, F_RESP, status, rid);
    buf_put(&c->out, h, sizeof h);
    if (n) buf_put(&c->out, pl->p, n);
}

static void list_cb(const char *key, uint8_t kind, uint64_t ts, void *ud) {
    buf_t *b = ud;
    buf_tlv_str(b, T_KEY, key);
    buf_tlv_u8(b, T_KIND, kind);
    buf_tlv_u64(b, T_TS, ts);
}

static void links_cb(const char *s, const char *p, const char *o, uint64_t ts, void *ud) {
    buf_t *b = ud;
    buf_tlv_str(b, T_SUBJ, s);
    buf_tlv_str(b, T_PRED, p);
    buf_tlv_str(b, T_OBJ, o);
    buf_tlv_u64(b, T_TS, ts);
}

static void dispatch(conn_t *c, uint8_t op, uint64_t rid, const uint8_t *pl, uint32_t n) {
    buf_t r;
    buf_init(&r);
    uint16_t st = ST_OK;
    char key[SLDB_KEY_MAX + 1];

    switch (op) {
    case OP_HELLO: {
        const uint8_t *v;
        uint32_t vl, ver = 0;
        if (tlv_find(pl, n, T_VERSION, &v, &vl) == 1 && vl == 4) ver = le32r(v);
        if (ver != SLDB_VERSION) st = ST_VERSION;
        buf_tlv_u32(&r, T_VERSION, SLDB_VERSION);
        break;
    }
    case OP_PING:
        break;
    case OP_PUT: {
        uint64_t ts;
        int rc;
        if (tlv_find_u64(pl, n, T_TS, &ts) == 1) {
            rc = store_put(g_st, pl, n);
        } else {
            buf_t p2;
            buf_init(&p2);
            if (buf_put(&p2, pl, n) || buf_tlv_u64(&p2, T_TS, now_ns()))
                rc = -1;
            else
                rc = store_put(g_st, p2.p, (uint32_t)p2.len);
            buf_free(&p2);
        }
        st = rc == 0 ? ST_OK : rc == -2 ? ST_BADREQ : ST_IO;
        break;
    }
    case OP_GET: {
        if (tlv_find_str(pl, n, T_KEY, key, sizeof key) != 1 || !key[0]) {
            st = ST_BADREQ;
            break;
        }
        uint8_t *v;
        uint32_t vl;
        int rc = store_get(g_st, key, &v, &vl);
        if (rc == 1) {
            buf_put(&r, v, vl);
            free(v);
        } else {
            st = rc == 0 ? ST_NOTFOUND : ST_IO;
        }
        break;
    }
    case OP_DEL: {
        if (tlv_find_str(pl, n, T_KEY, key, sizeof key) != 1 || !key[0]) {
            st = ST_BADREQ;
            break;
        }
        int rc = store_del(g_st, key);
        st = rc == 1 ? ST_OK : rc == 0 ? ST_NOTFOUND : ST_IO;
        break;
    }
    case OP_LIST: {
        char pfx[SLDB_KEY_MAX + 1] = "";
        if (tlv_find_str(pl, n, T_PREFIX, pfx, sizeof pfx) < 0) {
            st = ST_BADREQ;
            break;
        }
        store_iter_keys(g_st, pfx[0] ? pfx : NULL, list_cb, &r);
        break;
    }
    case OP_LINK: {
        char s[SLDB_KEY_MAX + 1], p[SLDB_KEY_MAX + 1], o[SLDB_KEY_MAX + 1];
        if (tlv_find_str(pl, n, T_SUBJ, s, sizeof s) != 1 ||
            tlv_find_str(pl, n, T_PRED, p, sizeof p) != 1 ||
            tlv_find_str(pl, n, T_OBJ, o, sizeof o) != 1 ||
            !s[0] || !p[0] || !o[0]) {
            st = ST_BADREQ;
            break;
        }
        if (store_link(g_st, s, p, o, now_ns())) st = ST_IO;
        break;
    }
    case OP_LINKS: {
        key[0] = 0;
        if (tlv_find_str(pl, n, T_KEY, key, sizeof key) < 0) {
            st = ST_BADREQ;
            break;
        }
        store_iter_links(g_st, key[0] ? key : NULL, links_cb, &r);
        break;
    }
    case OP_STATS:
        buf_tlv_u64(&r, T_NKEYS, store_nkeys(g_st));
        buf_tlv_u64(&r, T_NLINKS, store_nlinks(g_st));
        buf_tlv_u64(&r, T_BYTES, store_bytes(g_st));
        break;
    default:
        st = ST_BADREQ;
        buf_tlv_str(&r, T_MSG, "unknown op");
        break;
    }

    respond(c, op, rid, st, &r);
    buf_free(&r);
}

/* 0 = ok, -1 = close connection */
static int conn_process(conn_t *c) {
    for (;;) {
        if (c->in.len < SLDB_HDR_SIZE) return 0;
        uint32_t len;
        uint8_t op, fl;
        uint16_t st;
        uint64_t rid;
        hdr_read(c->in.p, &len, &op, &fl, &st, &rid);
        if (len > SLDB_MAX_PAYLOAD) return -1;
        if (c->in.len < SLDB_HDR_SIZE + (size_t)len) return 0;
        dispatch(c, op, rid, c->in.p + SLDB_HDR_SIZE, len);
        buf_consume(&c->in, SLDB_HDR_SIZE + len);
    }
}

static int conn_read(conn_t *c) {
    uint8_t tmp[65536];
    int eof = 0;
    for (;;) {
        ssize_t r = read(c->fd, tmp, sizeof tmp);
        if (r > 0) {
            if (buf_put(&c->in, tmp, (size_t)r)) return -1;
            if (r < (ssize_t)sizeof tmp) break;
            continue;
        }
        if (r == 0) {
            eof = 1;
            break;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK) break;
        if (errno == EINTR) continue;
        return -1;
    }
    if (conn_process(c)) return -1;
    return eof ? -1 : 0;
}

static int conn_flush(conn_t *c) {
    while (c->out.len) {
        ssize_t w = write(c->fd, c->out.p, c->out.len);
        if (w > 0) {
            buf_consume(&c->out, (size_t)w);
            continue;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
        if (errno == EINTR) continue;
        return -1;
    }
    return 0;
}

static void conn_close(conn_t *c) {
    conn_flush(c); /* best effort */
    close(c->fd);
    c->fd = -1;
    buf_free(&c->in);
    buf_free(&c->out);
}

int main(int argc, char **argv) {
    const char *dir = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-d") && i + 1 < argc) {
            dir = argv[++i];
        } else {
            fprintf(stderr, "usage: silicadbd [-d dir]\n");
            return 1;
        }
    }

    char home[512];
    if (dir) {
        snprintf(home, sizeof home, "%s", dir);
    } else {
        const char *env = getenv("SILICADB_HOME");
        if (env && *env) {
            snprintf(home, sizeof home, "%s", env);
        } else {
            const char *h = getenv("HOME");
            if (!h) {
                fprintf(stderr, "silicadbd: HOME unset\n");
                return 1;
            }
            snprintf(home, sizeof home, "%s/.silicadb", h);
        }
    }
    mkdir(home, 0700);

    char logp[600], sockp[600];
    snprintf(logp, sizeof logp, "%s/memory.log", home);
    snprintf(sockp, sizeof sockp, "%s/silicadb.sock", home);

    g_st = store_open(logp);
    if (!g_st) {
        fprintf(stderr, "silicadbd: cannot open %s: %s\n", logp, strerror(errno));
        return 1;
    }

    struct sockaddr_un sa;
    if (strlen(sockp) >= sizeof sa.sun_path) {
        fprintf(stderr, "silicadbd: socket path too long: %s\n", sockp);
        return 1;
    }
    int lfd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (lfd < 0) {
        perror("silicadbd: socket");
        return 1;
    }
    memset(&sa, 0, sizeof sa);
    sa.sun_family = AF_UNIX;
    strcpy(sa.sun_path, sockp);
    unlink(sockp);
    if (bind(lfd, (struct sockaddr *)&sa, sizeof sa) || listen(lfd, 64)) {
        perror("silicadbd: bind/listen");
        return 1;
    }
    fcntl(lfd, F_SETFL, O_NONBLOCK);

    signal(SIGPIPE, SIG_IGN);
    struct sigaction sact;
    memset(&sact, 0, sizeof sact);
    sact.sa_handler = on_sig;
    sigaction(SIGINT, &sact, NULL);
    sigaction(SIGTERM, &sact, NULL);

    fprintf(stderr, "silicadbd: %llu keys, %llu links; listening on %s\n",
            (unsigned long long)store_nkeys(g_st),
            (unsigned long long)store_nlinks(g_st), sockp);

    conn_t conns[MAXC];
    for (int i = 0; i < MAXC; i++) conns[i].fd = -1;

    while (!g_stop) {
        struct pollfd pf[MAXC + 1];
        int map[MAXC + 1], np = 0;
        pf[np].fd = lfd;
        pf[np].events = POLLIN;
        pf[np].revents = 0;
        np++;
        for (int i = 0; i < MAXC; i++) {
            if (conns[i].fd < 0) continue;
            pf[np].fd = conns[i].fd;
            pf[np].events = (short)(POLLIN | (conns[i].out.len ? POLLOUT : 0));
            pf[np].revents = 0;
            map[np] = i;
            np++;
        }
        if (poll(pf, (nfds_t)np, -1) < 0) {
            if (errno == EINTR) continue;
            perror("silicadbd: poll");
            break;
        }
        if (pf[0].revents & POLLIN) {
            for (;;) {
                int fd = accept(lfd, NULL, NULL);
                if (fd < 0) break;
                fcntl(fd, F_SETFL, O_NONBLOCK);
                int slot = -1;
                for (int i = 0; i < MAXC; i++)
                    if (conns[i].fd < 0) { slot = i; break; }
                if (slot < 0) {
                    close(fd);
                    continue;
                }
                conns[slot].fd = fd;
                buf_init(&conns[slot].in);
                buf_init(&conns[slot].out);
            }
        }
        for (int j = 1; j < np; j++) {
            conn_t *c = &conns[map[j]];
            if (c->fd < 0) continue;
            int dead = 0;
            if (pf[j].revents & (POLLERR | POLLNVAL)) dead = 1;
            if (!dead && (pf[j].revents & (POLLIN | POLLHUP))) dead = conn_read(c) < 0;
            if (!dead && c->out.len) dead = conn_flush(c) < 0;
            if (dead) conn_close(c);
        }
    }

    for (int i = 0; i < MAXC; i++)
        if (conns[i].fd >= 0) conn_close(&conns[i]);
    close(lfd);
    unlink(sockp);
    store_close(g_st);
    fprintf(stderr, "silicadbd: bye\n");
    return 0;
}
