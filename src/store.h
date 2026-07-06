#ifndef SLDB_STORE_H
#define SLDB_STORE_H

#include <stddef.h>
#include <stdint.h>

typedef struct store store_t;

typedef void (*store_key_fn)(const char *key, uint8_t kind, uint64_t ts, void *ud);
typedef void (*store_link_fn)(const char *s, const char *p, const char *o, uint64_t ts, void *ud);

store_t *store_open(const char *path);
void     store_close(store_t *st);

/* pl is a wire TLV payload containing at least T_KEY; stored verbatim.
 * 0 = ok, -1 = io/oom, -2 = bad payload */
int store_put(store_t *st, const uint8_t *pl, uint32_t n);

/* 1 = found (caller frees *pl), 0 = missing, -1 = io */
int store_get(store_t *st, const char *key, uint8_t **pl, uint32_t *n);

/* 1 = deleted, 0 = missing, -1 = io */
int store_del(store_t *st, const char *key);

int store_link(store_t *st, const char *s, const char *p, const char *o, uint64_t ts);

void store_iter_keys(store_t *st, const char *prefix, store_key_fn fn, void *ud);
void store_iter_links(store_t *st, const char *key, store_link_fn fn, void *ud);

uint64_t store_nkeys(store_t *st);
uint64_t store_nlinks(store_t *st);
uint64_t store_bytes(store_t *st);

#endif
