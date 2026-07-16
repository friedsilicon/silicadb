# Decision log

Append-only. One dated entry per decision that shapes protocol, storage, or
architecture. Reversals get a new entry referencing the old one. See
[principles.md](principles.md).

Format: `D-NNN <date> <title>` — context, decision, rejected alternatives.

---

## D-001 2026-07-05 Implementation language: C11 (status: closed by D-007)

**Context:** Need daemon + CLI, zero-dependency, binary protocol, long-lived
portable codebase. Repo was initialized with the C .gitignore template.

**Decision:** Zig + C11 + POSIX. Rationale: ubiquitous toolchain and no runtime

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

## D-007 2026-07-05 Implementation language: Zig (closes D-001)

**Context:** D-001 left Zig as an open question. The full v0 surface (daemon,
CLI, store, wire) was ported to Zig 0.16 while the codebase was still small;
on-disk log format and wire protocol are byte-identical to the C version.

**Decision:** Zig is the implementation language. C sources deleted. Build is
`zig build`; unit smoke tests (`src/tests.zig`, `zig build test`) plus the
E2E daemon test (`scripts/smoke.sh`, `make check`) gate changes.

**Rejected:** Keeping parallel C+Zig trees (double maintenance, drift risk —
the log format compatibility is already proven by replay tests).

## D-008 2026-07-15 RFC-0001 (spec-v0 branch) abandoned; ideas harvested

**Context:** The orphan branch `spec-v0` carried RFC-0001, a normative spec
for a SQLite-backed, MCP-fronted, JSON-valued memory store — the approaches
D-002 and D-004 rejected. It describes a system that was never built, and it
drifted from the implemented engine precisely because it was written ahead of
any code.

**Decision:** RFC-0001 is abandoned unmerged (PR #2 closed; the draft stays
archived on the `spec-v0` branch). Four storage/transport-agnostic ideas are
harvested into ROADMAP.md instead: `as_of` supersession-aware reads over the
append-only log, a provenance TLV tag, multi-store routing with visibility
policies, and spec discipline (numbered invariants, error registry, declared
token estimator) applied inside SPEC.md as it grows. The one interface that
gets normative treatment is the `silica load` compiler↔db contract, specified
in SPEC.md when phase 2 starts.

**Rejected:** Rewriting RFC-0001 against current decisions (normative spec
for unbuilt phases repeats the mistake that orphaned it; violates principles
4 and 6); merging it under `rfc/` as a reference document (dead weight beside
the living SPEC.md — the branch archive suffices).

## D-009 2026-07-15 Weighted, interned, provenance-carrying links (phase 1)

**Context:** ROADMAP.md phase 1. Links were unweighted string triples deduped
by an O(n) scan over every link on every insert.

**Decision:** New TLV tags WEIGHT (15, f32 le, must be finite, default 1.0)
and SRC (16, utf8 ≤255). LINK accepts both; LINKS returns them. The log
payload keeps predicate strings (log stays self-describing); in memory,
predicates intern to dense u16 ids and inserts dedup via a per-subject
adjacency map — both derived, rebuilt on replay. Old logs and old clients
keep working (unknown tags skipped, absent weight reads as 1.0).

**Rejected:** Predicate ids on disk (log would need an id table to stay
portable, violating "the log is the artifact"); weight as fixed-point u32
(f32 is what the sodl layer computes with; NaN/inf rejected at the wire);
global triple hash for dedup (per-subject buckets are what phase-2 traversal
needs anyway).

## D-010 2026-07-15 Graph kernel as derived index; as-of reads; bulk load (phase 2)

**Context:** ROADMAP.md phase 2 — the sodl EntityNode/RelationEdge layout,
point-in-time reads, and the compiler↔db ingest contract.

**Decision:** The graph kernel (EntityNode table keyed by wyhash-64 of the
key, RelationEdge arena with per-subject intrusive chains) is a **derived
index**: maintained on mutation, rebuilt from the log on replay, never
serialized. Edges store the target *node index* (u32), not the sodl spec's
u64 id_hash — the hash is one lookup away and the arena stays half the size.
GET gains ASOF (tag 17): a linear log rescan answering "value at instant T";
DEL records now carry TS to support it (old TS-less DELs inherit the previous
record's ts — sound because the log appends in time order). LINKS accepts
repeated PRED tags filtered via a u64 bitmask over interned ids (< 64) with a
small-list fallback. `silica load` TSV is specified normatively in SPEC.md —
it is the one interface an external program (sodl compiler) must emit.

**Rejected:** On-disk mmap arena (nothing measured demands persistence of a
rebuildable index; revisit when replay time hurts — ROADMAP open question 3);
as-of via per-key version chains in memory (state grows with history; the log
already is the history); id_hash as edge target (u64 vs u32, no read either
way); JSON/CSV load formats (tabs need no quoting layer for this data).
