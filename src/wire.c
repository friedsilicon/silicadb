#include "wire.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "proto.h"

void buf_init(buf_t *b) { b->p = NULL; b->len = b->cap = 0; }

void buf_free(buf_t *b) {
    free(b->p);
    b->p = NULL;
    b->len = b->cap = 0;
}

static int buf_reserve(buf_t *b, size_t need) {
    if (b->cap - b->len >= need) return 0;
    size_t nc = b->cap ? b->cap : 256;
    while (nc - b->len < need) nc *= 2;
    uint8_t *np = realloc(b->p, nc);
    if (!np) return -1;
    b->p = np;
    b->cap = nc;
    return 0;
}

int buf_put(buf_t *b, const void *src, size_t n) {
    if (buf_reserve(b, n)) return -1;
    memcpy(b->p + b->len, src, n);
    b->len += n;
    return 0;
}

void buf_consume(buf_t *b, size_t n) {
    memmove(b->p, b->p + n, b->len - n);
    b->len -= n;
}

int buf_tlv(buf_t *b, uint16_t tag, const void *v, uint32_t n) {
    uint8_t h[6];
    le16w(h, tag);
    le32w(h + 2, n);
    if (buf_put(b, h, sizeof h)) return -1;
    return n ? buf_put(b, v, n) : 0;
}

int buf_tlv_str(buf_t *b, uint16_t tag, const char *s) {
    return buf_tlv(b, tag, s, (uint32_t)strlen(s));
}

int buf_tlv_u8(buf_t *b, uint16_t tag, uint8_t v) { return buf_tlv(b, tag, &v, 1); }

int buf_tlv_u32(buf_t *b, uint16_t tag, uint32_t v) {
    uint8_t t[4];
    le32w(t, v);
    return buf_tlv(b, tag, t, sizeof t);
}

int buf_tlv_u64(buf_t *b, uint16_t tag, uint64_t v) {
    uint8_t t[8];
    le64w(t, v);
    return buf_tlv(b, tag, t, sizeof t);
}

int tlv_next(cur_t *c, uint16_t *tag, const uint8_t **v, uint32_t *n) {
    if (c->off == c->len) return 0;
    if (c->len - c->off < 6) return -1;
    *tag = le16r(c->p + c->off);
    uint32_t l = le32r(c->p + c->off + 2);
    c->off += 6;
    if (c->len - c->off < l) return -1;
    *v = c->p + c->off;
    *n = l;
    c->off += l;
    return 1;
}

int tlv_find(const uint8_t *pl, uint32_t pln, uint16_t tag, const uint8_t **v, uint32_t *n) {
    cur_t c = { pl, pln, 0 };
    uint16_t t;
    const uint8_t *tv;
    uint32_t tn;
    int rc;
    while ((rc = tlv_next(&c, &t, &tv, &tn)) == 1) {
        if (t == tag) {
            *v = tv;
            *n = tn;
            return 1;
        }
    }
    return rc; /* 0 or -1 */
}

int tlv_find_str(const uint8_t *pl, uint32_t pln, uint16_t tag, char *out, size_t cap) {
    const uint8_t *v;
    uint32_t n;
    int rc = tlv_find(pl, pln, tag, &v, &n);
    if (rc != 1) return rc;
    if (n >= cap || memchr(v, 0, n)) return -1;
    memcpy(out, v, n);
    out[n] = 0;
    return 1;
}

int tlv_find_u8(const uint8_t *pl, uint32_t pln, uint16_t tag, uint8_t *out) {
    const uint8_t *v;
    uint32_t n;
    int rc = tlv_find(pl, pln, tag, &v, &n);
    if (rc != 1) return rc;
    if (n != 1) return -1;
    *out = v[0];
    return 1;
}

int tlv_find_u64(const uint8_t *pl, uint32_t pln, uint16_t tag, uint64_t *out) {
    const uint8_t *v;
    uint32_t n;
    int rc = tlv_find(pl, pln, tag, &v, &n);
    if (rc != 1) return rc;
    if (n != 8) return -1;
    *out = le64r(v);
    return 1;
}

void hdr_write(uint8_t *h, uint32_t len, uint8_t op, uint8_t flags, uint16_t status, uint64_t rid) {
    le32w(h, len);
    h[4] = op;
    h[5] = flags;
    le16w(h + 6, status);
    le64w(h + 8, rid);
}

void hdr_read(const uint8_t *h, uint32_t *len, uint8_t *op, uint8_t *flags, uint16_t *status, uint64_t *rid) {
    *len = le32r(h);
    *op = h[4];
    *flags = h[5];
    *status = le16r(h + 6);
    *rid = le64r(h + 8);
}

int read_full(int fd, void *p, size_t n) {
    uint8_t *b = p;
    while (n) {
        ssize_t r = read(fd, b, n);
        if (r > 0) {
            b += r;
            n -= (size_t)r;
            continue;
        }
        if (r < 0 && errno == EINTR) continue;
        return -1;
    }
    return 0;
}

int write_full(int fd, const void *p, size_t n) {
    const uint8_t *b = p;
    while (n) {
        ssize_t w = write(fd, b, n);
        if (w > 0) {
            b += w;
            n -= (size_t)w;
            continue;
        }
        if (w < 0 && errno == EINTR) continue;
        return -1;
    }
    return 0;
}

int wire_send(int fd, uint8_t op, uint8_t flags, uint16_t status, uint64_t rid,
              const uint8_t *pl, uint32_t pln) {
    uint8_t h[SLDB_HDR_SIZE];
    hdr_write(h, pln, op, flags, status, rid);
    if (write_full(fd, h, sizeof h)) return -1;
    return pln ? write_full(fd, pl, pln) : 0;
}

int wire_recv(int fd, uint8_t *op, uint8_t *flags, uint16_t *status, uint64_t *rid,
              uint8_t **pl, uint32_t *pln) {
    uint8_t h[SLDB_HDR_SIZE];
    if (read_full(fd, h, sizeof h)) return -1;
    uint32_t n;
    hdr_read(h, &n, op, flags, status, rid);
    if (n > SLDB_MAX_PAYLOAD) return -1;
    uint8_t *b = malloc(n ? n : 1);
    if (!b) return -1;
    if (n && read_full(fd, b, n)) {
        free(b);
        return -1;
    }
    *pl = b;
    *pln = n;
    return 0;
}

uint32_t crc32_of(const void *p, size_t n, uint32_t crc) {
    static uint32_t tab[256];
    static int init = 0;
    if (!init) {
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            tab[i] = c;
        }
        init = 1;
    }
    crc = ~crc;
    const uint8_t *s = p;
    while (n--) crc = tab[(crc ^ *s++) & 0xFF] ^ (crc >> 8);
    return ~crc;
}

uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}
