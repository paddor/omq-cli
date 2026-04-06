# frozen_string_literal: true

module OMQ
  module CLI
    # Runner for REQ sockets (synchronous request-reply client).
    class ReqRunner < BaseRunner
      private


      def run_loop(task)
        n = config.count
        i = 0
        sleep(config.delay) if config.delay
        loop do
          parts = read_next
          break unless parts
          parts = eval_send_expr(parts)
          next unless parts
          send_msg(parts)
          reply = recv_msg
          break if reply.nil?
          output(eval_recv_expr(reply))
          i += 1
          break if n && n > 0 && i >= n
          break if !config.interval && (config.data || config.file)
          wait_for_interval if config.interval
        end
      end


      def wait_for_interval
        wait = config.interval - (Time.now.to_f % config.interval)
        sleep(wait) if wait > 0
      end
    end


    # Runner for REP sockets (synchronous request-reply server).
    class RepRunner < BaseRunner
      private


      def run_loop(task)
        n = config.count
        i = 0
        loop do
          msg = recv_msg
          break if msg.nil?
          break unless handle_rep_request(msg)
          i += 1
          break if n && n > 0 && i >= n
        end
      end


      def handle_rep_request(msg)
        if config.recv_expr || @recv_eval_proc
          reply = eval_recv_expr(msg)
          unless reply.equal?(SENT)
            output(reply)
            send_msg(reply || [""])
          end
        elsif config.echo
          output(msg)
          send_msg(msg)
        elsif config.data || config.file || !config.stdin_is_tty
          reply = read_next
          return false unless reply
          output(msg)
          send_msg(reply)
        else
          abort "REP needs a reply source: --echo, --data, --file, -e, or stdin pipe"
        end
        true
      end
    end
  end
end
