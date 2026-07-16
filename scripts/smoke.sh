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

"$BIN"/silica rm proj/greeting
if "$BIN"/silica get proj/greeting 2>/dev/null; then
    echo "FAIL: expected miss after rm"
    exit 1
fi

# restart: state must replay from log
kill "$PID"
wait "$PID" 2>/dev/null || true
start_daemon

test "$("$BIN"/silica get proj/other)" = "second value"
"$BIN"/silica links proj/greeting | grep -q refines
"$BIN"/silica links proj/greeting | grep cites | grep -q 'w=0.50'
"$BIN"/silica stats | grep -q '^keys: 1$'

echo "SMOKE OK"
