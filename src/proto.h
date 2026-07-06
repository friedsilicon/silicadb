#ifndef SLDB_PROTO_H
#define SLDB_PROTO_H

#include <stdint.h>

#define SLDB_VERSION     1u
#define SLDB_HDR_SIZE    16u
#define SLDB_MAX_PAYLOAD (16u * 1024u * 1024u)

#define SLDB_KEY_MAX  255
#define SLDB_TAGS_MAX 1024

/* opcodes */
enum {
    OP_HELLO = 0x01,
    OP_PING  = 0x02,
    OP_PUT   = 0x10,
    OP_GET   = 0x11,
    OP_DEL   = 0x12,
    OP_LIST  = 0x13,
    OP_LINK  = 0x20,
    OP_LINKS = 0x21,
    OP_STATS = 0x30,
};

/* frame flags */
#define F_RESP 0x80u

/* response status */
enum {
    ST_OK       = 0,
    ST_NOTFOUND = 1,
    ST_BADREQ   = 2,
    ST_IO       = 3,
    ST_VERSION  = 4,
    ST_TOOBIG   = 5,
};

/* TLV tags */
enum {
    T_VERSION = 1,  /* u32 */
    T_KEY     = 2,  /* utf-8, <= SLDB_KEY_MAX */
    T_BODY    = 3,  /* raw bytes */
    T_KIND    = 4,  /* u8 */
    T_TAGS    = 5,  /* utf-8, comma-separated */
    T_TS      = 6,  /* u64 unix ns */
    T_SUBJ    = 7,  /* utf-8 */
    T_PRED    = 8,  /* utf-8 */
    T_OBJ     = 9,  /* utf-8 */
    T_PREFIX  = 10, /* utf-8 */
    T_NKEYS   = 11, /* u64 */
    T_NLINKS  = 12, /* u64 */
    T_BYTES   = 13, /* u64 */
    T_MSG     = 14, /* utf-8 */
};

/* record kinds */
enum { K_NOTE = 0, K_FACT = 1, K_PREF = 2, K_PROJECT = 3, K_REF = 4 };

#endif
