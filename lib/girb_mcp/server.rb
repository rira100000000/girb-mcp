# frozen_string_literal: true

require "mcp"
require_relative "tools/list_debug_sessions"
require_relative "tools/connect"
require_relative "tools/evaluate_code"
require_relative "tools/inspect_object"
require_relative "tools/get_context"
require_relative "tools/get_source"
require_relative "tools/read_file"
require_relative "tools/continue_execution"
require_relative "tools/set_breakpoint"
require_relative "tools/remove_breakpoint"
require_relative "tools/step"
require_relative "tools/next"
require_relative "tools/finish"
require_relative "tools/run_debug_command"
require_relative "tools/run_script"
require_relative "tools/trigger_request"
require_relative "tools/list_paused_sessions"

module GirbMcp
  class Server
    TOOLS = [
      # Discovery & connection
      Tools::ListDebugSessions,
      Tools::Connect,
      Tools::ListPausedSessions,
      # Investigation
      Tools::EvaluateCode,
      Tools::InspectObject,
      Tools::GetContext,
      Tools::GetSource,
      Tools::ReadFile,
      # Control
      Tools::SetBreakpoint,
      Tools::RemoveBreakpoint,
      Tools::ContinueExecution,
      Tools::Step,
      Tools::Next,
      Tools::Finish,
      Tools::RunDebugCommand,
      # Entry points
      Tools::RunScript,
      Tools::TriggerRequest,
    ].freeze

    DEFAULT_HTTP_PORT = 6029
    DEFAULT_HTTP_HOST = "127.0.0.1"

    INSTRUCTIONS = <<~TEXT
      girb-mcp is a Ruby runtime debugger. It connects to live Ruby processes via the debug gem \
      and lets you inspect variables, evaluate code, set breakpoints, and control execution.

      Use these tools when the user asks to debug a Ruby program, investigate runtime behavior, \
      or inspect the state of a running process.

      Typical workflow:
      1. run_script to launch a Ruby script under the debugger (recommended — captures stdout/stderr). \
      Use connect only when attaching to an already-running process (e.g., Rails server).
      2. get_context to see the current state (variables, call stack, breakpoints)
      3. evaluate_code / inspect_object to investigate specific values
      4. set_breakpoint / next / step / continue_execution to control the flow

      When to use get_context:
      - After connecting or run_script — to understand the initial stop point
      - After continue_execution hits a breakpoint — the stop output shows source and stack, \
      but get_context gives you local/instance variables and the full breakpoint list
      - When you need to check what breakpoints are currently set
      - When variables or call stack context would help decide the next debugging action
      - You do NOT need get_context after every next/step if the output already shows \
      the information you need (source listing and stop location are included in the response)
    TEXT

    def initialize(transport: nil, port: nil, host: nil, session_timeout: nil, **_)
      @transport_type = transport || "stdio"
      @http_port = port || DEFAULT_HTTP_PORT
      @http_host = host || DEFAULT_HTTP_HOST
      @session_manager = SessionManager.new(
        **(session_timeout ? { timeout: session_timeout } : {}),
      )
    end

    def start
      server = MCP::Server.new(
        name: "girb-mcp",
        version: GirbMcp::VERSION,
        instructions: INSTRUCTIONS,
        tools: TOOLS,
        server_context: { session_manager: @session_manager },
      )

      setup_signal_handlers

      case @transport_type
      when "stdio"
        start_stdio(server)
      when "http"
        start_http(server)
      else
        raise ArgumentError, "Unknown transport: #{@transport_type}"
      end
    ensure
      @session_manager.disconnect_all
    end

    private

    def start_stdio(server)
      transport = MCP::Server::Transports::StdioTransport.new(server)
      transport.open
    end

    def start_http(server)
      require "webrick"

      transport = MCP::Server::Transports::StreamableHTTPTransport.new(server)

      webrick = WEBrick::HTTPServer.new(
        Port: @http_port,
        BindAddress: @http_host,
        Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN),
        AccessLog: [],
      )

      webrick.mount_proc("/mcp") do |req, res|
        env = build_rack_env(req)
        rack_request = RackRequestAdapter.new(env)
        status, headers, body = transport.handle_request(rack_request)

        res.status = status
        headers.each { |k, v| res[k] = v }

        if body.respond_to?(:each)
          output = +""
          body.each { |chunk| output << chunk }
          res.body = output
        elsif body.respond_to?(:call)
          # SSE streaming body
          rd, wr = IO.pipe
          res["Content-Type"] = headers["Content-Type"] || "text/event-stream"
          res["Cache-Control"] = "no-cache"
          res["Connection"] = "keep-alive"
          res.body = rd

          Thread.new do
            body.call(wr)
          rescue IOError, Errno::EPIPE
            # Client disconnected
          ensure
            wr.close unless wr.closed?
          end
        end
      end

      $stderr.puts "girb-mcp HTTP server listening on http://#{@http_host}:#{@http_port}/mcp"

      setup_http_signal_handlers(webrick)
      webrick.start
    ensure
      transport&.close
    end

    # Minimal Rack::Request-compatible adapter for WEBrick
    class RackRequestAdapter
      attr_reader :env

      def initialize(env)
        @env = env
      end

      def body
        @env["rack.input"]
      end
    end

    def build_rack_env(req)
      env = {
        "REQUEST_METHOD" => req.request_method,
        "PATH_INFO" => req.path,
        "QUERY_STRING" => req.query_string || "",
        "SERVER_NAME" => @http_host,
        "SERVER_PORT" => @http_port.to_s,
        "rack.input" => StringIO.new(req.body || ""),
      }

      # Map HTTP headers to Rack convention
      req.header.each do |key, values|
        rack_key = "HTTP_#{key.tr("-", "_").upcase}"
        env[rack_key] = values.join(", ")
      end

      # Ensure key headers are mapped correctly
      env["CONTENT_TYPE"] = req.content_type if req.content_type
      env["HTTP_ACCEPT"] = req["Accept"] if req["Accept"]
      env["HTTP_MCP_SESSION_ID"] = req["Mcp-Session-Id"] if req["Mcp-Session-Id"]

      env
    end

    def setup_signal_handlers
      trap("INT") do
        @session_manager.disconnect_all
        exit(0)
      end

      trap("TERM") do
        @session_manager.disconnect_all
        exit(0)
      end
    end

    def setup_http_signal_handlers(webrick)
      trap("INT") do
        @session_manager.disconnect_all
        webrick.shutdown
      end

      trap("TERM") do
        @session_manager.disconnect_all
        webrick.shutdown
      end
    end
  end
end
