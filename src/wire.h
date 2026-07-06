#ifndef SLDB_WIRE_H
#define SLDB_WIRE_H

#include <stddef.h>
#include <stdint.h>

/* little-endian encode/decode */
static inline void le16w(uint8_t *d, uint16_t v) { d[0] = (uint8_t)v; d[1] = (uint8_t)(v >> 8); }
static inline void le32w(uint8_t *d, uint32_t v) {
    d[0] = (uint8_t)v; d[1] = (uint8_t)(v >> 8); d[2] = (uint8_t)(v >> 16); d[3] = (uint8_t)(v >> 24);
}
static inline void le64w(uint8_t *d, uint64_t v) {
    for (int i = 0; i < 8; i++) d[i] = (uint8_t)(v >> (8 * i));
}
static inline uint16_t le16r(const uint8_t *s) { return (uint16_t)((uint16_t)s[0] | (uint16_t)s[1] << 8); }
static inline uint32_t le32r(const uint8_t *s) {
    return (uint32_t)s[0] | (uint32_t)s[1] << 8 | (uint32_t)s[2] << 16 | (uint32_t)s[3] << 24;
}
static inline uint64_t le64r(const uint8_t *s) {
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) v = v << 8 | s[i];
    return v;
}

/* growable byte buffer */
typedef struct {
    uint8_t *p;
    size_t len, cap;
} buf_t;

void buf_init(buf_t *b);
void buf_free(buf_t *b);
int  buf_put(buf_t *b, const void *src, size_t n);
void buf_consume(buf_t *b, size_t n);

int buf_tlv(buf_t *b, uint16_t tag, const void *v, uint32_t n);
int buf_tlv_str(buf_t *b, uint16_t tag, const char *s);
int buf_tlv_u8(buf_t *b, uint16_t tag, uint8_t v);
int buf_tlv_u32(buf_t *b, uint16_t tag, uint32_t v);
int buf_tlv_u64(buf_t *b, uint16_t tag, uint64_t v);

/* TLV parse cursor: 1 = got one, 0 = end, -1 = malformed */
typedef struct {
    const uint8_t *p;
    size_t len, off;
} cur_t;

int tlv_next(cur_t *c, uint16_t *tag, const uint8_t **v, uint32_t *n);

/* find helpers: 1 = found, 0 = missing, -1 = malformed/oversize */
int tlv_find(const uint8_t *pl, uint32_t pln, uint16_t tag, const uint8_t **v, uint32_t *n);
int tlv_find_str(const uint8_t *pl, uint32_t pln, uint16_t tag, char *out, size_t cap);
int tlv_find_u8(const uint8_t *pl, uint32_t pln, uint16_t tag, uint8_t *out);
int tlv_find_u64(const uint8_t *pl, uint32_t pln, uint16_t tag, uint64_t *out);

/* frame header */
void hdr_write(uint8_t *h, uint32_t len, uint8_t op, uint8_t flags, uint16_t status, uint64_t rid);
void hdr_read(const uint8_t *h, uint32_t *len, uint8_t *op, uint8_t *flags, uint16_t *status, uint64_t *rid);

/* blocking frame i/o (client side) */
int read_full(int fd, void *p, size_t n);
int write_full(int fd, const void *p, size_t n);
int wire_send(int fd, uint8_t op, uint8_t flags, uint16_t status, uint64_t rid,
              const uint8_t *pl, uint32_t pln);
int wire_recv(int fd, uint8_t *op, uint8_t *flags, uint16_t *status, uint64_t *rid,
              uint8_t **pl, uint32_t *pln);

uint32_t crc32_of(const void *p, size_t n, uint32_t crc);
uint64_t now_ns(void);

#endif
