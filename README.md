# silicadb

Typed, auditable agent memory in one file. No server, no meter, no silent facts.

- **One `.silica` file** — SQLite under the hood; your memory opens in stock `sqlite3` in 2036.
- **Schema-enforced** (SODL): unknown predicates are rejected, not silently absorbed.
- **Bitemporal supersession**: facts are never updated, only superseded — `silica history` shows *why* memory changed.
- **Token-capped recall** over MCP: ~200 tokens instead of a 40k-token CLAUDE.md re-read, every session.
- **Scoped stores + default-deny sync policy**: personal / work contexts physically isolated.

Status: pre-v0. Contract-first — see [SPEC.md](SPEC.md). The spec, schema (`sql/schema.sql`,
tested), and MCP tool contract (`contract/tools.json`) are locked; the Zig engine lands next.
