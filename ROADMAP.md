# silicadb roadmap

Vision, phases, and where we stand. Companion to [principles.md](principles.md)
(how we build) and [DECISIONS.md](DECISIONS.md) (what we decided and why).

## Vision

silicadb is a personal memory daemon for AI sessions: one machine, one human,
many agents. Agents `put` facts and `link` them into a graph as they work;
later sessions recall by key, prefix, or graph traversal instead of re-reading
transcripts. The end state is a small semantic graph engine — entities joined
by typed, weighted relations, eventually with vector similarity — whose
success is measured in context-window tokens: recall the smallest set of
records that carries the most meaning.

The constraints do not change as it grows: binary everywhere, zero
dependencies, and the append-only log stays the single source of truth. Every
index, arena, and vector structure is a projection that replay can rebuild.

## Where we are today (2026-07-15)

v0 is shipped, ported from C11 to Zig (D-007). Branch `metal-v0` @ 9e983b4:

- **daemon** `silicadbd`: unix stream socket, poll(2) loop, 64 connections,
  16-byte frame header + TLV protocol ([SPEC.md](SPEC.md))
- **CLI** `silica`: `ping put get rm ls link links stats`
- **store**: append-only crc-checked log, fsync per mutation, full replay on
  start; in-memory `StringHashMap` key index + linear triple list
- **gates**: `zig build test` (unit: wire, store, replay) and `make check`
  (E2E smoke incl. restart persistence) — both green

Links today are unweighted string triples, predicates are free strings, and
there are no vectors. The gap between this and the vision is the sodl
semantic layer (`sodl-1` spec): fixed-layout `EntityNode`/`RelationEdge`
storage, interned predicate ids, f32 edge weights, vector search, and the
decay/aggregation/masking experiments. The phases below close that gap.

## Phase 1 — weighted, interned edges (foundations)

Goal: links become measurable without breaking a byte on the wire or on disk.

- `T_WEIGHT` (f32) TLV tag; `silica link --weight`, default 1.0. Old logs and
  old clients keep working (principle 5: unknown tags are skipped).
- Intern predicates to u16 ids at replay/insert — in-memory table, the log
  keeps strings.
- Replace the O(n) dedup scan in `linksAdd` with per-subject hash adjacency.
  Not premature optimization: today every link insert walks every link.

Exit: tests + smoke green, new tag in SPEC.md, decision logged (D-008).

## Phase 2 — graph node layer (sodl kernel)

Goal: sodl's `EntityNode`/`RelationEdge` layouts as a **derived index**; the
log stays canonical (D-004).

- `id_hash: u64` over the key; fixed-size `EntityNode` table and
  `RelationEdge` arena, maintained on mutation, rebuilt on replay.
- `category_enum` mapped from the existing kind byte.
- CLI: `silica links <s> --pred a,b` (bitmask over interned predicate ids)
  and `silica load` bulk ingest for sodl compiler output.

Exit: graph traversal with no per-query allocation storm; `silica load`
input format specified in SPEC.md.

## Phase 3 — semantic experiments

Each of these needs a decision before it is built (see open questions):

- **Temporal weight decay** applied at traversal time — needs a half-life.
- **Hierarchical aggregation** of dense sub-graphs into pseudo-nodes during
  idle daemon cycles — needs a clustering criterion.
- **Vectors**: `T_VEC` tag + brute-force cosine first; HNSW only when node
  count demands it (principle 6).

Target metric for all three, per sodl-1: fewer tokens for equal recall.

## Open questions

1. sodl spec sections 1–3 and the compiler's output format — prerequisite
   for the `silica load` format.
2. Embedding source for the vector layer — the daemon does not embed; what
   does?
3. Arena persistence: derived in-memory (recommended, consistent with D-004)
   vs the spec's literal on-disk mmap file. Revisit only when
   rebuild-on-replay time actually hurts.
