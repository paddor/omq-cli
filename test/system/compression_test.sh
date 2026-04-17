#!/bin/sh
# Per-frame zstd compression (-z): round-trips over zstd+tcp:// and a
# wire-size trace check that a repeating payload compresses to
# significantly fewer bytes on the wire.

. "$(dirname "$0")/support.sh"

# Helper: extract port from "bound to zstd+tcp://host:PORT" in a log file.
# Polls until the line appears (up to ~2 seconds).
extract_port() {
  _log="$1"
  _i=0
  while [ "$_i" -lt 20 ]; do
    _port=$(grep -oE 'bound to [^ ]+' "$_log" | head -1 | grep -oE '[0-9]+$' || true)
    if [ -n "$_port" ]; then
      echo "$_port"
      return 0
    fi
    sleep 0.1
    _i=$((_i + 1))
  done
  echo ""
}

# -- Round-trip: large payload ----------------------------------------

echo "Compression (large):"
PAYLOAD=$(ruby -e "puts 'x' * 200")
$OMQ rep -b tcp://127.0.0.1:0 -n 1 --echo -z -v $T > $TMPDIR/compress_out.txt 2>$TMPDIR/compress_rep.log &
REP_PID=$!
PORT=$(extract_port "$TMPDIR/compress_rep.log")
echo "$PAYLOAD" | $OMQ req -c tcp://127.0.0.1:$PORT -n 1 -z $T > $TMPDIR/compress_req_out.txt 2>>"$STDERR_LOG"
wait $REP_PID 2>/dev/null
check "compression round-trip" "$PAYLOAD" "$(cat $TMPDIR/compress_req_out.txt)"

# -- Round-trip: small payload ----------------------------------------

echo "Compression (small):"
$OMQ rep -b tcp://127.0.0.1:0 -n 1 --echo -z -v $T > /dev/null 2>$TMPDIR/compress_small_rep.log &
REP_PID=$!
PORT=$(extract_port "$TMPDIR/compress_small_rep.log")
echo 'tiny' | $OMQ req -c tcp://127.0.0.1:$PORT -n 1 -z $T > $TMPDIR/compress_small_out.txt 2>>"$STDERR_LOG"
wait $REP_PID 2>/dev/null
check "compression round-trip (small)" "tiny" "$(cat $TMPDIR/compress_small_out.txt)"

# -- Wire size trace: 2000 bytes should compress, receiver logs wire= -

echo "Compression wire size trace:"
PAYLOAD=$(ruby -e "print 'Z' * 2000")
REP_LOG="$TMPDIR/wire_rep.log"
$OMQ rep -b tcp://127.0.0.1:0 -n 1 --echo -z -vvv $T > /dev/null 2>"$REP_LOG" &
REP_PID=$!
PORT=$(extract_port "$REP_LOG")
printf '%s' "$PAYLOAD" | $OMQ req -c tcp://127.0.0.1:$PORT -n 1 -z $T > /dev/null 2>>"$STDERR_LOG"
wait $REP_PID 2>/dev/null

REP_WIRE=$(grep -oE 'wire=[0-9]+B' "$REP_LOG" | head -1 | grep -oE '[0-9]+' || echo "")

if [ -n "$REP_WIRE" ] && [ "$REP_WIRE" -lt 2000 ]; then
  pass "rep -vvvz logs wire=${REP_WIRE}B < 2000"
else
  fail "rep -vvvz wire size" "<2000" "${REP_WIRE:-<missing>}"
  cat "$REP_LOG" >&2
fi
