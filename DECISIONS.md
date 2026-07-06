# Decision log

Append-only. One dated entry per decision that shapes protocol, storage, or
architecture. Reversals get a new entry referencing the old one. See
[principles.md](principles.md).

Format: `D-NNN <date> <title>` — context, decision, rejected alternatives.

---

## D-001 2026-07-05 Implementation language: C11 (status: under review)

**Context:** Need daemon + CLI, zero-dependency, binary protocol, long-lived
portable codebase. Repo was initialized with the C .gitignore template.

**Decision:** C11 + POSIX. Rationale: ubiquitous toolchain (a stock `cc`
builds it on any unix), stable ABI/language for a decade-scale artifact, no
runtime.

**Rejected:** Rust (toolchain weight, slower iteration for a ~1.5 kLOC v0);
Go (runtime, GC, fat binaries — not metal); Zig (strong candidate — see open
question below).

**Open:** Zig raised as alternative (comptime, no macros/UB footguns, built-in
cross-compilation, `zig cc` still builds C). v0 surface is small (~1.5 kLOC),
so a port is cheap now and expensive later. Decide before v1.

## D-002 2026-07-05 Transport: unix domain socket first

**Decision:** v0 listens on `$SILICADB_HOME/silicadb.sock` only. Local-first
matches the use case (AI sessions on the same machine); filesystem permissions
are the auth story. TCP + auth token deferred to v1.

**Rejected:** TCP-first (needs auth design now); stdio-per-request like an
MCP server (no shared daemon state, fork/exec cost per call).

## D-003 2026-07-05 Wire format: 16-byte frame header + TLV payload

**Decision:** Fixed little-endian header (len, op, flags, status, rid) then
flat `[u16 tag][u32 len][bytes]` TLVs. Unknown tags skipped — forward
compatibility without version negotiation per field.

**Rejected:** JSON (violates principle 1); protobuf/flatbuffers/cap'n proto
(dependency + codegen for a protocol we fully control); fixed structs
(no evolvability).

## D-004 2026-07-05 Storage: single append-only log, replay on start

**Decision:** One `memory.log`: crc-checked records (PUT/DEL/LINK), full
replay into an in-memory hash index + triple array at startup. Corrupt tail
truncated. The log doubles as complete history and as the portability/merge
unit. Compaction deferred until size hurts.

**Rejected:** SQLite (dependency, opaque file, overkill for KV+triples);
B-tree pages (complexity not yet earned); one-file-per-record (fsync storm,
not portable as a unit).

## D-005 2026-07-05 Durability: fsync per mutation

**Decision:** Every PUT/DEL/LINK is one `write()` + `fsync()` before the OK
response. Memory writes are low-rate, human/agent-paced; losing a confirmed
memory is worse than ~ms latency.

**Rejected:** Group commit / periodic flush (complexity, torn-tail window for
no needed throughput).

## D-006 2026-07-05 PUT payload stored verbatim, served verbatim on GET

**Decision:** The stored log payload for a record is byte-identical to the
wire payload of PUT (server appends TS if absent) and is returned as-is on
GET. Zero re-encoding on the read path; one `pread` per GET.

**Consequence:** Wire TLV tags and log payload tags are the same namespace —
protocol tag changes are storage format changes. Acceptable while both live
in one repo and the log carries a format version.
