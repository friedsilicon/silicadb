//! Wire protocol constants. Must match SPEC.md exactly.

pub const VERSION: u32 = 1;
pub const HDR_SIZE: usize = 16;
pub const MAX_PAYLOAD: u32 = 16 * 1024 * 1024;

pub const KEY_MAX: usize = 255;
pub const TAGS_MAX: usize = 1024;
pub const SRC_MAX: usize = 255;

// opcodes
pub const OP_HELLO: u8 = 0x01;
pub const OP_PING: u8 = 0x02;
pub const OP_PUT: u8 = 0x10;
pub const OP_GET: u8 = 0x11;
pub const OP_DEL: u8 = 0x12;
pub const OP_LIST: u8 = 0x13;
pub const OP_LINK: u8 = 0x20;
pub const OP_LINKS: u8 = 0x21;
pub const OP_STATS: u8 = 0x30;

// frame flags
pub const F_RESP: u8 = 0x80;

// response status
pub const ST_OK: u16 = 0;
pub const ST_NOTFOUND: u16 = 1;
pub const ST_BADREQ: u16 = 2;
pub const ST_IO: u16 = 3;
pub const ST_VERSION: u16 = 4;
pub const ST_TOOBIG: u16 = 5;

// TLV tags
pub const T_VERSION: u16 = 1;
pub const T_KEY: u16 = 2;
pub const T_BODY: u16 = 3;
pub const T_KIND: u16 = 4;
pub const T_TAGS: u16 = 5;
pub const T_TS: u16 = 6;
pub const T_SUBJ: u16 = 7;
pub const T_PRED: u16 = 8;
pub const T_OBJ: u16 = 9;
pub const T_PREFIX: u16 = 10;
pub const T_NKEYS: u16 = 11;
pub const T_NLINKS: u16 = 12;
pub const T_BYTES: u16 = 13;
pub const T_MSG: u16 = 14;
pub const T_WEIGHT: u16 = 15;
pub const T_SRC: u16 = 16;
pub const T_ASOF: u16 = 17;

// record kinds
pub const K_NOTE: u8 = 0;
pub const K_FACT: u8 = 1;
pub const K_PREF: u8 = 2;
pub const K_PROJECT: u8 = 3;
pub const K_REF: u8 = 4;
