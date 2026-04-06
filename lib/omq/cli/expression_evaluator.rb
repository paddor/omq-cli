# frozen_string_literal: true

module OMQ
  module CLI
    # Compiles and evaluates a single Ruby expression string for use in
    # --recv-eval / --send-eval. Handles BEGIN{}/END{} block extraction,
    # proc compilation, and result normalisation.
    #
    # One instance per direction (send or recv).
    #
    class ExpressionEvaluator
      attr_reader :begin_proc, :end_proc, :eval_proc

      # Sentinel: eval proc returned the context object, meaning it already
      # sent the reply itself.
      SENT = Object.new.freeze


      # @param src [String, nil]  the raw expression string (may include BEGIN{}/END{})
      # @param format [Symbol]    the active format, used to normalise results
      # @param fallback_proc [Proc, nil]  registered OMQ.outgoing/incoming handler;
      #   used only when +src+ is nil (no inline expression)
      #
      def initialize(src, format:, fallback_proc: nil)
        @format = format

        if src
          expr, begin_body, end_body = extract_blocks(src)
          @begin_proc = eval("proc { #{begin_body} }") if begin_body # rubocop:disable Security/Eval
          @end_proc   = eval("proc { #{end_body} }")   if end_body   # rubocop:disable Security/Eval
          if expr && !expr.strip.empty?
            @eval_proc = eval("proc { $_ = $F&.first; #{expr} }") # rubocop:disable Security/Eval
          end
        elsif fallback_proc
          @eval_proc = proc { |msg| $_ = msg&.first; fallback_proc.call(msg) }
        end
      end


      # Runs the eval proc against +parts+ using +context+ as self.
      # Returns the normalised result Array, nil (filter/skip), or SENT.
      #
      def call(parts, context)
        return parts unless @eval_proc

        $F     = parts
        result = context.instance_exec(parts, &@eval_proc)
        return nil  if result.nil?
        return SENT if result.equal?(context)
        return [result] if @format == :marshal

        case result
        when Array  then result
        when String then [result]
        else             [result.to_str]
        end
      rescue => e
        $stderr.puts "omq: eval error: #{e.message} (#{e.class})"
        exit 3
      end


      # Normalises an eval result to nil (skip) or an Array of strings.
      # Used inside Ractor worker blocks where instance methods are unavailable.
      #
      def self.normalize_result(result)
        case result
        when nil    then nil
        when Array  then result
        when String then [result]
        else             [result.to_s]
        end
      end


      # Compiles begin/end/eval procs inside a Ractor from a raw expression
      # string. Returns [begin_proc, end_proc, eval_proc], any may be nil.
      #
      # Must be called inside the Ractor block (Procs are not Ractor-shareable).
      #
      def self.compile_inside_ractor(src)
        return [nil, nil, nil] unless src

        extract = ->(expr, kw) {
          s = expr.index(/#{kw}\s*\{/)
          return [expr, nil] unless s
          ci = expr.index("{", s); depth = 1; j = ci + 1
          while j < expr.length && depth > 0
            depth += 1 if expr[j] == "{"; depth -= 1 if expr[j] == "}"
            j += 1
          end
          [expr[0...s] + expr[j..], expr[(ci + 1)..(j - 2)]]
        }

        expr, begin_body = extract.(src, "BEGIN")
        expr, end_body   = extract.(expr, "END")

        begin_proc = eval("proc { #{begin_body} }") if begin_body # rubocop:disable Security/Eval
        end_proc   = eval("proc { #{end_body} }")   if end_body   # rubocop:disable Security/Eval
        eval_proc  = nil
        if expr && !expr.strip.empty?
          ractor_expr = expr.gsub(/\$F\b/, "__F")
          eval_proc   = eval("proc { |__F| $_ = __F&.first; #{ractor_expr} }") # rubocop:disable Security/Eval
        end

        [begin_proc, end_proc, eval_proc]
      end


      private


      def extract_blocks(expr)
        expr, begin_body = extract_block(expr, "BEGIN")
        expr, end_body   = extract_block(expr, "END")
        [expr, begin_body, end_body]
      end


      def extract_block(expr, keyword)
        start = expr.index(/#{keyword}\s*\{/)
        return [expr, nil] unless start

        i     = expr.index("{", start)
        depth = 1
        j     = i + 1
        while j < expr.length && depth > 0
          case expr[j]
          when "{" then depth += 1
          when "}" then depth -= 1
          end
          j += 1
        end

        body    = expr[(i + 1)..(j - 2)]
        trimmed = expr[0...start] + expr[j..]
        [trimmed, body]
      end
    end
  end
end
