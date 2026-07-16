# silicadb — spec v0

A minimal, metal-first memory daemon for AI sessions. One append-only log per
machine holds every memory record and every semantic link ever written. A tiny
binary protocol connects clients (CLI today, editor/agent hooks tomorrow) to a
single daemon. No JSON, no runtime dependencies, Zig.

## Goals

- **Portable memory substrate.** The log file *is* the artifact: copy
  `memory.log` to another machine and the daemon rebuilds full state.
- **Semantic + ontological growth path.** Records carry kinds and tags; links
  are subject–predicate–object triples, so the store is already a graph that
  can later be exported as RDF/N-Triples or enriched with embeddings.
- **Efficiency.** Binary framing, TLV payloads, single write + fsync per
  mutation, pread-served reads, zero copies re-encoding (the stored PUT
  payload is byte-identical to the GET response payload).

## Components

| Binary      | Role                                                        |
|-------------|-------------------------------------------------------------|
| `silicadbd` | Daemon. Owns the log, serves a unix socket, poll(2) loop.   |
| `silica`    | CLI client. One subcommand per opcode.                      |

Shared core: `src/wire.[ch]` (framing, TLV, buffers, crc32),
`src/store.[ch]` (log + index + links), `src/proto.h` (constants).

Default home is `$SILICADB_HOME` or `~/.silicadb`:

```
~/.silicadb/memory.log      append-only record log (the portable artifact)
~/.silicadb/silicadb.sock   unix stream socket
```

## Wire protocol

All integers are little-endian. Every message is a frame:

```
offset  size  field
0       4     len      payload byte count (after this header)
4       1     op       opcode
5       1     flags    bit 7 (0x80) = response
6       2     status   0 on requests; status code on responses
8       8     rid      request id, echoed verbatim in the response
```

Header is 16 bytes. Max payload 16 MiB. Payloads are a flat sequence of TLVs:

```
[u16 tag][u32 len][len bytes]
```

Unknown tags are skipped — forward compatible by construction.

### Opcodes

| op   | name  | request TLVs                       | response TLVs                       |
|------|-------|------------------------------------|-------------------------------------|
| 0x01 | HELLO | VERSION                            | VERSION                             |
| 0x02 | PING  | —                                  | —                                   |
| 0x10 | PUT   | KEY, [KIND], [TAGS], [SRC], [TS], BODY | —                               |
| 0x11 | GET   | KEY, [ASOF]                        | KEY, KIND, TAGS, TS, BODY (stored)  |
| 0x12 | DEL   | KEY                                | —                                   |
| 0x13 | LIST  | [PREFIX]                           | (KEY, KIND, TS)*                    |
| 0x20 | LINK  | SUBJ, PRED, OBJ, [WEIGHT], [SRC]   | —                                   |
| 0x21 | LINKS | [KEY], PRED*                       | (SUBJ, PRED, OBJ, WEIGHT, [SRC], TS)* |

GET with ASOF answers as of that instant by rescanning the log (linear; fine
until measured otherwise). LINKS with one or more PRED tags returns only
those predicates; a predicate the store has never seen matches nothing.
| 0x30 | STATS | —                                  | NKEYS, NLINKS, BYTES                |

Status codes: `0 OK, 1 NOTFOUND, 2 BADREQ, 3 IO, 4 VERSION, 5 TOOBIG`.

### TLV tags

| tag | name    | type | notes                                  |
|-----|---------|------|----------------------------------------|
| 1   | VERSION | u32  | protocol version (currently 1)         |
| 2   | KEY     | utf8 | ≤255 bytes; convention `scope/name`    |
| 3   | BODY    | raw  | arbitrary bytes                        |
| 4   | KIND    | u8   | 0 note, 1 fact, 2 pref, 3 project, 4 ref |
| 5   | TAGS    | utf8 | comma-separated, ≤1024 bytes           |
| 6   | TS      | u64  | unix time, nanoseconds                 |
| 7   | SUBJ    | utf8 | link subject key                       |
| 8   | PRED    | utf8 | link predicate                         |
| 9   | OBJ     | utf8 | link object key                        |
| 10  | PREFIX  | utf8 | LIST filter                            |
| 11  | NKEYS   | u64  |                                        |
| 12  | NLINKS  | u64  |                                        |
| 13  | BYTES   | u64  | log size on disk                       |
| 14  | MSG     | utf8 | optional error text on responses       |
| 15  | WEIGHT  | f32  | link weight, IEEE 754 le; must be finite; default 1.0 |
| 16  | SRC     | utf8 | provenance (session/agent/url), ≤255 bytes |
| 17  | ASOF    | u64  | GET: answer as of this instant (ns)    |

If a PUT arrives without TS the server appends one; otherwise the client
payload is stored verbatim — and returned verbatim on GET.

## Storage

`memory.log`: 8-byte file header (`"SLDB"` magic + u32 format version), then
records:

```
[u32 paylen][u32 crc32(type ‖ payload)][u8 type][payload TLVs]
```

Record types: `1 PUT, 2 DEL, 3 LINK`. DEL records carry TS (older logs
without it stay readable: for as-of reads such a record inherits the previous
record's ts). Startup replays the log into an open-addressing hash index
(key → payload offset/len, kind, ts), an in-memory triple array, and the
derived graph kernel below. A corrupt tail (torn write) is detected by
crc/length and truncated. Every mutation is one `write` + `fsync`. GET is a
single `pread` at the indexed offset.

### Derived graph kernel

Everything here is rebuilt from the log on replay; none of it is on disk.
Predicates intern to dense u16 ids. Every PUT key and every link endpoint
gets a fixed-size `EntityNode` (wyhash-64 of the key, name length, category =
kind byte, or 0xff for link-only endpoints, and reserved vector offset);
edges live in one arena as `RelationEdge` (target node index, predicate id,
f32 weight, ts) chained per subject node. Last write per (subject, predicate,
object) wins, updating weight/src/ts in both the triple array and the edge.

## Bulk load (normative: the sodl-compiler contract)

`silica load` reads UTF-8 lines from stdin. This is the one interface a
separate program (the sodl compiler) must produce, so it is normative:
tab-separated fields, one operation per line.

```
put  <TAB> key <TAB> kind <TAB> tags <TAB> src <TAB> body
link <TAB> subj <TAB> pred <TAB> obj [<TAB> weight [<TAB> src]]
```

- `kind` is a kind name (`note fact pref project ref`) or 0–255; empty means
  note. Empty `tags`/`src` are omitted. `weight` empty or absent means 1.0
  and must be finite. `key`, `subj`, `pred`, `obj` must be non-empty.
- `put` body is everything after the fifth tab and may itself contain tabs;
  it cannot contain a newline.
- Blank lines and lines starting with `#` are skipped. Any other line is an
  error: the loader stops with the line number and nothing further is sent.
- Lines apply in order with server-assigned timestamps; a `link` may
  reference keys that were never `put`.

Compaction (rewrite live records into a fresh log) is deliberately deferred —
the log doubles as full history until then.

## Data model

- **Record**: key + kind + tags + timestamp + opaque body. Keys are
  namespaced by convention: `projectname/topic`, `user/prefs/editor`, …
- **Link**: `(subject, predicate, object)` triple with weight (f32, default
  1.0), optional provenance, and timestamp; last write per triple wins and
  updates weight/src/ts. Predicates are free-form strings on the wire and in
  the log, interned to dense u16 ids in memory (derived, rebuilt on replay).

## Roadmap

- **v1**: `VEC` TLV (f32[] embedding) on PUT, `SEARCH` opcode (brute-force
  cosine, later HNSW); TCP transport + auth token; log compaction.
- **v2**: `silica export` → N-Triples/RDF of the link graph; multi-machine
  merge (log records are naturally mergeable by timestamp); session-capture
  hooks for AI agents (Claude Code memory hook → `silica put`).
