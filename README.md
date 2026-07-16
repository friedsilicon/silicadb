# silicadb

Metal-first memory daemon for AI sessions. Binary protocol, append-only log,
weighted semantic graph. No JSON, no dependencies. See [SPEC.md](SPEC.md) for
the protocol and storage format, [DECISIONS.md](DECISIONS.md) for why things
are the way they are, and [ROADMAP.md](ROADMAP.md) for where this is going.

## Build & run

```sh
zig build                  # builds silicadbd (daemon) + silica (CLI) into zig-out/bin
zig build test             # unit smoke tests (wire, store, replay)
make check                 # end-to-end smoke test (daemon + CLI + restart)
./zig-out/bin/silicadbd &  # listens on ~/.silicadb/silicadb.sock
```

## Use

```sh
silica put myproj/arch -k fact -t design "server is poll(2), single thread"
silica get myproj/arch                      # -a <ts>: read as of a past instant
silica ls myproj/
silica link myproj/arch refines myproj/goals -w 0.8 -s session-42
silica links myproj/arch -p refines -d 7d   # filter by predicate, decay by age
silica links hub -r 4                       # roll up dense fan-out into one row
silica put myproj/emb -V 0.12,0.87,0.33 embedding demo
silica sim 0.1,0.9,0.3 -n 5                 # top-k by cosine similarity
silica load < dump.tsv                      # bulk ingest (sodl compiler contract)
silica stats
```

Kinds: `note fact pref project ref`. Body from args or stdin. All state lives
in one portable file: `~/.silicadb/memory.log` (override with
`$SILICADB_HOME`).
