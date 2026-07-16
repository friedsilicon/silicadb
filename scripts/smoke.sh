#!/bin/sh
# End-to-end smoke test: daemon + client + persistence across restart.
set -e

BIN=${BIN:-./zig-out/bin}
DIR=$(mktemp -d)
export SILICADB_HOME="$DIR"
PID=""
cleanup() {
    [ -n "$PID" ] && kill "$PID" 2>/dev/null
    rm -rf "$DIR"
}
trap cleanup EXIT

start_daemon() {
    "$BIN"/silicadbd &
    PID=$!
    i=0
    while [ ! -S "$DIR/silicadb.sock" ]; do
        i=$((i + 1))
        [ $i -gt 50 ] && { echo "daemon did not start"; exit 1; }
        sleep 0.1
    done
}

start_daemon

"$BIN"/silica ping >/dev/null

printf '%s' "hello metal" | "$BIN"/silica put proj/greeting -k note -t demo,smoke
test "$("$BIN"/silica get proj/greeting)" = "hello metal"

"$BIN"/silica put proj/other -k fact second value
test "$("$BIN"/silica get proj/other)" = "second value"

"$BIN"/silica ls proj/ | grep -q greeting
"$BIN"/silica link proj/greeting refines proj/other
"$BIN"/silica links proj/greeting | grep -q refines
"$BIN"/silica link proj/greeting cites proj/other -w 0.5 -s smoke
"$BIN"/silica links proj/greeting | grep cites | grep -q 'w=0.50'
"$BIN"/silica links proj/greeting | grep cites | grep -q 'src=smoke'
"$BIN"/silica stats | grep -q '^keys: 2$'
"$BIN"/silica stats | grep -q '^links: 2$'

# phase 2: predicate filter, bulk load, as-of reads
"$BIN"/silica links proj/greeting -p cites | grep -q cites
if "$BIN"/silica links proj/greeting -p refines | grep -q cites; then
    echo "FAIL: predicate filter leaked"
    exit 1
fi

printf 'put\tbulk/one\tfact\t\tloader\tbulk body one\nlink\tbulk/one\tcites\tproj/other\t0.25\tloader\n# comment\n' \
    | "$BIN"/silica load | grep -q 'loaded 1 records, 1 links'
test "$("$BIN"/silica get bulk/one)" = "bulk body one"
"$BIN"/silica links bulk/one -p cites | grep -q 'w=0.25'

sleep 1 # date +%s floors: keep prior puts strictly before T0
T0=$(date +%s)
sleep 1
"$BIN"/silica put proj/other -k fact third value
test "$("$BIN"/silica get proj/other)" = "third value"
test "$("$BIN"/silica get proj/other -a "$T0")" = "second value"

# phase 3: read-time decay, rollup, vector similarity
"$BIN"/silica links proj/greeting -p cites -d 1 | grep cites | grep -qv 'w=0.50'
"$BIN"/silica links proj/greeting -p cites | grep cites | grep -q 'w=0.50' # decay never mutates

for n in 1 2 3 4; do "$BIN"/silica link hub member "leaf/$n"; done
"$BIN"/silica links hub -r 4 | grep -q '(4 objects)'
"$BIN"/silica links hub -r 5 | grep -q 'leaf/1'

"$BIN"/silica put vec/a -k note -V 1,0 alpha
"$BIN"/silica put vec/b -k note -V 0,1 beta
"$BIN"/silica sim 1,0 -n 1 | grep -q vec/a
"$BIN"/silica sim '0.1,0.9' -n 1 | grep -q vec/b

"$BIN"/silica rm proj/greeting
if "$BIN"/silica get proj/greeting 2>/dev/null; then
    echo "FAIL: expected miss after rm"
    exit 1
fi

# restart: state must replay from log
kill "$PID"
wait "$PID" 2>/dev/null || true
start_daemon

test "$("$BIN"/silica get proj/other)" = "third value"
test "$("$BIN"/silica get proj/other -a "$T0")" = "second value"
"$BIN"/silica links proj/greeting | grep -q refines
"$BIN"/silica links proj/greeting | grep cites | grep -q 'w=0.50'
"$BIN"/silica sim 1,0 -n 1 | grep -q vec/a
"$BIN"/silica stats | grep -q '^keys: 4$'

echo "SMOKE OK"
