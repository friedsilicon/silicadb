#!/bin/sh
# End-to-end smoke test: daemon + client + persistence across restart.
set -e

DIR=$(mktemp -d)
export SILICADB_HOME="$DIR"
PID=""
cleanup() {
    [ -n "$PID" ] && kill "$PID" 2>/dev/null
    rm -rf "$DIR"
}
trap cleanup EXIT

start_daemon() {
    ./silicadbd &
    PID=$!
    i=0
    while [ ! -S "$DIR/silicadb.sock" ]; do
        i=$((i + 1))
        [ $i -gt 50 ] && { echo "daemon did not start"; exit 1; }
        sleep 0.1
    done
}

start_daemon

./silica ping >/dev/null

printf '%s' "hello metal" | ./silica put proj/greeting -k note -t demo,smoke
test "$(./silica get proj/greeting)" = "hello metal"

./silica put proj/other -k fact second value
test "$(./silica get proj/other)" = "second value"

./silica ls proj/ | grep -q greeting
./silica link proj/greeting refines proj/other
./silica links proj/greeting | grep -q refines
./silica stats | grep -q '^keys: 2$'
./silica stats | grep -q '^links: 1$'

./silica rm proj/greeting
if ./silica get proj/greeting 2>/dev/null; then
    echo "FAIL: expected miss after rm"
    exit 1
fi

# restart: state must replay from log
kill "$PID"
wait "$PID" 2>/dev/null || true
start_daemon

test "$(./silica get proj/other)" = "second value"
./silica links proj/greeting | grep -q refines
./silica stats | grep -q '^keys: 1$'

echo "SMOKE OK"
