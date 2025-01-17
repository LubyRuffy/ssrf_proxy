# coding: utf-8
#
# Copyright (c) 2015-2016 Brendan Coles <bcoles@gmail.com>
# SSRF Proxy - https://github.com/bcoles/ssrf_proxy
# See the file 'LICENSE.md' for copying permission
#

module SSRFProxy
  #
  # @note SSRFProxy::HTTP
  #
  class HTTP
    #
    # @note SSRFProxy::HTTP errors
    #
    module Error
      # custom errors
      class Error < StandardError; end
      exceptions = %w(
        NoUrlPlaceholder
        InvalidSsrfRequest
        InvalidRequestMethod
        InvalidUpstreamProxy
        InvalidIpEncoding
        InvalidHttpRequest
        InvalidUriRequest )
      exceptions.each { |e| const_set(e, Class.new(Error)) }
    end

    #
    # @note SSRFProxy::HTTP
    #
    # @options
    # - url - String - SSRF URL with 'xxURLxx' placeholder
    # - opts - Hash - SSRF and HTTP connection options:
    #   - 'proxy'          => String
    #   - 'method'         => String
    #   - 'post_data'      => String
    #   - 'rules'          => String
    #   - 'ip_encoding'    => String
    #   - 'match'          => Regex
    #   - 'strip'          => String
    #   - 'decode_html'    => Boolean
    #   - 'guess_status'   => Boolean
    #   - 'guess_mime'     => Boolean
    #   - 'ask_password'   => Boolean
    #   - 'forward_cookies'=> Boolean
    #   - 'body_to_uri'    => Boolean
    #   - 'auth_to_uri'    => Boolean
    #   - 'cookies_to_uri' => Boolean
    #   - 'cookie'         => String
    #   - 'timeout'        => Integer
    #   - 'user_agent'     => String
    #   - 'insecure'       => Boolean
    #
    def initialize(url = '', opts = {})
      @banner = 'SSRF Proxy'
      @detect_waf = true
      @logger = ::Logger.new(STDOUT).tap do |log|
        log.progname = 'ssrf-proxy'
        log.level = ::Logger::WARN
        log.datetime_format = '%Y-%m-%d %H:%M:%S '
      end
      begin
        @ssrf_url = URI.parse(url.to_s)
      rescue URI::InvalidURIError
        raise SSRFProxy::HTTP::Error::InvalidSsrfRequest.new,
              'Invalid SSRF request specified.'
      end
      if @ssrf_url.scheme.nil? || @ssrf_url.host.nil? || @ssrf_url.port.nil?
        raise SSRFProxy::HTTP::Error::InvalidSsrfRequest.new,
              'Invalid SSRF request specified.'
      end
      if @ssrf_url.scheme !~ /\Ahttps?\z/
        raise SSRFProxy::HTTP::Error::InvalidSsrfRequest.new,
              'Invalid SSRF request specified. Scheme must be http(s).'
      end
      parse_options(opts)
    end

    #
    # @note parse configuration options
    #
    # @options
    # - opts - Hash - SSRF and HTTP connection options
    #
    def parse_options(opts = {})
      # SSRF configuration options
      @upstream_proxy = nil
      @method = 'GET'
      @post_data = ''
      @rules = []
      opts.each do |option, value|
        next if value.eql?('')
        case option
        when 'proxy'
          begin
            @upstream_proxy = URI.parse(value)
          rescue URI::InvalidURIError
            raise SSRFProxy::HTTP::Error::InvalidUpstreamProxy.new,
                  'Invalid upstream HTTP proxy specified.'
          end
          if @upstream_proxy.scheme !~ /\Ahttps?\z/
            raise SSRFProxy::HTTP::Error::InvalidUpstreamProxy.new,
                  'Invalid upstream HTTP proxy specified.'
          end
        when 'method'
          case value.to_s.downcase
          when 'get'
            @method = 'GET'
          when 'head'
            @method = 'HEAD'
          when 'delete'
            @method = 'DELETE'
          when 'post'
            @method = 'POST'
          when 'put'
            @method = 'PUT'
          else
            raise SSRFProxy::HTTP::Error::InvalidRequestMethod.new,
                  'Invalid SSRF request method specified. Method must be GET/HEAD/DELETE/POST/PUT.'
          end
        when 'post_data'
          @post_data = value.to_s
        when 'rules'
          @rules = value.to_s.split(/,/)
        end
      end
      if @ssrf_url.request_uri !~ /xxURLxx/ && @post_data.to_s !~ /xxURLxx/
        raise SSRFProxy::HTTP::Error::NoUrlPlaceholder.new,
              "You must specify a URL placeholder with 'xxURLxx' in the SSRF request"
      end

      # client request modification
      @ip_encoding = nil
      @forward_cookies = false
      @body_to_uri = false
      @auth_to_uri = false
      @cookies_to_uri = false
      opts.each do |option, value|
        next if value.eql?('')
        case option
        when 'ip_encoding'
          if value.to_s !~ /\A[a-z0-9_]+\z/i
            raise SSRFProxy::HTTP::Error::InvalidIpEncoding.new,
                  'Invalid IP encoding method specified.'
          end
          @ip_encoding = value.to_s
        when 'forward_cookies'
          @forward_cookies = true if value
        when 'body_to_uri'
          @body_to_uri = true if value
        when 'auth_to_uri'
          @auth_to_uri = true if value
        when 'cookies_to_uri'
          @cookies_to_uri = true if value
        end
      end

      # SSRF connection options
      @cookie = nil
      @timeout = 10
      @user_agent = 'Mozilla/5.0'
      @insecure = false
      opts.each do |option, value|
        next if value.eql?('')
        case option
        when 'cookie'
          @cookie = value.to_s
        when 'timeout'
          @timeout = value.to_i
        when 'user_agent'
          @user_agent = value.to_s
        when 'insecure'
          @insecure = true if value
        end
      end

      # HTTP response modification options
      @match_regex = '\\A(.+)\\z'
      @strip = []
      @decode_html = false
      @guess_status = false
      @guess_mime = false
      @ask_password = false
      opts.each do |option, value|
        next if value.eql?('')
        case option
        when 'match'
          @match_regex = value.to_s
        when 'strip'
          @strip = value.to_s.split(/,/)
        when 'decode_html'
          @decode_html = true if value
        when 'guess_status'
          @guess_status = true if value
        when 'guess_mime'
          @guess_mime = true if value
        when 'ask_password'
          @ask_password = true if value
        end
      end
    end

    #
    # @note output status messages
    #
    # @options
    # - msg - String - message to print
    #
    def print_status(msg = '')
      puts '[*] '.blue + msg
    end

    #
    # @note output progress messages
    #
    # @options
    # - msg - String - message to print
    #
    def print_good(msg = '')
      puts '[+] '.green + msg
    end

    #
    # @note logger accessor
    #
    # @returns - Logger - class logger object
    #
    def logger
      @logger
    end

    #
    # @note URL accessor
    #
    # @returns - String - SSRF URL
    #
    def url
      @ssrf_url
    end

    #
    # @note Host accessor
    #
    # @returns - String - SSRF host
    #
    def host
      @ssrf_url.host
    end

    #
    # @note Port accessor
    #
    # @returns - String - SSRF port
    #
    def port
      @ssrf_url.port
    end

    #
    # @note Cookie accessor
    #
    # @returns - String - SSRF request cookie
    #
    def cookie
      @cookie
    end

    #
    # @note Upstream proxy accessor
    #
    # @returns - URI - Upstream HTTP proxy
    #
    def proxy
      @upstream_proxy
    end

    #
    # @note Format a HTTP request as a URL and request via SSRF
    #
    # @options
    # - request - String - raw HTTP request
    #
    # @returns String - raw HTTP response headers and body
    #
    def send_request(request)
      if request.to_s !~ /\A[A-Z]{1,20} /
        logger.warn('Received malformed client HTTP request.')
        return "HTTP\/1.1 501 Error\nServer: #{@banner}\nContent-Length: 0\n\n"
      elsif request.to_s =~ /\ACONNECT ([^\s]+) .*$/
        logger.warn("CONNECT tunneling is not supported: #{$1}")
        return "HTTP\/1.1 501 Error\nServer: #{@banner}\nContent-Length: 0\n\n"
      elsif request.to_s =~ /\A(DEBUG|TRACE|TRACK|OPTIONS) /
        logger.warn("Client request method is not supported: #{$1}")
        return "HTTP\/1.1 501 Error\nServer: #{@banner}\nContent-Length: 0\n\n"
      end
      if request.to_s !~ %r{\A[A-Z]{1,20} https?://}
        if request.to_s =~ /^Host: ([^\s]+)\r?\n/
          logger.info("Using host header: #{$1}")
        else
          logger.warn('No host specified')
          return "HTTP\/1.1 501 Error\nServer: #{@banner}\nContent-Length: 0\n\n"
        end
      end
      opts = {}
      begin
        # parse client request
        req = WEBrick::HTTPRequest.new(WEBrick::Config::HTTP)
        req.parse(StringIO.new(request))
        if req.to_s =~ /^Upgrade: WebSocket/
          logger.warn("WebSocket tunneling is not supported: #{req.host}:#{req.port}")
          return "HTTP\/1.1 501 Error\nServer: #{@banner}\nContent-Length: 0\n\n"
        end
        uri = req.request_uri
        raise SSRFProxy::HTTP::Error::InvalidHttpRequest if uri.nil?
      rescue
        logger.info('Received malformed client HTTP request.')
        return "HTTP\/1.1 501 Error\nServer: #{@banner}\nContent-Length: 0\n\n"
      end

      # parse request body and move to uri
      if @body_to_uri && !req.body.nil?
        logger.debug("Parsing request body: #{req.body}")
        begin
          new_query = URI.decode_www_form(req.body)
          if req.query_string.nil?
            uri = "#{uri}?#{URI.encode_www_form(new_query)}"
          else
            URI.decode_www_form(req.query_string).each { |p| new_query << p }
            uri = "#{uri}&#{URI.encode_www_form(new_query)}"
          end
        rescue
          logger.warn('Could not parse request POST data')
        end
      end

      # move basic authentication credentials to uri
      if @auth_to_uri && !req.header.nil?
        req.header['authorization'].each do |header|
          next unless header.split(' ').first =~ /^basic$/i
          begin
            creds = header.split(' ')[1]
            user = Base64.decode64(creds).chomp
            logger.info "Using basic authentication credentials: #{user}"
            uri = uri.to_s.gsub!(%r{:(//)}, "://#{user}@")
          rescue
            logger.warn "Could not parse request authorization header: #{header}"
          end
          break
        end
      end

      # copy cookies to uri
      cookies = []
      if @cookies_to_uri && !req.cookies.nil? && !req.cookies.empty?
        logger.info "Parsing request cookies: #{req.cookies.join('; ')}"
        cookies = []
        begin
          req.cookies.each do |c|
            cookies << c.to_s.gsub(/;\z/, '').to_s unless c.nil?
          end
          query_string = uri.to_s.split('?')[1..-1]
          if query_string.empty?
            s = '?'
          else
            s = '&'
          end
          uri = "#{uri}#{s}#{cookies.join('&')}"
        rescue => e
          logger.warn "Could not parse request coookies: #{e}"
        end
      end

      # forward client cookies
      new_cookie = []
      new_cookie << @cookie unless @cookie.nil?
      if @forward_cookies
        req.cookies.each do |c|
          new_cookie << c.to_s
        end
      end
      unless new_cookie.empty?
        opts['cookie'] = new_cookie.uniq.join('; ').to_s
        logger.info("Using cookie: #{opts['cookie']}")
      end
      send_uri(uri, opts)
    end

    #
    # @note Fetch a URI via SSRF
    #
    # @options
    # - uri - URI - URI to fetch
    # - opts - Hash - request options (keys: cookie)
    #
    # @returns String - raw HTTP response headers and body
    #
    def send_uri(uri, opts = {})
      raise SSRFProxy::HTTP::Error::InvalidUriRequest if uri.nil?

      # send request
      status_msg = "Request  -> #{@method}"
      status_msg << " -> PROXY[#{@upstream_proxy.host}:#{@upstream_proxy.port}]" unless @upstream_proxy.nil?
      status_msg << " -> SSRF[#{@ssrf_url.host}:#{@ssrf_url.port}] -> URI[#{uri}]"
      print_status(status_msg)
      start_time = Time.now
      response = send_http_request(uri, opts)
      end_time = Time.now
      duration = end_time - start_time

      # parse response
      response = parse_http_response(response) unless response.class == Hash
      body = response['body'] || ''
      headers = response['headers']

      # advise client to close HTTP connection
      if headers =~ /^connection:.*$/i
        headers.gsub!(/^connection:.*$/i, 'Connection: close')
      else
        headers.gsub!(/\n\z/, "Connection: close\n\n")
      end

      # handle HTTP response for failed request
      if response['status'] == 'fail'
        status_msg = "Response <- #{response['code']}"
        status_msg << " <- PROXY[#{@upstream_proxy.host}:#{@upstream_proxy.port}]" unless @upstream_proxy.nil?
        status_msg << " <- SSRF[#{@ssrf_url.host}:#{@ssrf_url.port}] <- URI[#{uri}]"
        print_status(status_msg)
        return "#{headers}#{body}"
      end

      # guess mime type and add content-type header
      if @guess_mime
        content_type = guess_mime(File.extname(uri.to_s.split('?').first))
        unless content_type.nil?
          logger.info "Using content-type: #{content_type}"
          if headers =~ /^content\-type:.*$/i
            headers.gsub!(/^content\-type:.*$/i, "Content-Type: #{content_type}")
          else
            headers.gsub!(/\n\z/, "Content-Type: #{content_type}\n\n")
          end
        end
      end

      # match response content
      unless @match_regex.nil?
        matches = body.scan(/#{@match_regex}/m)
        if matches.length > 0
          body = matches.flatten.first.to_s
          logger.info("Response matches pattern '#{@match_regex}'")
        else
          body = ''
          logger.warn("Response does not match pattern '#{@match_regex}'")
        end
      end

      # decode HTML entities
      if @decode_html
        body = HTMLEntities.new.decode(
          body.encode(
            'UTF-8',
            :invalid => :replace,
            :undef   => :replace,
            :replace => '?'))
      end

      # set content length
      content_length = body.to_s.length
      if headers =~ /^transfer\-encoding:.*$/i
        headers.gsub!(/^transfer\-encoding:.*$/i, "Content-Length: #{content_length}")
      elsif headers =~ /^content\-length:.*$/i
        headers.gsub!(/^content\-length:.*$/i, "Content-Length: #{content_length}")
      else
        headers.gsub!(/\n\z/, "Content-Length: #{content_length}\n\n")
      end

      # prompt for password
      if @ask_password
        if response['code'].to_i == 401
          auth_uri = URI.parse(uri.to_s.split('?').first)
          realm = "#{auth_uri.host}:#{auth_uri.port}"
          headers.gsub!(/\n\z/, "WWW-Authenticate: Basic realm=\"#{realm}\"\n\n")
          logger.info "Added WWW-Authenticate header for realm: #{realm}"
        end
      end

      # return HTTP response
      logger.debug("Response:\n#{headers}#{body}")
      status_msg = "Response <- #{response['code']}"
      status_msg << " <- PROXY[#{@upstream_proxy.host}:#{@upstream_proxy.port}]" unless @upstream_proxy.nil?
      status_msg << " <- SSRF[#{@ssrf_url.host}:#{@ssrf_url.port}] <- URI[#{uri}]"
      status_msg << " -- TITLE[#{$1}]" if body[0..1024] =~ %r{<title>([^<]*)<\/title>}im
      status_msg << " -- SIZE[#{body.size} bytes]"
      print_good(status_msg)
      logger.info("Received #{body.size} bytes in #{(duration * 1000).round(3)} ms")
      "#{headers}#{body}"
    end

    #
    # @note Encode IP address of a given URL
    #
    # @options
    # - url - String - target url
    # - mode - String - encoding (int, ipv6, oct, hex, dotted_hex)
    #
    # @returns - String - encoded ip address
    #
    def encode_ip(url, mode)
      return if url.nil?
      new_host = nil
      host = URI.parse(url.to_s.split('?').first).host.to_s
      begin
        ip = IPAddress::IPv4.new(host)
      rescue
        logger.warn("Could not parse requested host as IPv4 address: #{host}")
        return
      end
      case mode
      when 'int'
        new_host = url.to_s.gsub(host, ip.to_u32.to_s)
      when 'ipv6'
        new_host = url.to_s.gsub(host, "[#{ip.to_ipv6}]")
      when 'oct'
        new_host = url.to_s.gsub(host, "0#{ip.to_u32.to_s(8)}")
      when 'hex'
        new_host = url.to_s.gsub(host, "0x#{ip.to_u32.to_s(16)}")
      when 'dotted_hex'
        res = ip.octets.map { |i| "0x#{i.to_s(16).rjust(2, '0')}" }.join('.')
        new_host = url.to_s.gsub(host, res.to_s) unless res.nil?
      else
        logger.warn("Invalid IP encoding: #{mode}")
      end
      new_host
    end

    #
    # @note Run a specified URL through SSRF rules
    #
    # @options
    # - url - String - request URL
    # - rules - String - comma separated list of rules
    #
    # @returns - String - modified request URL
    #
    def run_rules(url, rules)
      str = url.to_s
      return str if rules.nil?
      rules.each do |rule|
        case rule
        when 'noproto'
          str = str.gsub(%r{^https?://}, '')
        when 'nossl', 'http'
          str = str.gsub(%r{^https://}, 'http://')
        when 'ssl', 'https'
          str = str.gsub(%r{^http://}, 'https://')
        when 'base32'
          str = Base32.encode(str).to_s
        when 'base64'
          str = Base64.encode64(str).delete("\n")
        when 'md4'
          str = OpenSSL::Digest::MD4.hexdigest(str)
        when 'md5'
          md5 = Digest::MD5.new
          md5.update str
          str = md5.hexdigest
        when 'sha1'
          str = Digest::SHA1.hexdigest(str)
        when 'reverse'
          str = str.reverse
        when 'upcase'
          str = str.upcase
        when 'downcase'
          str = str.downcase
        when 'rot13'
          str = str.tr('A-Za-z', 'N-ZA-Mn-za-m')
        when 'urlencode'
          str = CGI.escape(str)
        when 'urldecode'
          str = CGI.unescape(str)
        else
          logger.warn("Unknown rule: #{rule}")
        end
      end
      str
    end

    #
    # @note Send HTTP request
    #
    # @options
    # - url - String - URI to fetch
    # - opts - Hash - request options (keys: cookie)
    #
    # @returns Hash of HTTP response (status, code, headers, body)
    #
    def send_http_request(url, opts = {})
      # use upstream proxy
      if @upstream_proxy.nil?
        http = Net::HTTP.new(@ssrf_url.host, @ssrf_url.port)
      else
        http = Net::HTTP::Proxy(@upstream_proxy.host, @upstream_proxy.port).new(@ssrf_url.host, @ssrf_url.port)
      end
      # encode target host ip
      target = (encode_ip(url, @ip_encoding) if @ip_encoding) || url
      # run target url through rules
      target = run_rules(target, @rules)
      # replace xxURLxx placeholder in SSRF HTTP GET parameters
      ssrf_url = "#{@ssrf_url.path}?#{@ssrf_url.query}".gsub(/xxURLxx/, target.to_s)
      # replace xxURLxx placeholder in SSRF HTTP POST parameters
      post_data = @post_data.gsub(/xxURLxx/, target.to_s) unless @post_data.nil?
      if @ssrf_url.scheme == 'https'
        http.use_ssl = true
        if @insecure
          http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        else
          http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        end
      end
      # set socket options
      http.open_timeout = @timeout
      http.read_timeout = @timeout
      # set request headers
      headers = {}
      headers['User-Agent'] = @user_agent unless @user_agent.nil?
      headers['Cookie'] = opts['cookie'].to_s unless opts['cookie'].nil?
      headers['Content-Type'] = 'application/x-www-form-urlencoded' if @method == 'POST'
      response = {}
      # send http request
      logger.info("Sending request: #{target}")
      begin
        if @method == 'GET'
          response = http.request Net::HTTP::Get.new(ssrf_url, headers.to_hash)
        elsif @method == 'HEAD'
          response = http.request Net::HTTP::Head.new(ssrf_url, headers.to_hash)
        elsif @method == 'DELETE'
          response = http.request Net::HTTP::Delete.new(ssrf_url, headers.to_hash)
        elsif @method == 'POST'
          request = Net::HTTP::Post.new(ssrf_url, headers.to_hash)
          request.body = post_data
          response = http.request(request)
        elsif @method == 'PUT'
          request = Net::HTTP::Put.new(ssrf_url, headers.to_hash)
          request.body = post_data
          response = http.request(request)
        else
          logger.info("SSRF request method not implemented - METHOD[#{@method}]")
          response['status']  = 'fail'
          response['code']    = 405
          response['message'] = 'Method not allowed'
          response['headers'] = "HTTP\/1.1 405 Method not allowed\nServer: #{@banner}\nContent-Length: 0\n\n"
        end
      rescue Timeout::Error, Errno::ETIMEDOUT
        logger.warn("Connection timeout - TIMEOUT[#{@timeout}] - URI[#{url}]\n")
        response['status']  = 'fail'
        response['code']    = 504
        response['message'] = 'Timeout'
        response['headers'] = "HTTP\/1.1 504 Error\nServer: #{@banner}\nContent-Length: 0\n\n"
      rescue => e
        response['status']  = 'fail'
        response['code']    = 500
        response['message'] = 'Error'
        response['headers'] = "HTTP\/1.1 500 Error\nServer: #{@banner}\nContent-Length: 0\n\n"
        logger.error("Unhandled exception: #{e.message}: #{e}")
      end
      response
    end

    #
    # @note Guess HTTP response status code and message based on common strings in the response body
    #
    # @options
    # - response - String - HTTP response
    #
    # @returns Hash - HTTP code and message
    #
    def guess_status(response)
      result = {}
      # generic page titles containing HTTP status
      if response =~ />400 Bad Request</
        result['code'] = 400
        result['message'] = 'Bad Request'
      elsif response =~ />401 Unauthorized</
        result['code'] = 401
        result['message'] = 'Unauthorized'
      elsif response =~ />403 Forbidden</
        result['code'] = 403
        result['message'] = 'Forbidden'
      elsif response =~ />404 Not Found</
        result['code'] = 404
        result['message'] = 'Not Found'
      elsif response =~ />500 Internal Server Error</
        result['code'] = 500
        result['message'] = 'Internal Server Error'
      elsif response =~ />503 Service Unavailable</
        result['code'] = 503
        result['message'] = 'Service Unavailable'
      # getaddrinfo() errors
      elsif response =~ /getaddrinfo: /
        if response =~ /getaddrinfo: nodename nor servname provided/
          result['code'] = 502
          result['message'] = 'Bad Gateway'
        elsif response =~ /getaddrinfo: Name or service not known/
          result['code'] = 502
          result['message'] = 'Bad Gateway'
        end
      # getnameinfo() errors
      elsif response =~ /getnameinfo failed: /
        result['code'] = 502
        result['message'] = 'Bad Gateway'
      # PHP 'failed to open stream' errors
      elsif response =~ /failed to open stream: /
        # HTTP request failed! HTTP/[version] [code] [message]
        if response =~ %r{failed to open stream: HTTP request failed! HTTP\/(0\.9|1\.0|1\.1) ([\d]+) }
          result['code'] = $2.to_s
          result['message'] = ''
          if response =~ %r{failed to open stream: HTTP request failed! HTTP/(0\.9|1\.0|1\.1) [\d]+ ([a-zA-Z ]+)}
            result['message'] = $2.to_s
          end
        # No route to host
        elsif response =~ /failed to open stream: No route to host in/
          result['code'] = 502
          result['message'] = 'Bad Gateway'
        # Connection refused
        elsif response =~ /failed to open stream: Connection refused in/
          result['code'] = 502
          result['message'] = 'Bad Gateway'
        # Connection timed out
        elsif response =~ /failed to open stream: Connection timed out/
          result['code'] = 504
          result['message'] = 'Timeout'
        # Success - This likely indicates an SSL/TLS connection failure
        elsif response =~ /failed to open stream: Success in/
          result['code'] = 502
          result['message'] = 'Bad Gateway'
        end
      # Java 'java.net' exceptions
      elsif response =~ /java\.net\.[^\s]*Exception: /
        if response =~ /java\.net\.ConnectException: No route to host/
          result['code'] = 502
          result['message'] = 'Bad Gateway'
        elsif response =~ /java\.net\.ConnectException: Connection refused/
          result['code'] = 502
          result['message'] = 'Bad Gateway'
        elsif response =~ /java\.net\.ConnectException: Connection timed out/
          result['code'] = 504
          result['message'] = 'Timeout'
        elsif response =~ /java\.net\.UnknownHostException: Invalid hostname/
          result['code'] = 502
          result['message'] = 'Bad Gateway'
        elsif response =~ /java\.net\.SocketException: Network is unreachable/
          result['code'] = 502
          result['message'] = 'Bad Gateway'
        elsif response =~ /java\.net\.SocketException: Connection reset/
          result['code'] = 502
          result['message'] = 'Bad Gateway'
        elsif response =~ /java\.net\.SocketTimeoutException: Connection timed out/
          result['code'] = 504
          result['message'] = 'Timeout'
        end
      # C errno
      elsif response =~ /\[Errno -?[\d]{1,3}\]/
        if response =~ /\[Errno -2\] Name or service not known/
          result['code'] = 502
          result['message'] = 'Bad Gateway'
        elsif response =~ /\[Errno 101\] Network is unreachable/
          result['code'] = 502
          result['message'] = 'Bad Gateway'
        elsif response =~ /\[Errno 104\] Connection reset by peer/
          result['code'] = 502
          result['message'] = 'Bad Gateway'
        elsif response =~ /\[Errno 110\] Connection timed out/
          result['code'] = 504
          result['message'] = 'Timeout'
        elsif response =~ /\[Errno 111\] Connection refused/
          result['code'] = 502
          result['message'] = 'Bad Gateway'
        elsif response =~ /\[Errno 113\] No route to host/
          result['code'] = 502
          result['message'] = 'Bad Gateway'
        end
      # Python urllib errors
      elsif response =~ /HTTPError: HTTP Error \d+/
        if response =~ /HTTPError: HTTP Error 400: Bad Request/
          result['code'] = 400
          result['message'] = 'Bad Request'
        elsif response =~ /HTTPError: HTTP Error 401: Unauthorized/
          result['code'] = 401
          result['message'] = 'Unauthorized'
        elsif response =~ /HTTPError: HTTP Error 402: Payment Required/
          result['code'] = 402
          result['message'] = 'Payment Required'
        elsif response =~ /HTTPError: HTTP Error 403: Forbidden/
          result['code'] = 403
          result['message'] = 'Forbidden'
        elsif response =~ /HTTPError: HTTP Error 404: Not Found/
          result['code'] = 404
          result['message'] = 'Not Found'
        elsif response =~ /HTTPError: HTTP Error 405: Method Not Allowed/
          result['code'] = 405
          result['message'] = 'Method Not Allowed'
        elsif response =~ /HTTPError: HTTP Error 410: Gone/
          result['code'] = 410
          result['message'] = 'Gone'
        elsif response =~ /HTTPError: HTTP Error 500: Internal Server Error/
          result['code'] = 500
          result['message'] = 'Internal Server Error'
        elsif response =~ /HTTPError: HTTP Error 502: Bad Gateway/
          result['code'] = 502
          result['message'] = 'Bad Gateway'
        elsif response =~ /HTTPError: HTTP Error 503: Service Unavailable/
          result['code'] = 503
          result['message'] = 'Service Unavailable'
        elsif response =~ /HTTPError: HTTP Error 504: Gateway Time-?out/
          result['code'] = 504
          result['message'] = 'Timeout'
        end
      # Ruby exceptions
      elsif response =~ /Errno::[A-Z]+/
        # Connection refused
        if response =~ /Errno::ECONNREFUSED/
          result['code'] = 502
          result['message'] = 'Bad Gateway'
        # No route to host
        elsif response =~ /Errno::EHOSTUNREACH/
          result['code'] = 502
          result['message'] = 'Bad Gateway'
        # Connection timed out
        elsif response =~ /Errno::ETIMEDOUT/
          result['code'] = 504
          result['message'] = 'Timeout'
        end
      # Generic error messages
      elsif response =~ /(Connection refused|No route to host) - connect\(\d\)/
        # Connection refused
        if response =~ /Connection refused - connect\(\d\)/
          result['code'] = 502
          result['message'] = 'Bad Gateway'
        # No route to host
        elsif response =~ /No route to host - connect\(\d\)/
          result['code'] = 502
          result['message'] = 'Bad Gateway'
        # Connection timed out
        elsif response =~ /Connection timed out - connect\(\d\)/
          result['code'] = 504
          result['message'] = 'Timeout'
        end
      end
      result
    end

    #
    # @note Detect WAF and SSRF protection libraries based on common strings in the response body
    #
    # @options
    # - response - String - HTTP response
    #
    # @returns Boolean - WAF detected
    #
    def detect_waf(response)
      detected = false
      # SafeCurl (safe_curl) InvalidURLException
      if response =~ /fin1te\\SafeCurl\\Exception\\InvalidURLException/
        logger.info 'SafeCurl protection mechanism appears to be in use'
        detected = true
      end
      detected
    end

    #
    # @note Parse HTTP response
    #
    # @options
    # - response - Net::HTTPResponse - HTTP response object
    #
    # @returns - Hash - HTTP response object
    #
    def parse_http_response(response)
      return response if response.class == Hash
      result = {}
      begin
        result['status']       = 'complete'
        result['http_version'] = response.http_version
        result['code']         = response.code
        result['message']      = response.message

        # guess HTTP response code and message
        if @guess_status
          head = response.body[0..4096]
          status = guess_status(head)
          unless status.empty?
            result['code'] = status['code']
            result['message'] = status['message']
            logger.info("Using HTTP response status: #{result['code']} #{result['message']}")
          end
        end
        result['headers'] = "HTTP\/#{result['http_version']} #{result['code']} #{result['message']}\n"

        # detect WAF and SSRF protection libraries
        if @detect_waf
          head = response.body[0..4096]
          # SafeCurl (safe_curl) InvalidURLException
          if head =~ /fin1te\\SafeCurl\\Exception\\InvalidURLException/
            logger.info 'SafeCurl protection mechanism appears to be in use'
          end
        end

        # strip unwanted HTTP response headers
        response.each_header do |header_name, header_value|
          if @strip.include?(header_name.downcase)
            logger.info "Removed response header: #{header_name}"
            next
          end
          result['headers'] << "#{header_name}: #{header_value}\n"
        end
        result['headers'] << "\n"
        result['body'] = response.body.to_s unless response.body.nil?
      rescue
        logger.info('Malformed HTTP response from server')
        result['status']  = 'fail'
        result['code']    = 502
        result['message'] = 'Error'
        result['headers'] = "HTTP\/1.1 502 Error\nServer: #{@banner}\nContent-Length: 0\n\n"
      end
      result
    end

    #
    # @note Guess content type based on file extension
    #
    # @options
    # - ext - String - File extension [with dots] (Example: '.png')
    #
    # @returns String - content-type value
    #
    def guess_mime(ext)
      content_types = WEBrick::HTTPUtils::DefaultMimeTypes
      common_content_types = {
        'ico' => 'image/x-icon' }
      content_types.merge!(common_content_types)
      content_types.each do |k, v|
        return v.to_s if ext == ".#{k}"
      end
      nil
    end

    # private methods
    private :print_status,
            :print_good,
            :parse_options,
            :parse_http_response,
            :send_http_request,
            :run_rules,
            :encode_ip,
            :guess_mime,
            :guess_status,
            :detect_waf
  end
end
