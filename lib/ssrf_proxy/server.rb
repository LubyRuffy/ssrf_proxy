# coding: utf-8
#
# Copyright (c) 2015-2016 Brendan Coles <bcoles@gmail.com>
# SSRF Proxy - https://github.com/bcoles/ssrf_proxy
# See the file 'LICENSE.md' for copying permission
#

module SSRFProxy
  #
  # @note SSRFProxy::Server
  #
  class Server
    include Celluloid::IO
    finalizer :shutdown

    #
    # @note SSRFProxy::Server errors
    #
    module Error
      # custom errors
      class Error < StandardError; end
      exceptions = %w( InvalidSsrf ProxyRecursion AddressInUse )
      exceptions.each { |e| const_set(e, Class.new(Error)) }
    end

    #
    # @note Start the local server and listen for connections
    #
    # @options
    # - ssrf - SSRFProxy::HTTP - SSRF
    # - interface - String - Listen interface (Default: 127.0.0.1)
    # - port - Integer - Listen port (Default: 8081)
    #
    def initialize(ssrf, interface = '127.0.0.1', port = 8081)
      @max_request_len = 8192
      @logger = ::Logger.new(STDOUT).tap do |log|
        log.progname = 'ssrf-proxy-server'
        log.level = ::Logger::WARN
        log.datetime_format = '%Y-%m-%d %H:%M:%S '
      end
      # set ssrf
      unless ssrf.class == SSRFProxy::HTTP
        raise SSRFProxy::Server::Error::InvalidSsrf.new,
              'Invalid SSRF provided'
      end
      @ssrf = ssrf
      # start server
      logger.info "Starting HTTP proxy on #{interface}:#{port}"
      if ssrf.proxy && ssrf.proxy.host == interface && ssrf.proxy.port == port
        raise SSRFProxy::Server::Error::ProxyRecursion.new,
              "Proxy recursion error: #{ssrf.proxy}"
      end
      begin
        print_status "Listening on #{interface}:#{port}"
        @server = TCPServer.new(interface, port.to_i)
      rescue Errno::EADDRINUSE
        raise SSRFProxy::Server::Error::AddressInUse.new,
              "Could not bind to #{interface}:#{port} - address already in use"
      end
    end

    #
    # @note output status messages
    #
    def print_status(msg = '')
      puts '[*] '.blue + msg
    end

    #
    # @note output progress messages
    #
    def print_good(msg = '')
      puts '[+] '.green + msg
    end

    #
    # @note logger accessor
    #
    def logger
      @logger
    end

    #
    # @note Run proxy server
    #
    def serve
      loop { async.handle_connection(@server.accept) }
    end

    #
    # @note Handle shutdown of client socket
    #
    def shutdown
      logger.info 'Shutting down'
      @server.close if @server
      logger.debug 'Shutdown complete'
    end

    #
    # @note Handle client request
    #
    # @options
    # - socket - Celluloid::IO::TCPSocket - client socket
    #
    def handle_connection(socket)
      start_time = Time.now
      _, port, host = socket.peeraddr
      logger.debug("Client #{host}:#{port} connected")
      request = socket.readpartial(@max_request_len)
      logger.debug("Received client request (#{request.length} bytes):\n#{request}")
      if request.to_s =~ /\ACONNECT ([_a-zA-Z0-9\.\-]+:[\d]+) .*$/
        host = $1.to_s
        logger.info("Negotiating connection to #{host}")
        response = @ssrf.send_request("GET http://#{host}/ HTTP/1.0\n\n")
        if response =~ /^Server: SSRF Proxy$/i && response =~ /^Content-Length: 0$/i
          logger.warn("Connection to #{host} failed")
          socket.write("HTTP/1.0 502 Bad Gateway\r\n\r\n")
          socket.close
        else
          logger.info("Connected to #{host} successfully")
          socket.write("HTTP/1.0 200 Connection established\r\n\r\n")
          handle_connection(socket)
        end
      else
        response = @ssrf.send_request(request)
        socket.write(response)
        socket.close
        end_time = Time.now
        duration = end_time - start_time
        logger.info("Served #{response.length} bytes in #{(duration * 1000).round(3)} ms")
      end
    rescue EOFError, Errno::ECONNRESET
      socket.close
      logger.debug("Client #{host}:#{port} disconnected")
    end

    # private methods
    private :print_status,
            :print_good,
            :shutdown,
            :handle_connection
  end
end
