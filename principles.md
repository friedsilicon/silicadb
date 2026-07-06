# silicadb principles

1. **Keep it metal.** Binary over text on every wire and every disk format.
   No JSON, no serialization frameworks. If a byte doesn't earn its place,
   it goes.

2. **Zero dependencies.** Standard library + POSIX only. A checkout and a Zig
   compiler must be enough to build and run everywhere.

3. **The log is the artifact.** All durable state lives in one append-only
   file. Copy it and you've migrated. Replay it and you've recovered. Nothing
   the daemon knows is unrecoverable from the log.

4. **Graph from day one.** Records are nodes, links are subject–predicate–
   object triples. The ontology grows out of use, not out of upfront schema
   design. Export formats (RDF, N-Triples) are projections, never the source
   of truth.

5. **Forward-compatible by construction.** TLV payloads; unknown tags are
   skipped, never errors. Old clients keep working against new servers.

6. **Simple beats clever until measured.** Brute-force scans and linear
   probes are fine until a real workload says otherwise. Optimize with
   numbers, not vibes.

7. **Every decision gets logged.** Any choice that shapes the protocol,
   storage format, or architecture gets a dated entry in
   [DECISIONS.md](DECISIONS.md) — including the options rejected and why.
   Reversals are new entries, not edits.
