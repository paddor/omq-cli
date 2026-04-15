#!/bin/sh
# PUB/SUB: topic prefix filtering, PUB -E generator mode, JSONL fan-out,
# and a pub->sub eval pipeline.

. "$(dirname "$0")/support.sh"

echo "PUB/SUB:"
U=$(ipc)
$OMQ sub -b $U -s "weather." -n 1 $T > $TMPDIR/sub_out.txt 2>>"$STDERR_LOG" &
$OMQ pub -c $U -E '"weather.nyc 72F"' $T 2>>"$STDERR_LOG"
wait
check "sub receives matching message" "weather.nyc 72F" "$(cat $TMPDIR/sub_out.txt)"

# PUB with -E and no stdin input should produce messages from the
# eval alone, same as REQ generator mode. Use -i to keep firing so
# SUB has time to subscribe before messages go out.
echo "PUB -E generator:"
U=$(ipc)
$OMQ sub -b $U -s "" -n 3 $T > $TMPDIR/sub_gen_out.txt 2>>"$STDERR_LOG" &
$OMQ pub -c $U -E '"tick"' -i 0.05 -n 3 $T 2>>"$STDERR_LOG"
wait
check "pub -E generator, sub receives N" "tick
tick
tick" "$(cat $TMPDIR/sub_gen_out.txt)"

echo "PUB/SUB eval JSONL:"
U=$(ipc)
$OMQ sub -b $U -J -n 1 $T > $TMPDIR/pubsub_jsonl_out.txt 2>>"$STDERR_LOG" &
$OMQ pub -c $U -E '%w(foo bar)' $T 2>>"$STDERR_LOG"
wait
check "pub -E array received as jsonl" '["foo","bar"]' "$(cat $TMPDIR/pubsub_jsonl_out.txt)"

echo "PUB/SUB eval pipe:"
U=$(ipc)
$OMQ sub -b $U -e 'it.first' -J -n 1 $T > $TMPDIR/pubsub_evalpipe_out.txt 2>>"$STDERR_LOG" &
$OMQ pub -c $U -E '%w(foo bar)' $T 2>>"$STDERR_LOG"
wait
check "pub -E to sub -e extracts first part" '["foo"]' "$(cat $TMPDIR/pubsub_evalpipe_out.txt)"
