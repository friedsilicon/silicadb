# silicadb

Metal-first memory daemon for AI sessions. Binary protocol, append-only log,
semantic triples. No JSON, no dependencies. See [SPEC.md](SPEC.md) for the
protocol and storage format, [DECISIONS.md](DECISIONS.md) for why things are
the way they are.

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
silica get myproj/arch
silica ls myproj/
silica link myproj/arch refines myproj/goals
silica links myproj/arch
silica stats
```

Kinds: `note fact pref project ref`. Body from args or stdin. All state lives
in one portable file: `~/.silicadb/memory.log` (override with
`$SILICADB_HOME`).
