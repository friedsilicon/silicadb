# SILICA v0 — Contract Spec

Status: DRAFT for founder sign-off. Everything here is the *permanent* surface: the file format,
the MCP tool contract, and SODL mapping/evolution rules. The engine behind it (SQLite now,
SODL-native mmap arena in v1) is swappable and invisible to users.

## 0. Invariants (non-negotiable)

- One `.silica` file per project. No daemon, no sidecar, no network.
- Shipping binary < 10 MB, single static executable (Zig, SQLite via @cImport).
- Crash-safe from day one: SQLite WAL is the write path and source of truth in v0.
- A `.silica` file is openable by stock `sqlite3` in 2036. Data outlives the product.
- Every recall response is provenance-carrying and token-bounded.

## 1. The .silica file (v0 physical layout)

SQLite database. `application_id = 0x51CA0001`, `user_version = 1`, WAL mode, FK enforcement on.

### Tables

**type_defs** — the ontology.
- `name TEXT PRIMARY KEY`
- `parent TEXT REFERENCES type_defs(name)` — single inheritance; `is_a` chains give subsumption
- `sodl_version INTEGER NOT NULL`

**schema_defs** — the file is self-describing.
- `version INTEGER PRIMARY KEY`
- `sodl_source TEXT NOT NULL` — full .sodl text as compiled
- `created_at INTEGER NOT NULL` (unix ms)

**entities**
- `id INTEGER PRIMARY KEY`
- `type TEXT NOT NULL REFERENCES type_defs(name)`
- `name TEXT` — human handle, nullable
- `created_at INTEGER NOT NULL`, `deleted_at INTEGER` — soft delete only

**facts** — append-only. Facts are never updated; they are superseded.
- `id INTEGER PRIMARY KEY`
- `entity_id INTEGER NOT NULL REFERENCES entities(id)`
- `predicate TEXT NOT NULL` — from the SODL field/relation set
- `object_entity_id INTEGER REFERENCES entities(id)` — set for relations
- `value TEXT` — JSON scalar/array for attribute facts (exactly one of value / object_entity_id)
- `source_id INTEGER NOT NULL REFERENCES sources(id)`
- `confidence REAL DEFAULT 1.0`
- `asserted_at INTEGER NOT NULL`
- `invalidated_at INTEGER`, `invalidated_by INTEGER REFERENCES facts(id)` — supersession chain

**sources** — provenance.
- `id INTEGER PRIMARY KEY`
- `kind TEXT NOT NULL CHECK (kind IN ('session','user','tool','import'))`
- `ref TEXT` — session id, file path, tool name
- `occurred_at INTEGER NOT NULL`

**events** — append-only activity log (decisions, observations, tool runs).
- `id INTEGER PRIMARY KEY`
- `ts INTEGER NOT NULL`
- `actor TEXT NOT NULL` — agent/user identifier
- `kind TEXT NOT NULL`
- `payload TEXT NOT NULL` — JSON

**facts_fts** — FTS5 over rendered fact text (`"<entity name> <predicate> <value>"`),
kept in sync by triggers. This is the entire v0 search story. Vectors are v0.2, optional.

## 2. MCP tool surface (permanent names, permanent shapes)

Transport: JSON-RPC 2.0 over stdio. Implements `initialize`, `tools/list`, `tools/call`.
Four tools. No fifth without a spec revision.

### remember
Assert facts about an entity (creating it if needed).
```json
{ "type": "decision", "name": "billing-retry-policy",
  "facts": [ {"predicate": "summary", "value": "retry 3x, exp backoff"},
             {"predicate": "supersedes", "entity_ref": "billing-retry-v1"} ],
  "source": {"kind": "session", "ref": "claude-code:2026-07-03"} }
```
→ `{ "entity_id": 42, "fact_ids": [107,108] }`
Rules: entity resolved by (type, name); unknown type or predicate → error citing the SODL schema
(schema-enforced memory is the product; silent acceptance is markdown with extra steps).

### recall
```json
{ "query": "billing retry decision", "type": "decision", "limit": 10,
  "as_of": null, "max_tokens": 800 }
```
→ `{ "results": [ { "entity": {...}, "facts": [...], "score": 0.91,
     "provenance": {"kind":"session","ref":"...","occurred_at": 1751500000000} } ],
     "token_estimate": 212 }`
Rules: `type` filter includes subtypes (subsumption via type_defs). Superseded facts excluded
unless `as_of` set (time-travel read). Response hard-capped at `max_tokens` (default 800) —
this cap IS the pitch: 40k-token CLAUDE.md → 200-token answer.

### invalidate
`{ "fact_id": 107, "reason": "user corrected" }` → `{ "superseded_by": 121 }`
Never deletes. Writes a tombstone fact and links the chain.

### log_event
`{ "kind": "decision", "actor": "claude-code", "payload": {...} }` → `{ "event_id": 9001 }`

## 3. SODL → layout mapping

- `object X` → row in type_defs; `object X : Y` → parent = Y (subsumption).
- Scalar fields → attribute facts (predicate = field name, value = JSON).
- Relation fields → relation facts (object_entity_id).
- Constraints (ranges, enums, cardinality) compile to CHECK-style validation in the write path.
- Compiled schema text stored in schema_defs; the file needs no external .sodl to be read.

## 4. Evolution rules (the ABI-vs-ontology answer, v0 = additive-only)

1. Types and predicates are append-only. Never renamed, never removed — only `@deprecated`.
2. A type's parent may change only to an ancestor of the current parent (widening only).
3. Constraint changes may only loosen. Tightening requires a new predicate.
4. Every compile bumps schema_defs.version; facts are readable under all versions forever.
Anything additive-only can later compile to a fixed physical layout — which is what makes v1 possible.

## 5. v1 direction (informative, not contractual)

`silica compact` emits a read-optimized, mmap-able arena generated from the SODL schema
(fixed offsets, C-ABI-compatible structs, string heap). SQLite stays the write path/source of
truth; the arena is a derived, regenerable snapshot. Zero-copy story lands without ever risking
the durability of a hand-rolled write path.

## 6. Build order (14-day sprint)

1. stdio JSON-RPC loop: initialize / tools/list / tools/call
2. File bootstrap + schema compile (hardcode one built-in schema if the SODL parser slips)
3. remember + facts_fts triggers
4. recall with token cap + subsumption
5. invalidate, log_event
6. Demo script: ingest a real CLAUDE.md, run 5 recalls, print token counts side by side

## 7. Multi-store: scoped memory with policy-governed sync (v0.2 surface, locked now)

All local. No network, ever. Sync = local file-to-file policy application, not a cloud.

### Stores
A store is a .silica file. Default mounts: `~/.silica/personal.silica` plus any project-level
stores declared in `~/.silica/routes.sodl`. New table in each file is NOT needed — mounts live
in config, files stay self-contained and portable.

### Routing (writes)
`remember` targets exactly one store, resolved deterministically — no LLM in the path:
1. explicit `store` param, else
2. cwd/git-remote match against routes.sodl rules (e.g. remote glob `github.com/friedsilicon/*`), else
3. personal.
Resolution is a string match at startup; cached per-process. Cost: ~zero.

### Federation (reads)
`recall` searches all mounted stores via SQLite `ATTACH DATABASE` — one process, one query
plan, unified FTS ranking across stores. No RPC, no merge daemon. Results carry
`provenance.store`. Optional `stores: [...]` param narrows scope.

### Sync policy (default-deny)
Cross-store visibility only by explicit rule in routes.sodl:
```
policy share_prefs  { from: personal,  types: [preference], to: * }
policy ms_isolation { from: mswork,    types: *,            to: none }
```
Facts never copy between stores by default. A store handed to an employer contains only what
was written to it — isolation is physical (separate file), not a filter. `silica audit <store>`
prints every fact that crossed a boundary and under which policy.

### Efficiency budget (contractual)
- recall p95 < 10 ms across 3 stores / 100k facts on laptop hardware
- silica process RSS < 20 MB idle
- store overhead: empty .silica < 100 KB
Budgets printed by `silica bench`; regressions are release blockers.
