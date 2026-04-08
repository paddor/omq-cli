# frozen_string_literal: true

module OMQ
  module CLI
    # Stateless helper for socket construction and configuration.
    # All methods are module-level so callers compose rather than inherit.
    #
    module SocketSetup
      # Apply common socket options from +config+ to +sock+.
      #
      def self.apply_options(sock, config)
        sock.linger             = config.linger
        sock.recv_timeout       = config.timeout       if config.timeout
        sock.send_timeout       = config.timeout       if config.timeout
        sock.reconnect_interval = config.reconnect_ivl if config.reconnect_ivl
        sock.heartbeat_interval = config.heartbeat_ivl if config.heartbeat_ivl
        sock.send_hwm           = config.send_hwm      if config.send_hwm
        sock.recv_hwm           = config.recv_hwm      if config.recv_hwm
        sock.sndbuf             = config.sndbuf        if config.sndbuf
        sock.rcvbuf             = config.rcvbuf        if config.rcvbuf
      end


      # Create and fully configure a socket from +klass+ and +config+.
      #
      def self.build(klass, config)
        sock = config.ffi ? klass.new(backend: :ffi) : klass.new
        sock.conflate = true if config.conflate && %w[pub radio].include?(config.type_name)
        apply_options(sock, config)
        sock.max_message_size = config.recv_maxsz if config.recv_maxsz
        sock.identity         = config.identity   if config.identity
        sock.router_mandatory = true if config.type_name == "router"
        sock
      end


      # Bind/connect +sock+ using URL strings from +config.binds+ / +config.connects+.
      #
      def self.attach(sock, config, verbose: false)
        config.binds.each do |url|
          sock.bind(url)
          $stderr.puts "Bound to #{sock.last_endpoint}" if verbose
        end
        config.connects.each do |url|
          sock.connect(url)
          $stderr.puts "Connecting to #{url}" if verbose
        end
      end


      # Bind/connect +sock+ from an Array of Endpoint objects.
      # Used by PipeRunner, which works with structured endpoint lists.
      #
      def self.attach_endpoints(sock, endpoints, verbose: false)
        endpoints.each do |ep|
          if ep.bind?
            sock.bind(ep.url)
            $stderr.puts "Bound to #{sock.last_endpoint}" if verbose
          else
            sock.connect(ep.url)
            $stderr.puts "Connecting to #{ep.url}" if verbose
          end
        end
      end


      # Subscribe or join groups on +sock+ according to +config+.
      #
      def self.setup_subscriptions(sock, config)
        case config.type_name
        when "sub"
          prefixes = config.subscribes.empty? ? [""] : config.subscribes
          prefixes.each { |p| sock.subscribe(p) }
        when "dish"
          config.joins.each { |g| sock.join(g) }
        end
      end


      # Configure CURVE encryption on +sock+ using +config+ and env vars.
      #
      def self.setup_curve(sock, config)
        server_key_z85 = config.curve_server_key || ENV["OMQ_SERVER_KEY"]
        server_mode    = config.curve_server || (ENV["OMQ_SERVER_PUBLIC"] && ENV["OMQ_SERVER_SECRET"])

        return unless server_key_z85 || server_mode

        crypto = CLI.load_curve_crypto(config.crypto || ENV["OMQ_CRYPTO"], verbose: config.verbose >= 1)
        require "protocol/zmtp/mechanism/curve"

        if server_key_z85
          server_key = Protocol::ZMTP::Z85.decode(server_key_z85)
          client_key = crypto::PrivateKey.generate
          sock.mechanism = Protocol::ZMTP::Mechanism::Curve.client(
            public_key: client_key.public_key.to_s,
            secret_key: client_key.to_s,
            server_key: server_key,
            crypto: crypto
          )
        elsif server_mode
          if ENV["OMQ_SERVER_PUBLIC"] && ENV["OMQ_SERVER_SECRET"]
            server_pub = Protocol::ZMTP::Z85.decode(ENV["OMQ_SERVER_PUBLIC"])
            server_sec = Protocol::ZMTP::Z85.decode(ENV["OMQ_SERVER_SECRET"])
          else
            key        = crypto::PrivateKey.generate
            server_pub = key.public_key.to_s
            server_sec = key.to_s
          end
          sock.mechanism = Protocol::ZMTP::Mechanism::Curve.server(
            public_key: server_pub,
            secret_key: server_sec,
            crypto: crypto
          )
          $stderr.puts "OMQ_SERVER_KEY='#{Protocol::ZMTP::Z85.encode(server_pub)}'"
        end
      end
    end
  end
end
