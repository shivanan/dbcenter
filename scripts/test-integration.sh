#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BREW_PREFIX="$(brew --prefix)"
PG="$BREW_PREFIX/opt/postgresql@18/bin"
MONGO="$BREW_PREFIX/opt/mongodb-community/bin/mongod"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dbcenter-tests.XXXXXX")"
REDIS_PID=""; MONGO_PID=""; HTTP_PID=""
cleanup() {
    [ -z "$REDIS_PID" ] || kill "$REDIS_PID" 2>/dev/null || true
    [ -z "$MONGO_PID" ] || kill "$MONGO_PID" 2>/dev/null || true
    [ -z "$HTTP_PID" ] || kill "$HTTP_PID" 2>/dev/null || true
    "$PG/pg_ctl" -D "$TEST_ROOT/pg" -m immediate stop >/dev/null 2>&1 || true
    # Keep logs in TEST_ROOT so failures can be diagnosed.
}
trap cleanup EXIT
"$PG/initdb" -D "$TEST_ROOT/pg" -U dbcenter_test -A trust --no-locale --encoding=UTF8 > "$TEST_ROOT/initdb.log"
"$PG/pg_ctl" -D "$TEST_ROOT/pg" -l "$TEST_ROOT/postgres.log" -o "-p 15439 -h 127.0.0.1 -k $TEST_ROOT" start
mkdir "$TEST_ROOT/mongo"
"$MONGO" --dbpath "$TEST_ROOT/mongo" --bind_ip 127.0.0.1 --port 27029 --logpath "$TEST_ROOT/mongo.log" > /dev/null 2>&1 &
MONGO_PID=$!
"$BREW_PREFIX/bin/redis-server" --bind 127.0.0.1 --port 16389 --save '' --appendonly no --dir "$TEST_ROOT" > "$TEST_ROOT/redis.log" 2>&1 &
REDIS_PID=$!
python3 scripts/influx-fixture.py > "$TEST_ROOT/influx.log" 2>&1 &
HTTP_PID=$!
python3 - <<'PY'
import socket,time
for port in [15439,27029,16389,18089]:
    for attempt in range(100):
        try:
            with socket.create_connection(('127.0.0.1',port),timeout=.2): break
        except OSError: time.sleep(.1)
    else: raise RuntimeError(f'Test server on {port} did not start')
PY
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/dbcenter-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/dbcenter-swift-cache"
DBCENTER_INTEGRATION=1 swift test --disable-sandbox
