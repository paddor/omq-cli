# frozen_string_literal: true

module OMQ
  module CLI
    # Shared routing behaviour for socket types that address peers by ID
    # (ROUTER, SERVER). Include in a runner to get display_routing_id,
    # resolve_target, and a send_targeted_or_eval template method.
    #
    # Including class must implement #send_to_peer(routing_id, parts).
    #
    module RoutingHelper
      # Format a raw routing ID for display: printable ASCII as-is,
      # binary as a 0x-prefixed hex string.
      #
      def display_routing_id(id)
        if id.bytes.all? { |b| b >= 0x20 && b <= 0x7E }
          id
        else
          "0x#{id.unpack1("H*")}"
        end
      end


      # Decode a target string: 0x-prefixed hex is converted to binary,
      # plain strings are returned as-is.
      #
      def resolve_target(target)
        if target.start_with?("0x")
          [target[2..].delete(" ")].pack("H*")
        else
          target
        end
      end


      # Send +parts+ to a peer, routing by identity or eval result.
      #
      # Template method: calls #send_to_peer(id, parts) which the
      # including class must implement for its socket type.
      #
      def send_targeted_or_eval(parts)
        if @send_eval_proc
          parts = eval_send_expr(parts)
          return unless parts
          send_to_peer(resolve_target(parts.shift), parts)
        elsif config.target
          send_to_peer(resolve_target(config.target), parts)
        else
          send_msg(parts)
        end
      end
    end
  end
end
