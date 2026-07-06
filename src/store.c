#include "store.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "proto.h"
#include "wire.h"

#define LOG_MAGIC   0x42444C53u /* "SLDB" little-endian */
#define LOG_VERSION 1u
#define REC_HDR     9u

enum { R_PUT = 1, R_DEL = 2, R_LINK = 3 };
enum { S_EMPTY = 0, S_USED = 1, S_TOMB = 2 };

typedef struct {
    char *key;
    uint64_t off; /* payload offset in log */
    uint32_t len; /* payload length */
    uint64_t ts;
    uint8_t kind;
    uint8_t state;
} slot_t;

typedef struct {
    char *s, *p, *o;
    uint64_t ts;
} link_t;

struct store {
    int fd;
    uint64_t end; /* log size */
    slot_t *slots;
    size_t cap, live, fill; /* fill = used + tombstones */
    link_t *links;
    size_t nlinks, caplinks;
};

static uint64_t fnv1a(const char *s) {
    uint64_t h = 1469598103934665603ull;
    while (*s) {
        h ^= (uint8_t)*s++;
        h *= 1099511628211ull;
    }
    return h;
}

static slot_t *idx_probe(store_t *st, const char *key, int forinsert) {
    size_t mask = st->cap - 1, i = fnv1a(key) & mask;
    slot_t *tomb = NULL;
    for (;;) {
        slot_t *sl = &st->slots[i];
        if (sl->state == S_EMPTY) return forinsert ? (tomb ? tomb : sl) : NULL;
        if (sl->state == S_TOMB) {
            if (forinsert && !tomb) tomb = sl;
        } else if (!strcmp(sl->key, key)) {
            return sl;
        }
        i = (i + 1) & mask;
    }
}

static int idx_grow(store_t *st) {
    size_t ncap = st->cap ? st->cap * 2 : 64;
    slot_t *ns = calloc(ncap, sizeof *ns);
    if (!ns) return -1;
    slot_t *old = st->slots;
    size_t ocap = st->cap;
    for (size_t i = 0; i < ocap; i++) {
        if (old[i].state != S_USED) continue;
        size_t mask = ncap - 1, j = fnv1a(old[i].key) & mask;
        while (ns[j].state == S_USED) j = (j + 1) & mask;
        ns[j] = old[i];
    }
    free(old);
    st->slots = ns;
    st->cap = ncap;
    st->fill = st->live;
    return 0;
}

static int idx_set(store_t *st, const char *key, uint64_t off, uint32_t len, uint8_t kind, uint64_t ts) {
    if (!st->cap || (st->fill + 1) * 10 > st->cap * 7)
        if (idx_grow(st)) return -1;
    slot_t *sl = idx_probe(st, key, 1);
    if (sl->state != S_USED) {
        char *k = strdup(key);
        if (!k) return -1;
        if (sl->state == S_EMPTY) st->fill++;
        sl->key = k;
        sl->state = S_USED;
        st->live++;
    }
    sl->off = off;
    sl->len = len;
    sl->kind = kind;
    sl->ts = ts;
    return 0;
}

static void idx_del(store_t *st, const char *key) {
    slot_t *sl = st->cap ? idx_probe(st, key, 0) : NULL;
    if (!sl) return;
    free(sl->key);
    sl->key = NULL;
    sl->state = S_TOMB;
    st->live--;
}

static int links_add(store_t *st, const char *s, const char *p, const char *o, uint64_t ts) {
    for (size_t i = 0; i < st->nlinks; i++) {
        link_t *l = &st->links[i];
        if (!strcmp(l->s, s) && !strcmp(l->p, p) && !strcmp(l->o, o)) {
            l->ts = ts;
            return 0;
        }
    }
    if (st->nlinks == st->caplinks) {
        size_t nc = st->caplinks ? st->caplinks * 2 : 16;
        link_t *nl = realloc(st->links, nc * sizeof *nl);
        if (!nl) return -1;
        st->links = nl;
        st->caplinks = nc;
    }
    link_t *l = &st->links[st->nlinks];
    l->s = strdup(s);
    l->p = strdup(p);
    l->o = strdup(o);
    l->ts = ts;
    if (!l->s || !l->p || !l->o) return -1;
    st->nlinks++;
    return 0;
}

static int apply(store_t *st, uint8_t type, const uint8_t *pl, uint32_t n, uint64_t off) {
    char key[SLDB_KEY_MAX + 1];
    switch (type) {
    case R_PUT: {
        if (tlv_find_str(pl, n, T_KEY, key, sizeof key) != 1 || !key[0]) return -1;
        uint8_t kind = 0;
        uint64_t ts = 0;
        tlv_find_u8(pl, n, T_KIND, &kind);
        tlv_find_u64(pl, n, T_TS, &ts);
        return idx_set(st, key, off, n, kind, ts);
    }
    case R_DEL:
        if (tlv_find_str(pl, n, T_KEY, key, sizeof key) != 1) return -1;
        idx_del(st, key);
        return 0;
    case R_LINK: {
        char s[SLDB_KEY_MAX + 1], p[SLDB_KEY_MAX + 1], o[SLDB_KEY_MAX + 1];
        uint64_t ts = 0;
        if (tlv_find_str(pl, n, T_SUBJ, s, sizeof s) != 1 ||
            tlv_find_str(pl, n, T_PRED, p, sizeof p) != 1 ||
            tlv_find_str(pl, n, T_OBJ, o, sizeof o) != 1)
            return -1;
        tlv_find_u64(pl, n, T_TS, &ts);
        return links_add(st, s, p, o, ts);
    }
    default:
        return -1;
    }
}

static int append(store_t *st, uint8_t type, const uint8_t *pl, uint32_t n, uint64_t *pay_off) {
    size_t total = REC_HDR + n;
    uint8_t *rec = malloc(total);
    if (!rec) return -1;
    le32w(rec, n);
    uint32_t crc = crc32_of(&type, 1, 0);
    crc = crc32_of(pl, n, crc);
    le32w(rec + 4, crc);
    rec[8] = type;
    memcpy(rec + REC_HDR, pl, n);
    int rc = write_full(st->fd, rec, total);
    free(rec);
    if (rc || fsync(st->fd)) return -1;
    if (pay_off) *pay_off = st->end + REC_HDR;
    st->end += total;
    return 0;
}

store_t *store_open(const char *path) {
    store_t *st = calloc(1, sizeof *st);
    if (!st) return NULL;
    st->fd = open(path, O_RDWR | O_CREAT | O_APPEND, 0600);
    if (st->fd < 0) {
        free(st);
        return NULL;
    }
    off_t sz = lseek(st->fd, 0, SEEK_END);
    if (sz == 0) {
        uint8_t h[8];
        le32w(h, LOG_MAGIC);
        le32w(h + 4, LOG_VERSION);
        if (write_full(st->fd, h, sizeof h) || fsync(st->fd)) goto fail;
        st->end = 8;
        return st;
    }
    uint8_t h[8];
    if (sz < 8 || pread(st->fd, h, 8, 0) != 8 ||
        le32r(h) != LOG_MAGIC || le32r(h + 4) != LOG_VERSION) {
        fprintf(stderr, "silicadb: %s: bad log header\n", path);
        goto fail;
    }
    uint64_t off = 8;
    uint8_t *buf = NULL;
    size_t bcap = 0;
    while (off + REC_HDR <= (uint64_t)sz) {
        uint8_t rh[REC_HDR];
        if (pread(st->fd, rh, REC_HDR, (off_t)off) != REC_HDR) break;
        uint32_t n = le32r(rh), crc = le32r(rh + 4);
        uint8_t type = rh[8];
        if (n > SLDB_MAX_PAYLOAD || off + REC_HDR + n > (uint64_t)sz) break;
        if (n > bcap) {
            uint8_t *nb = realloc(buf, n);
            if (!nb) {
                free(buf);
                goto fail;
            }
            buf = nb;
            bcap = n;
        }
        if (n && pread(st->fd, buf, n, (off_t)(off + REC_HDR)) != (ssize_t)n) break;
        uint32_t c = crc32_of(&type, 1, 0);
        c = crc32_of(buf, n, c);
        if (c != crc) break;
        if (apply(st, type, buf, n, off + REC_HDR))
            fprintf(stderr, "silicadb: skipping bad record at %llu\n", (unsigned long long)off);
        off += REC_HDR + n;
    }
    free(buf);
    if (off < (uint64_t)sz) {
        fprintf(stderr, "silicadb: truncating corrupt log tail at %llu (size was %lld)\n",
                (unsigned long long)off, (long long)sz);
        if (ftruncate(st->fd, (off_t)off)) goto fail;
    }
    st->end = off;
    return st;
fail:
    close(st->fd);
    free(st->slots);
    free(st);
    return NULL;
}

void store_close(store_t *st) {
    if (!st) return;
    for (size_t i = 0; i < st->cap; i++)
        if (st->slots[i].state == S_USED) free(st->slots[i].key);
    for (size_t i = 0; i < st->nlinks; i++) {
        free(st->links[i].s);
        free(st->links[i].p);
        free(st->links[i].o);
    }
    free(st->slots);
    free(st->links);
    close(st->fd);
    free(st);
}

int store_put(store_t *st, const uint8_t *pl, uint32_t n) {
    char key[SLDB_KEY_MAX + 1];
    if (tlv_find_str(pl, n, T_KEY, key, sizeof key) != 1 || !key[0]) return -2;
    uint8_t kind = 0;
    uint64_t ts = 0;
    tlv_find_u8(pl, n, T_KIND, &kind);
    tlv_find_u64(pl, n, T_TS, &ts);
    uint64_t off;
    if (append(st, R_PUT, pl, n, &off)) return -1;
    return idx_set(st, key, off, n, kind, ts) ? -1 : 0;
}

int store_get(store_t *st, const char *key, uint8_t **pl, uint32_t *n) {
    slot_t *sl = st->cap ? idx_probe(st, key, 0) : NULL;
    if (!sl) return 0;
    uint8_t *b = malloc(sl->len ? sl->len : 1);
    if (!b) return -1;
    if (sl->len && pread(st->fd, b, sl->len, (off_t)sl->off) != (ssize_t)sl->len) {
        free(b);
        return -1;
    }
    *pl = b;
    *n = sl->len;
    return 1;
}

int store_del(store_t *st, const char *key) {
    if (!(st->cap && idx_probe(st, key, 0))) return 0;
    buf_t b;
    buf_init(&b);
    int rc = buf_tlv_str(&b, T_KEY, key) || append(st, R_DEL, b.p, (uint32_t)b.len, NULL);
    buf_free(&b);
    if (rc) return -1;
    idx_del(st, key);
    return 1;
}

int store_link(store_t *st, const char *s, const char *p, const char *o, uint64_t ts) {
    buf_t b;
    buf_init(&b);
    int rc = buf_tlv_str(&b, T_SUBJ, s) || buf_tlv_str(&b, T_PRED, p) ||
             buf_tlv_str(&b, T_OBJ, o) || buf_tlv_u64(&b, T_TS, ts) ||
             append(st, R_LINK, b.p, (uint32_t)b.len, NULL);
    buf_free(&b);
    if (rc) return -1;
    return links_add(st, s, p, o, ts);
}

void store_iter_keys(store_t *st, const char *prefix, store_key_fn fn, void *ud) {
    size_t plen = prefix ? strlen(prefix) : 0;
    for (size_t i = 0; i < st->cap; i++) {
        slot_t *sl = &st->slots[i];
        if (sl->state != S_USED) continue;
        if (plen && strncmp(sl->key, prefix, plen)) continue;
        fn(sl->key, sl->kind, sl->ts, ud);
    }
}

void store_iter_links(store_t *st, const char *key, store_link_fn fn, void *ud) {
    for (size_t i = 0; i < st->nlinks; i++) {
        link_t *l = &st->links[i];
        if (key && strcmp(l->s, key) && strcmp(l->o, key)) continue;
        fn(l->s, l->p, l->o, l->ts, ud);
    }
}

uint64_t store_nkeys(store_t *st) { return st->live; }
uint64_t store_nlinks(store_t *st) { return st->nlinks; }
uint64_t store_bytes(store_t *st) { return st->end; }
