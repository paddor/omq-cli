# Shared setup for omq system tests. Sourced by every test/system/*_test.sh
# file. Provides: TMPDIR, OMQ, T, STDERR_LOG, pass/fail/check, ipc().
#
# Each test file runs independently. When TMPDIR and PASS/FAIL are already
# set in the environment (run_all.sh aggregation), we reuse them; otherwise
# we create a fresh TMPDIR and install an EXIT trap that prints the
# per-file summary and cleans up.

set -eu

SYSTEM_DIR=$(cd "$(dirname "$0")" && pwd)
CLI_ROOT=$(cd "$SYSTEM_DIR/../.." && pwd)
cd "$CLI_ROOT"

export OMQ_DEV=1
OMQ="bundle exec ruby -Ilib exe/omq"
T="-t 1"

if [ -z "${TMPDIR_SYSTEM:-}" ]; then
  TMPDIR_SYSTEM=$(mktemp -d)
  OWN_TMPDIR=1
else
  OWN_TMPDIR=0
fi
TMPDIR="$TMPDIR_SYSTEM"
export TMPDIR TMPDIR_SYSTEM

PASS=0
FAIL=0

STDERR_LOG="$TMPDIR/stderr.log"
: > "$STDERR_LOG"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() {
  echo "  FAIL: $1 -- expected: '$2', got: '$3'"
  if [ -s "$STDERR_LOG" ]; then
    echo "        stderr: $(cat "$STDERR_LOG")"
  fi
  FAIL=$((FAIL + 1))
}

check() {
  name="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    pass "$name"
  else
    fail "$name" "$expected" "$actual"
  fi
  : > "$STDERR_LOG"
}

# Unique IPC name per call (abstract namespace, no file cleanup).
# Counter persists across $(ipc) subshells via a file.
IPC_CTR="$TMPDIR/ipc_ctr"
[ -f "$IPC_CTR" ] || echo 0 > "$IPC_CTR"
ipc() {
  N=$(cat "$IPC_CTR")
  N=$((N + 1))
  echo "$N" > "$IPC_CTR"
  echo "ipc://@omq_test_${$}_${N}"
}

system_test_cleanup() {
  rc=$?
  if [ "$FAIL" -eq 0 ] && [ "$rc" -eq 0 ]; then
    [ "$OWN_TMPDIR" = "1" ] && rm -rf "$TMPDIR"
  else
    [ -s "$STDERR_LOG" ] && cat "$STDERR_LOG" >&2
  fi
  echo
  echo "Results: $PASS passed, $FAIL failed"
  if [ "$FAIL" -ne 0 ]; then
    exit 1
  fi
  exit "$rc"
}

trap system_test_cleanup EXIT
