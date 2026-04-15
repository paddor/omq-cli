#!/bin/sh
# -P N: Ractor-based parallel runners for pull, pull+zstd, rep --echo,
# and gather. Each worker owns its own socket pair.

. "$(dirname "$0")/support.sh"

echo "Parallel PULL:"
U=$(ipc)
seq 10 | $OMQ push -b $U -t 5 2>>"$STDERR_LOG" &
PPUSH_PID=$!
sleep 0.5
$OMQ pull -c $U -P 2 -t 3 > $TMPDIR/ppull_out.txt 2>>"$STDERR_LOG" &
PPULL_PID=$!
wait $PPULL_PID 2>/dev/null || true
kill $PPUSH_PID 2>/dev/null || true; wait $PPUSH_PID 2>/dev/null || true
PPULL_CONTENT=$(cat $TMPDIR/ppull_out.txt | sort -n | tr '\n' ',')
check "pull -P2 receives all messages" "1,2,3,4,5,6,7,8,9,10," "$PPULL_CONTENT"

echo "Parallel PULL -z:"
U=$(ipc)
seq 10 | $OMQ push -b $U -z -t 5 2>>"$STDERR_LOG" &
PPUSHZ_PID=$!
sleep 0.5
$OMQ pull -c $U -P 2 -z -t 3 > $TMPDIR/ppullz_out.txt 2>>"$STDERR_LOG" &
PPULLZ_PID=$!
wait $PPULLZ_PID 2>/dev/null || true
kill $PPUSHZ_PID 2>/dev/null || true; wait $PPUSHZ_PID 2>/dev/null || true
PPULLZ_CONTENT=$(cat $TMPDIR/ppullz_out.txt | sort -n | tr '\n' ',')
check "pull -P2 -z decompresses correctly" "1,2,3,4,5,6,7,8,9,10," "$PPULLZ_CONTENT"

echo "Parallel REP --echo:"
U=$(ipc)
$OMQ rep -c $U -P 2 --echo -t 3 > /dev/null 2>>"$STDERR_LOG" &
PREP_PID=$!
sleep 0.5
PREP_OUT=$(seq 5 | $OMQ req -b $U -n 5 -t 3 2>>"$STDERR_LOG" | sort -n | tr '\n' ',')
kill $PREP_PID 2>/dev/null || true; wait $PREP_PID 2>/dev/null || true
check "rep -P2 --echo echoes all" "1,2,3,4,5," "$PREP_OUT"

echo "Parallel GATHER:"
U=$(ipc)
seq 10 | $OMQ scatter -b $U -t 5 2>>"$STDERR_LOG" &
PSCATTER_PID=$!
sleep 1
$OMQ gather -c $U -P 2 -t 3 > $TMPDIR/pgather_out.txt 2>>"$STDERR_LOG" &
PGATHER_PID=$!
wait $PGATHER_PID 2>/dev/null || true
kill $PSCATTER_PID 2>/dev/null || true; wait $PSCATTER_PID 2>/dev/null || true
PGATHER_CONTENT=$(cat $TMPDIR/pgather_out.txt | sort -n | tr '\n' ',')
check "gather -P2 receives all messages" "1,2,3,4,5,6,7,8,9,10," "$PGATHER_CONTENT"
