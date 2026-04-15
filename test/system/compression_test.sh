#!/bin/sh
# Per-frame zstd compression (-z): large and small payload round-trips
# plus a wire-size trace check that a 1000-byte repeating payload
# compresses to significantly fewer bytes on the wire.

. "$(dirname "$0")/support.sh"

echo "Compression:"
U=$(ipc)
PAYLOAD=$(ruby -e "puts 'x' * 200")
$OMQ pull -b $U -n 1 -z $T > $TMPDIR/compress_out.txt 2>>"$STDERR_LOG" &
echo "$PAYLOAD" | $OMQ push -c $U -z $T 2>>"$STDERR_LOG"
wait
check "compression round-trip" "$PAYLOAD" "$(cat $TMPDIR/compress_out.txt)"

echo "Compression (small):"
U=$(ipc)
$OMQ pull -b $U -n 1 -z $T > $TMPDIR/compress_small_out.txt 2>>"$STDERR_LOG" &
echo 'tiny' | $OMQ push -c $U -z $T 2>>"$STDERR_LOG"
wait
check "compression round-trip (small)" "tiny" "$(cat $TMPDIR/compress_small_out.txt)"

# 1000 Zs should compress to far less than 1000 bytes; the pull side
# must log wire=NB with N < 1000.
echo "Compression wire size trace:"
U=$(ipc)
PAYLOAD=$(ruby -e "print 'Z' * 1000")
PULL_LOG="$TMPDIR/wire_pull.log"
$OMQ pull -b $U -n 1 -z -vvv $T > $TMPDIR/wire_out.txt 2>"$PULL_LOG" &
printf '%s' "$PAYLOAD" | $OMQ push -c $U -z $T 2>>"$STDERR_LOG"
wait

PULL_WIRE=$(grep -oE 'wire=[0-9]+B' "$PULL_LOG" | head -1 | grep -oE '[0-9]+' || echo "")

if [ -n "$PULL_WIRE" ] && [ "$PULL_WIRE" -lt 1000 ]; then
  pass "pull -vvv logs wire=${PULL_WIRE}B < 1000"
else
  fail "pull -vvv wire size" "<1000" "$PULL_WIRE"
  cat "$PULL_LOG" >&2
fi
