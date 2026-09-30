#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Install paramiko in a disposable venv first; no test dependency is added to the app.
SSH_TEST_PYTHON="${SSH_TEST_PYTHON:-python3}"
"$SSH_TEST_PYTHON" -c 'import paramiko'
SSH_TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dbcenter-ssh-tests.XXXXXX")"
SSH_FIXTURE_PID=""
cleanup() { [ -z "$SSH_FIXTURE_PID" ] || kill "$SSH_FIXTURE_PID" 2>/dev/null || true; }
trap cleanup EXIT
"$SSH_TEST_PYTHON" scripts/ssh-fixture.py "$SSH_TEST_ROOT" > "$SSH_TEST_ROOT/ssh.log" 2>&1 &
SSH_FIXTURE_PID=$!
for attempt in {1..100}; do
    [ ! -f "$SSH_TEST_ROOT/port" ] || break
    sleep .1
done
export DBCENTER_SSH_TEST_PORT="$(cat "$SSH_TEST_ROOT/port")"
export DBCENTER_SSH_TEST_KEY="$SSH_TEST_ROOT/key"
export DBCENTER_SSH_TEST_ROOT="$SSH_TEST_ROOT"
export DBCENTER_SSH_INTEGRATION=1
./scripts/test-integration.sh
