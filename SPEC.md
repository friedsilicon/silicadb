# RFC-0001: SILICA — A Local, Typed, Bitemporal Memory Store for AI Agents

```
Status:     Draft
Version:    0.1.0
Date:       2026-07-03
Author:     Fried Silicon
Obsoletes:  none
Audience:   Implementers of silica engines, SODL compilers, and MCP clients
```

## Abstract

SILICA defines (a) a single-file, SQLite-backed storage format for typed, provenance-carrying,
bitemporal facts ("the .silica file"), (b) a four-tool interface exposed over the Model Context
Protocol (MCP) by which agents read and write memory, (c) mapping and evolution rules from the
Structured Object Definition Language (SODL) to the physical layout, and (d) a multi-store
routing and visibility-policy model for isolating memory across personal and organizational
contexts. The document is normative and is intended to be sufficient to implement an
interoperable engine, compiler, and tooling without reference to any existing implementation.

## 1. Requirements Language

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT",
"RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in
RFC 2119.

## 2. Terminology

- **Store**: a single `.silica` file conforming to §4. A store is self-contained: it MUST be
  readable without reference to any external file.
- **Entity**: a typed, optionally named subject about which facts are asserted (§5.1).
- **Fact**: an immutable assertion about exactly one entity: either an *attribute fact*
  (predicate + JSON value) or a *relation fact* (predicate + reference to another entity). §5.2.
- **Supersession**: the only permitted form of change to a fact: marking it invalidated and
  optionally linking the fact that replaces it (§5.3).
- **Visibility instant (T)**: the point in time at which a read is evaluated. Defaults to the
  current time; overridable per-query via `as_of` (§8.5).
- **Source**: a provenance record identifying where an assertion originated (§5.4).
- **Context store**: for a given process invocation, the store to which writes route (§9.2).
- **Ontology**: the set of types in `type_defs`, forming a single-inheritance forest rooted,
  by convention, at type `entity`.
- **Engine**: software implementing this RFC's storage and protocol requirements.
- **Compiler**: software translating SODL source into schema rows per §6 and validating
  evolution per §7.

## 3. Design Invariants

An implementation MUST uphold all of the following. These are testable conformance criteria
(§13), not aspirations.

- **I-1 (Single file)**: one store is one ordinary file plus SQLite's transient sidecars
  (`-wal`, `-shm`). No daemon, no lock server, no network I/O in the storage path.
- **I-2 (Local only)**: an engine MUST NOT initiate network connections. All synchronization
  is local file-to-file (§9.4).
- **I-3 (Durability by substrate)**: v0 engines MUST use SQLite in WAL mode as the write path.
  Crash safety is delegated to SQLite; engines MUST NOT buffer acknowledged writes in memory.
- **I-4 (Forward readability)**: a store MUST remain fully readable by stock `sqlite3` with no
  extensions beyond FTS5. No custom file headers, no encryption at the format layer.
- **I-5 (Append-only facts)**: rows in `facts` MUST NOT be deleted, and no column of an
  existing `facts` row may be modified except `invalidated_at` and `invalidated_by`, each
  writable exactly once (NULL → non-NULL).
- **I-6 (Bounded reads)**: every `recall` response MUST respect the token budget of §8.5.6.
- **I-7 (Provenance totality)**: every fact MUST reference a source row.

## 4. The .silica Container Format

### 4.1 Container

A store is an SQLite 3 database file with:

- `PRAGMA application_id = 0x51CA0001` — REQUIRED. Readers MUST reject files whose
  application_id differs, with error 1010 (§11).
- `PRAGMA user_version = 1` — the **format version** of this RFC. Engines MUST reject
  user_version values greater than they implement (error 1011) and MUST migrate or reject
  lesser values.
- `PRAGMA journal_mode = WAL` and `PRAGMA foreign_keys = ON` MUST be set by engines on open.

### 4.2 Schema (normative DDL)

The DDL in `sql/schema.sql` of the reference repository is **normative**; the table and index
definitions there MUST be reproduced byte-equivalently in meaning (column names, types,
constraints, trigger behavior). Summary of tables:

| Table        | Purpose                                                      |
|--------------|--------------------------------------------------------------|
| `type_defs`  | The ontology: type name → parent type, introducing schema version. |
| `schema_defs`| Every compiled SODL schema version, full source retained.    |
| `sources`    | Provenance records.                                          |
| `entities`   | Typed subjects.                                              |
| `facts`      | Append-only attribute and relation assertions.               |
| `events`     | Append-only activity log.                                    |
| `facts_fts`  | FTS5 index (contentless, `contentless_delete=1`) over visible facts. |

Two trigger behaviors are normative:

- **T-1**: inserting a fact MUST insert a corresponding `facts_fts` row containing the
  entity's name (empty string if NULL), the predicate, and the JSON value (empty string for
  relation facts), rowid equal to the fact id.
- **T-2**: setting `invalidated_at` on a fact MUST delete its `facts_fts` row. Consequently a
  superseded fact is unreachable via full-text search *by construction*; engines MUST NOT rely
  on query-time filtering alone for supersession semantics on the FTS path.

### 4.3 Identifier and encoding rules

- All timestamps are **Unix epoch milliseconds**, INTEGER, UTC.
- All ids are SQLite INTEGER PRIMARY KEY (rowid) values; ids MUST NOT be reused (guaranteed by
  I-5's no-delete rule).
- `facts.value`, `events.payload` MUST contain valid JSON encoded as UTF-8 text. Engines MUST
  validate JSON on write and reject invalid JSON with error 1003.
- Type names and predicates MUST match `[a-z][a-z0-9_]*`, maximum 64 bytes.
- Entity names are free-form UTF-8, maximum 512 bytes; leading/trailing whitespace MUST be
  trimmed on write. Uniqueness of `(type, name)` is enforced for non-NULL names among
  non-deleted entities.

## 5. Data Model Semantics

### 5.1 Entities

An entity has exactly one type for its lifetime. Retyping is prohibited; the correction path is
soft-deleting the entity (setting `deleted_at`) and creating a replacement. Soft-deleted
entities remain readable via time-travel (`as_of` earlier than `deleted_at`) and are excluded
from current-time reads.

### 5.2 Facts

Exactly one of `value` / `object_entity_id` MUST be non-NULL (the XOR CHECK in the DDL).
A fact with `object_entity_id` set is a *relation fact*; its predicate MUST be declared in SODL
as a relation (§6.3). `confidence` is a REAL in [0.0, 1.0]; writers MAY set it, default 1.0.
Engines MUST NOT interpret confidence in ranking in v0; it is carried for consumers.

### 5.3 Supersession and bitemporal visibility

**Visibility rule (normative).** Fact F is *visible at instant T* iff:

```
F.asserted_at <= T  AND  (F.invalidated_at IS NULL OR F.invalidated_at > T)
```

and F's entity is not soft-deleted at T by the same rule applied to `deleted_at`.

Invalidation MUST record: `invalidated_at` (the instant), and, when the invalidation
accompanies a replacement assertion, `invalidated_by` pointing at the replacing fact. The
replacing fact and the invalidation MUST be committed in one SQLite transaction so no reader
can observe both facts visible simultaneously. The chain `invalidated_by → id` MUST be acyclic.

### 5.4 Sources

Every write API accepts an optional source descriptor `{kind, ref}`. If omitted, the engine
MUST synthesize `{kind: "session", ref: <client name + ISO date>}` from the MCP initialize
handshake. `occurred_at` defaults to write time.

### 5.5 Events

`events` is an append-only log with no supersession semantics and no FTS indexing in v0.
Engines MUST NOT delete event rows. Events are the designated home for high-volume,
low-structure records; anything queried by meaning belongs in facts instead.

## 6. SODL → Physical Mapping

This section binds SODL declarations to rows. The SODL surface grammar is defined in the
`friedsilicon/sodl` repository; this RFC constrains its *semantics* when compiled to a store.

### 6.1 Types

`object X` compiles to `type_defs(name='x', parent='entity')`. `object X : Y` sets
`parent='y'`; Y MUST already exist in the schema being compiled (forward references within one
compilation unit are permitted; the compiler resolves them before emit). Inheritance is single;
the parent graph MUST be a forest (compiler error 2001 on cycles).

### 6.2 Attribute fields

A scalar/array field `f` on type X declares predicate `f` as valid for X and all descendants
of X. The compiler MUST record, per predicate: value JSON kind (string | number | boolean |
array | object), cardinality (`one` | `many`, default `one`), and constraints. For
cardinality `one`, a `remember` asserting predicate `f` on an entity that already has a
visible `f` fact MUST atomically invalidate the prior fact (reason `"superseded by new
assertion"`, `invalidated_by` linked) — this is the *implicit supersession* rule. For
cardinality `many`, assertions accumulate.

### 6.3 Relations

`rel r -> Y` on type X declares predicate `r` whose facts MUST have `object_entity_id`
referencing an entity of type Y or a descendant of Y (checked at write time; error 1003).
Cardinality semantics as §6.2.

### 6.4 Constraints

Range, enum, pattern, and length constraints compile to write-time validation in the engine.
Engines MUST evaluate constraints from the schema version current at write time. Constraint
violation is error 1003 with a message naming the predicate and the violated constraint.

### 6.5 Compiled schema storage

Each successful compile inserts one `schema_defs` row: monotonically increasing `version`,
the complete SODL source text, and `created_at`. The compiled, machine-readable form
(predicate table) is NOT stored; engines MUST be able to re-derive it from the stored source.
A store with zero `schema_defs` rows is invalid except transiently during `silica init`, which
MUST seed schema version 1: the **starter ontology** — types `entity`, `decision`,
`preference`, `lesson`, `procedure` with the predicate sets published in
`examples/starter.sodl` of the reference repository.

## 7. Schema Evolution Rules

A compile against a store holding prior versions MUST validate the new schema against the
latest stored version and reject on violation (error 2002 + rule id). All rules are decidable
from the two schema texts alone.

- **E-1 (Append-only vocabulary)**: every type and every predicate present in version N MUST
  be present in version N+1. Removal and renaming are prohibited. Deprecation is expressed
  with a `@deprecated` annotation; deprecated predicates remain writable but compilers SHOULD
  warn.
- **E-2 (Widening-only reparenting)**: a type's parent may change in N+1 only to a proper
  ancestor of its parent in N. (Guarantees every subsumption query true under N stays true
  under N+1.)
- **E-3 (Loosening-only constraints)**: version N+1's constraint set for a predicate MUST
  accept every value version N accepted. Tightening requires introducing a new predicate.
- **E-4 (Kind stability)**: a predicate's JSON kind and its attribute/relation nature MUST
  never change. Cardinality may change only from `one` to `many`.

**Consequence (informative)**: E-1..E-4 jointly guarantee that any fact valid under any
historical version is valid and interpretable under the current version, which is what makes
both time-travel reads and the v1 fixed-layout compilation target (§12) possible.

## 8. Protocol Surface (MCP)

### 8.1 Transport

Engines MUST implement MCP over stdio: JSON-RPC 2.0, UTF-8, one message per line
(newline-delimited; messages MUST NOT contain unescaped newlines). Engines MUST implement
`initialize`, `tools/list`, and `tools/call`, and MUST declare only the `tools` capability in
v0. The `initialize` result `serverInfo.name` MUST be `"silica"`; `serverInfo.version` carries
the engine version. The result MUST additionally carry
`_meta: {"silica.tokenEstimator": "<method>"}` per §8.5.6.

### 8.2 Tool registry

Exactly four tools: `remember`, `recall`, `invalidate`, `log_event`. The JSON Schemas in
`contract/tools.json` are normative for request shape; this section is normative for
semantics. Adding, removing, or renaming tools requires a new RFC version. Tool descriptions
served by `tools/list` MUST be the texts in `contract/tools.json` verbatim: the descriptions
encode the write/read policy the client model is expected to follow and are part of the
contract.

### 8.3 `remember`

Input: `{type, name?, facts: [{predicate, value? | entity_ref?}], source?, store?}`.

Processing steps (normative order):

1. Resolve target store (§9.2); unknown explicit `store` → error 1006.
2. Validate `type` exists in the target store's current schema → else error 1001.
3. Resolve the entity: if `name` given, find non-deleted `(type, name)`; create if absent.
   If `name` omitted, always create a new anonymous entity.
4. For each fact: validate predicate declared for the type or an ancestor (error 1002);
   validate XOR of `value`/`entity_ref` (error 1003); validate value against kind and
   constraints (error 1003). `entity_ref` is either `"name"` or `"type:name"`; a bare name
   matching entities of multiple types is error 1009 (AMBIGUOUS_REF); no match is error 1004.
5. Apply implicit supersession for cardinality-`one` predicates (§6.2).
6. Insert source (or synthesize, §5.4), entity if new, and all facts in **one transaction**.

Result: `{entity_id, fact_ids: [...], superseded: [{fact_id, by}...]}`.

### 8.4 `invalidate`

Input: `{fact_id, reason}`. The fact MUST exist (error 1004) and MUST be currently visible
(already-invalidated → error 1005). The engine sets `invalidated_at = now`, leaves
`invalidated_by` NULL (no replacement), and appends an `events` row
`{kind: "invalidation", payload: {fact_id, reason}}` in the same transaction — the reason
lives in the event log, keeping `facts` schema-pure. Result: `{invalidated_at}`.

### 8.5 `recall`

Input: `{query, type?, limit?=10, max_tokens?=800, as_of?, stores?}`.

1. **Store set**: the context store plus every mounted store visible under policy (§9.4);
   intersected with `stores` if given (unknown name → error 1006).
2. **Visibility instant**: `as_of` if present, else now. Time-travel reads (`as_of` set) MUST
   bypass the FTS index (which holds only currently-visible facts, per T-2) and scan with the
   §5.3 rule; engines MAY answer them slowly.
3. **Matching (current-time path)**: query the unified FTS index across attached stores with
   the raw query string as an FTS5 MATCH expression; engines MUST escape user input such that
   FTS5 syntax errors are impossible (treat as quoted phrase terms, OR-joined).
4. **Subsumption**: a `type` filter matches entities of that type and all transitive
   descendants (computed from `type_defs` of each store).
5. **Ranking**: entities are scored `min(bm25(facts_fts))` over their matched facts
   (lower = better) and returned ascending. Ties break by most recent `asserted_at`, then by
   fact id. Ranking MUST be deterministic: identical store contents and query MUST yield
   identical ordering.
6. **Token budget**: the serialized `results` array MUST NOT exceed `max_tokens` as measured
   by the engine's declared estimator. The REQUIRED baseline estimator is
   `ceil(utf8_bytes / 4)`; engines MAY substitute a real tokenizer, declared in `_meta`
   (§8.1). Whole entities (entity header + its visible matched facts + provenance) are
   appended in rank order while the budget holds; the first entity, if alone over budget, is
   included with facts truncated in rank order and `"truncated": true` set.
7. Result: `{results: [{entity: {id, type, name}, facts: [{id, predicate, value|entity_ref,
   asserted_at}], score, provenance: {store, kind, ref, occurred_at}}], token_estimate,
   truncated?}`. Superseded facts MUST NOT appear unless `as_of` reads select them.

### 8.6 `log_event`

Input: `{kind, payload, actor?}`; `actor` defaults to the MCP client name. Appends to the
context store's `events`. Result: `{event_id}`.

## 9. Multi-Store: Routing, Federation, Policy

### 9.1 Mounts and the routes file

Mounted stores are declared in `~/.silica/routes.sodl` (path overridable by
`SILICA_ROUTES`). Grammar (EBNF):

```
routes      = { store_decl | policy_decl } ;
store_decl  = "store" ident "{" "path" ":" string
              [ "," "default" ":" bool ]
              [ "," "match" "{" "remote" ":" glob "}" ] "}" ;
policy_decl = "policy" ident "{" "from" ":" ident ","
              "types" ":" ( "*" | "[" ident { "," ident } "]" ) ","
              "to" ":" ( "*" | "none" | ident ) "}" ;
ident       = lowercase, alnum/underscore, per §4.3 ;
```

Exactly one store MUST carry `default: true` (error 3001 otherwise). All `path`s MUST be
distinct after expansion. If the routes file is absent, the implicit configuration is a single
default store at `~/.silica/personal.silica`.

### 9.2 Write routing (normative algorithm)

The **context store** for a process is resolved once at startup and cached:

1. If a tool call carries `store`, that store is used *for that call* (must be mounted,
   error 1006).
2. Else, obtain the repository remote: run the equivalent of
   `git config --get remote.origin.url` from the process working directory; normalize by
   lowercasing, stripping scheme/credentials, converting `:` to `/` in scp-form URLs, and
   stripping a trailing `.git`. Evaluate `match.remote` globs **in file declaration order**;
   first match wins.
3. Else (no repo, or no rule matches): the default store.

The algorithm MUST NOT invoke a model, perform I/O beyond the git config read, or depend on
wall-clock time. Two invocations in the same directory with the same routes file MUST resolve
identically.

### 9.3 Read federation

Engines MUST implement cross-store `recall` with SQLite `ATTACH DATABASE` — one connection,
one query — rather than per-store queries merged in application code, so that FTS ranking is
computed under a single query plan. Attached stores are opened read-only. Store identity MUST
be preserved through to `provenance.store` in results.

### 9.4 Visibility policy (default-deny)

Policies govern **read visibility only**; no engine operation copies facts between stores.

Normative rule: in a recall whose context store is C, a fact from mounted store S ≠ C is
visible iff some policy has `from: S`, `to` equal to `*` or `C`, and `types` equal to `*` or
containing the fact's entity type or an ancestor of it. `to: none` declarations are
permitted for explicitness but are semantically inert (deny is the default). Facts from C are
always visible. Policy evaluation MUST occur inside the query (attached-store rows filtered by
type set), not by post-filtering serialized results.

### 9.5 Audit

`silica audit <store>` MUST report every recall in which a fact from `<store>` was returned
into a different context, with timestamp, context store, and matching policy. To support
this, engines MUST append an event `{kind: "cross_store_read", payload: {store, context,
policy, fact_ids}}` to the **context** store on every recall that returned foreign facts.

## 10. Performance Conformance

Measured by `silica bench` on the reference workload (3 stores, 100k facts total, published in
the repository). A release MUST NOT ship if it regresses a bound:

| Metric | Bound |
|---|---|
| `recall` latency, p95, current-time path | < 10 ms |
| Engine resident memory, idle, 3 stores mounted | < 20 MB |
| Empty store file size | < 100 KB |
| Engine binary size, release build | < 10 MB |

## 11. Error Code Registry

Errors are JSON-RPC error objects: `code` from this registry, `message` human-readable,
`data` structured details. Engine errors 1xxx, compiler 2xxx, configuration 3xxx.

| Code | Name | §
|---|---|---|
| 1001 | UNKNOWN_TYPE | 8.3 |
| 1002 | UNKNOWN_PREDICATE | 8.3 |
| 1003 | CONSTRAINT_VIOLATION (incl. bad JSON, XOR, kind, range) | 4.3, 6.4, 8.3 |
| 1004 | NOT_FOUND (fact or entity_ref) | 8.3, 8.4 |
| 1005 | ALREADY_INVALIDATED | 8.4 |
| 1006 | STORE_NOT_FOUND | 8.3, 8.5 |
| 1009 | AMBIGUOUS_REF | 8.3 |
| 1010 | NOT_A_SILICA_FILE | 4.1 |
| 1011 | FORMAT_VERSION_UNSUPPORTED | 4.1 |
| 2001 | ONTOLOGY_CYCLE | 6.1 |
| 2002 | EVOLUTION_VIOLATION (data names E-rule) | 7 |
| 3001 | ROUTES_INVALID | 9.1 |

## 12. Future Direction (informative, non-normative)

A later version specifies `silica compact`: compilation of a store snapshot into a
read-optimized, mmap-able arena with fixed, C-ABI-compatible record layouts derived from the
SODL schema. The additive-only evolution rules of §7 are what make a fixed layout per schema
version sound. SQLite remains the sole write path; the arena is derived and regenerable.
Nothing in this section relaxes any requirement above.

## 13. Conformance

An implementation is a **conforming silica engine** iff it: implements §4 byte-compatibly
(verifiable by opening its output with stock sqlite3 and running the conformance SQL suite);
implements all four tools with §8 semantics; enforces invariants I-1..I-7; implements §9
routing/federation/policy; passes the published conformance test vectors (request/response
pairs, to live at `conformance/` in the reference repository); and meets §10 on the reference
workload. A **conforming SODL compiler** implements §6 and §7 and rejects every negative test
vector with the specified error code.

## 14. Security Considerations

Stores are plaintext SQLite files; confidentiality is delegated to filesystem permissions and
full-disk encryption (I-4 deliberately excludes format-layer encryption in v0). The isolation
guarantee of §9 is *physical* for writes (a store never receives foreign facts) and
*policy-mediated* for reads; the audit log (§9.5) exists because read-side policy is the sole
soft boundary. FTS MATCH input MUST be escaped per §8.5(3) to prevent query-syntax injection.
Engines MUST treat `entity_ref` and `store` parameters as data, never as file paths.

## Appendix A — Normative artifacts in this repository

- `sql/schema.sql` — normative DDL (§4.2), smoke-tested.
- `contract/tools.json` — normative request schemas and tool descriptions (§8.2).
- `examples/routes.sodl` — canonical routes/policy example (§9.1).
- `examples/starter.sodl` — starter ontology predicate sets (§6.5). *(to be added)*
