#!/bin/sh
# omq pipe: recv-eval, fan-in, fan-out, HWM reconnect buffering,
# FIFO across source batches, producer-first delivery, compressed pipe.

. "$(dirname "$0")/support.sh"

echo "Pipe -e:"
$OMQ push -b ipc://@omq_pipe_in_$$ -D "piped" -d 0.5 -t 3 2>>"$STDERR_LOG" &
$OMQ pull -b ipc://@omq_pipe_out_$$ -n 1 -t 3 > $TMPDIR/pipe_e_out.txt 2>>"$STDERR_LOG" &
$OMQ pipe -c ipc://@omq_pipe_in_$$ -c ipc://@omq_pipe_out_$$ -e 'it.map(&:upcase)' -n 1 -t 3 2>>"$STDERR_LOG" &
wait
check "pipe -e transforms in pipeline" "PIPED" "$(cat $TMPDIR/pipe_e_out.txt)"

echo "Pipe fan-in:"
$OMQ push -b ipc://@omq_fanin_a_$$ -D "from_a" -d 0.5 -t 3 2>>"$STDERR_LOG" &
$OMQ push -b ipc://@omq_fanin_b_$$ -D "from_b" -d 0.5 -t 3 2>>"$STDERR_LOG" &
$OMQ pull -b ipc://@omq_fanin_out_$$ -n 2 -t 3 > $TMPDIR/fanin_out.txt 2>>"$STDERR_LOG" &
$OMQ pipe --in -c ipc://@omq_fanin_a_$$ -c ipc://@omq_fanin_b_$$ \
         --out -c ipc://@omq_fanin_out_$$ -e 'it.map(&:upcase)' -n 2 -t 3 2>>"$STDERR_LOG" &
wait
FANIN_LINES=$(wc -l < $TMPDIR/fanin_out.txt | tr -d ' ')
FANIN_CONTENT=$(sort $TMPDIR/fanin_out.txt | tr '\n' ',')
check "pipe fan-in receives from both sources" "2" "$FANIN_LINES"
check "pipe fan-in content" "FROM_A,FROM_B," "$FANIN_CONTENT"

# Work-stealing (not strict round-robin) distributes messages across
# peers. With only 2 messages, batching may send both to the first
# pump. Send enough messages that both sinks get some.
echo "Pipe fan-out:"
$OMQ pull -b ipc://@omq_fanout_a_$$ --transient -t 5 > $TMPDIR/fanout_a.txt 2>>"$STDERR_LOG" &
$OMQ pull -b ipc://@omq_fanout_b_$$ --transient -t 5 > $TMPDIR/fanout_b.txt 2>>"$STDERR_LOG" &
$OMQ pipe --in -b ipc://@omq_fanout_in_$$ \
         --out -c ipc://@omq_fanout_a_$$ -c ipc://@omq_fanout_b_$$ \
         -e 'it.map(&:upcase)' --transient -t 5 2>>"$STDERR_LOG" &
sleep 0.5
seq 20 | $OMQ push -c ipc://@omq_fanout_in_$$ -t 5 2>>"$STDERR_LOG"
wait
FANOUT_A=$(wc -l < $TMPDIR/fanout_a.txt 2>/dev/null | tr -d ' ')
FANOUT_B=$(wc -l < $TMPDIR/fanout_b.txt 2>/dev/null | tr -d ' ')
FANOUT_TOTAL=$((FANOUT_A + FANOUT_B))
if [ "$FANOUT_TOTAL" -eq 20 ] && [ "$FANOUT_A" -gt 0 ] && [ "$FANOUT_B" -gt 0 ]; then
  pass "pipe fan-out distributes to both sinks"
else
  fail "pipe fan-out distributes to both sinks" "20 total, both non-empty" "a=$FANOUT_A b=$FANOUT_B total=$FANOUT_TOTAL"
fi

# Use large messages (64KB each) so the kernel buffer fills up and
# creates real backpressure.  With --out --hwm 1, the pipe retains
# un-forwarded messages for a reconnecting consumer.
echo "Pipe send-hwm reconnect:"
PIPE_SRC="ipc://@omq_pipe_src_$$"
PIPE_DST="ipc://@omq_pipe_dst_$$"
$OMQ pipe -c $PIPE_SRC --out -c $PIPE_DST --hwm 1 --reconnect-ivl 0.1 -t 10 2>>"$STDERR_LOG" &
PIPE_PID=$!
sleep 0.5
$OMQ pull -b $PIPE_DST -n 2 -t 5 > $TMPDIR/pipe_c1.txt 2>>"$STDERR_LOG" &
C1_PID=$!
sleep 0.5
ruby -e '50.times { |i| puts "#{i}#{"X" * 65536}" }' \
  | $OMQ push -b $PIPE_SRC -t 5 2>>"$STDERR_LOG" &
SRC_PID=$!
wait $C1_PID 2>/dev/null || true
sleep 1.5
$OMQ pull -b $PIPE_DST -n 3 -t 5 > $TMPDIR/pipe_c2.txt 2>>"$STDERR_LOG" &
C2_PID=$!
if wait $C2_PID 2>/dev/null; then
  C2_LINES=$(wc -l < $TMPDIR/pipe_c2.txt | tr -d ' ')
  check "consumer 2 receives after consumer 1 exits" "3" "$C2_LINES"
else
  fail "consumer 2 receives after consumer 1 exits" "3 messages" "timeout"
fi
kill $PIPE_PID $SRC_PID 2>/dev/null || true
wait 2>/dev/null || true

echo "Pipe FIFO ordering:"
FIFO_SRC="ipc://@omq_fifo_src_$$"
FIFO_DST="ipc://@omq_fifo_dst_$$"
# Pipe with --out --hwm 1 to create backpressure.
$OMQ pipe -c $FIFO_SRC --out -c $FIFO_DST --hwm 1 --reconnect-ivl 0.1 -t 10 2>>"$STDERR_LOG" &
FIFO_PIPE_PID=$!
sleep 0.3

# Send batch A (messages A0..A9, 64KB each) then batch B (B0..B9).
ruby -e '10.times { |i| puts "A#{i}#{"X" * 65536}" }' \
  | $OMQ push -b $FIFO_SRC -t 5 2>>"$STDERR_LOG"
sleep 0.3
ruby -e '10.times { |i| puts "B#{i}#{"Y" * 65536}" }' \
  | $OMQ push -b $FIFO_SRC -t 5 2>>"$STDERR_LOG"
sleep 0.3

# Consumer pulls 10 messages -- should be A0..A9 in order, no B's mixed in.
$OMQ pull -b $FIFO_DST --hwm 1 -n 10 -t 5 > $TMPDIR/fifo_out.txt 2>>"$STDERR_LOG" &
FIFO_C_PID=$!
if wait $FIFO_C_PID 2>/dev/null; then
  FIFO_PREFIXES=$(sed 's/[XY].*//' $TMPDIR/fifo_out.txt | tr '\n' ',')
  if [ "$FIFO_PREFIXES" = "A0,A1,A2,A3,A4,A5,A6,A7,A8,A9," ]; then
    pass "pipe preserves FIFO across source batches"
  else
    fail "pipe preserves FIFO across source batches" "A0,A1,...,A9" "$FIFO_PREFIXES"
  fi
else
  fail "pipe preserves FIFO across source batches" "10 messages" "timeout"
fi
kill $FIFO_PIPE_PID 2>/dev/null || true
wait 2>/dev/null || true

echo "Pipe producer-first:"
PF_SRC="ipc://@omq_pf_src_$$"
PF_DST="ipc://@omq_pf_dst_$$"
$OMQ pipe -c $PF_SRC --out -c $PF_DST --hwm 1 --reconnect-ivl 0.1 -t 10 2>>"$STDERR_LOG" &
PF_PIPE_PID=$!
sleep 0.3

# Producer sends BEFORE consumer exists -- pipe must buffer and deliver.
seq 5 | $OMQ push -b $PF_SRC -t 5 2>>"$STDERR_LOG"
sleep 0.5

$OMQ pull -b $PF_DST -n 5 -t 5 > $TMPDIR/pf_out.txt 2>>"$STDERR_LOG" &
PF_C_PID=$!
if wait $PF_C_PID 2>/dev/null; then
  PF_CONTENT=$(cat $TMPDIR/pf_out.txt | tr '\n' ',')
  check "pipe delivers all messages when producer finishes first" "1,2,3,4,5," "$PF_CONTENT"
else
  fail "pipe delivers all messages when producer finishes first" "5 messages" "timeout"
fi
kill $PF_PIPE_PID 2>/dev/null || true
wait 2>/dev/null || true

echo "Pipe -z:"
ZC_SRC="ipc://@omq_zc_src_$$"
ZC_DST="ipc://@omq_zc_dst_$$"
$OMQ pipe --in -c $ZC_SRC --out -c $ZC_DST -z --reconnect-ivl 0.1 -t 10 2>>"$STDERR_LOG" &
ZC_PIPE_PID=$!
sleep 0.3

$OMQ pull -b $ZC_DST -z -n 3 -t 5 > $TMPDIR/zc_out.txt 2>>"$STDERR_LOG" &
ZC_C_PID=$!
seq 3 | $OMQ push -b $ZC_SRC -z -t 5 2>>"$STDERR_LOG"
if wait $ZC_C_PID 2>/dev/null; then
  ZC_CONTENT=$(cat $TMPDIR/zc_out.txt | tr '\n' ',')
  check "pipe -z end-to-end" "1,2,3," "$ZC_CONTENT"
else
  fail "pipe -z end-to-end" "3 messages" "timeout"
fi
kill $ZC_PIPE_PID 2>/dev/null || true
wait 2>/dev/null || true
