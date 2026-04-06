# frozen_string_literal: true

require_relative "support"
require "securerandom"

# ── Parallel execution (-P) ──────────────────────────────────────────
#
# FIB expression (iterative, no method definition):
#   n = Integer($F.first); a,b = 0,1; n.times { a,b = b,a+b }; [a.to_s]
#
# fib(1..10) = [1, 1, 2, 3, 5, 8, 13, 21, 34, 55]  sum = 143
#
FIB_EXPR = "n=Integer($F.first);a,b=0,1;n.times{a,b=b,a+b};[a.to_s]".freeze
FIB_1_10 = [1, 1, 2, 3, 5, 8, 13, 21, 34, 55].freeze


# Unique inproc address per call to avoid cross-test interference.
def inproc_url(label) = "inproc://test-#{label}-#{SecureRandom.hex(4)}"


describe "pipe -P parallel execution" do
  it "routes all messages through workers and produces correct fib results" do
    OMQ::Transport::Inproc.reset!

    work_url    = inproc_url("pipe-work")
    results_url = inproc_url("pipe-results")
    n_msgs      = 10

    Async do |task|
      # recv_timeout: 1 causes worker PULLs to exit after the last message,
      # which lets runner_task finish without an explicit stop signal.
      src  = OMQ::PUSH.new(linger: 1); src.bind(work_url)
      sink = OMQ::PULL.new(linger: 0, recv_timeout: 3); sink.bind(results_url)

      cfg = make_config(
        type_name:     "pipe",
        in_endpoints:  [OMQ::CLI::Endpoint.new(work_url,    false)],
        out_endpoints: [OMQ::CLI::Endpoint.new(results_url, false)],
        parallel:      2,
        recv_expr:     FIB_EXPR,
        timeout:       1,
      )

      runner_task = task.async { OMQ::CLI::PipeRunner.new(cfg).call(task) }

      src.peer_connected.wait
      (1..n_msgs).each { |n| src.send([n.to_s]) }

      results = n_msgs.times.map { sink.receive&.first.to_i }.sort
      assert_equal FIB_1_10, results

      runner_task.wait
    ensure
      src&.close
      sink&.close
    end
  end

  it "applies BEGIN/END blocks once per worker" do
    OMQ::Transport::Inproc.reset!

    work_url    = inproc_url("pipe-begin-work")
    results_url = inproc_url("pipe-begin-results")

    # Expression: accumulate sum per worker, emit it at END.
    # Each worker receives some subset of 1..10 and sums them.
    # The total across all workers must equal 55 (sum of 1..10).
    # END emits after recv_timeout fires (workers see nil → exit loop → run END).
    expr = "BEGIN{ @s=0 } @s += Integer($F.first); nil END{ [$_=@s.to_s] }"

    Async do |task|
      src  = OMQ::PUSH.new(linger: 1); src.bind(work_url)
      sink = OMQ::PULL.new(linger: 0, recv_timeout: 3); sink.bind(results_url)

      cfg = make_config(
        type_name:     "pipe",
        in_endpoints:  [OMQ::CLI::Endpoint.new(work_url,    false)],
        out_endpoints: [OMQ::CLI::Endpoint.new(results_url, false)],
        parallel:      2,
        recv_expr:     expr,
        timeout:       1,
      )

      runner_task = task.async { OMQ::CLI::PipeRunner.new(cfg).call(task) }

      src.peer_connected.wait
      (1..10).each { |n| src.send([n.to_s]) }

      # END emits one result per worker after recv_timeout; sink.recv_timeout: 3
      # gives us up to 3 s to collect each before declaring a miss.
      partial_sums = 2.times.map { sink.receive&.first.to_i }
      assert_equal 55, partial_sums.sum

      runner_task.wait
    ensure
      src&.close
      sink&.close
    end
  end
end


describe "pull -P parallel recv-eval" do
  it "transforms all messages through N workers and outputs correct fib results" do
    OMQ::Transport::Inproc.reset!

    src_url = inproc_url("pull-p-src")
    n_msgs  = 10

    captured = StringIO.new
    orig_out = $stdout
    $stdout  = captured

    Async do |task|
      src = OMQ::PUSH.new(linger: 1); src.bind(src_url)

      # count: n_msgs terminates the collect loop after receiving all results,
      # then w.close injects nil to the workers so they exit promptly.
      cfg = make_config(
        type_name: "pull",
        connects:  [src_url],
        parallel:  2,
        recv_expr: FIB_EXPR,
        count:     n_msgs,
        timeout:   5,
      )

      runner_task = task.async { OMQ::CLI::PullRunner.new(cfg, OMQ::PULL).call(task) }

      src.peer_connected.wait
      (1..n_msgs).each { |n| src.send([n.to_s]) }

      runner_task.wait
    ensure
      src&.close
    end

    $stdout = orig_out
    results = captured.string.split("\n").map(&:to_i).sort
    assert_equal FIB_1_10, results
  end

  it "filters messages when expression returns nil" do
    OMQ::Transport::Inproc.reset!

    src_url = inproc_url("pull-p-filter")

    captured = StringIO.new
    orig_out = $stdout
    $stdout  = captured

    Async do |task|
      src = OMQ::PUSH.new(linger: 1); src.bind(src_url)

      # 10 inputs but only 5 even numbers pass the filter → count: 5
      cfg = make_config(
        type_name: "pull",
        connects:  [src_url],
        parallel:  2,
        recv_expr: "Integer($F.first).even? ? $F : nil",
        count:     5,
        timeout:   5,
      )

      runner_task = task.async { OMQ::CLI::PullRunner.new(cfg, OMQ::PULL).call(task) }

      src.peer_connected.wait
      (1..10).each { |n| src.send([n.to_s]) }

      runner_task.wait
    ensure
      src&.close
    end

    $stdout = orig_out
    results = captured.string.split("\n").map(&:to_i).sort
    assert_equal [2, 4, 6, 8, 10], results
  end
end
