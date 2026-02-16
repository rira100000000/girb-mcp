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
require_relative "tools/disconnect"
require_relative "tools/rails_info"
require_relative "tools/rails_routes"
require_relative "tools/rails_model"

module GirbMcp
  class Server
    # Base tools: always available
    BASE_TOOLS = [
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
      Tools::Disconnect,
      # Entry points
      Tools::RunScript,
      Tools::TriggerRequest,
    ].freeze

    # Rails tools: dynamically added when a Rails process is detected
    RAILS_TOOLS = [
      Tools::RailsInfo,
      Tools::RailsRoutes,
      Tools::RailsModel,
    ].freeze

    # All tools (used in tests and for reference)
    TOOLS = (BASE_TOOLS + RAILS_TOOLS).freeze

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
      - For a quick breakpoint check without fetching all context, use \
      run_debug_command(command: "info breakpoints")

      IMPORTANT — connect pauses the target process:
      When you use 'connect', the target process is PAUSED. It will not serve requests or \
      respond to Ctrl+C until you resume it. Always use 'continue_execution' when done \
      investigating, or 'disconnect' to detach (which also resumes the process). \
      Never leave a connected session idle without resuming — the user won't be able to \
      interact with the target process.

      Signal trap context (Puma/threaded servers):
      When connecting to a process like Puma, the debug gem pauses it via SIGURG. \
      This puts the process in a signal trap context where thread operations (Mutex, \
      DB connection pools, autoloading) fail with ThreadError. \
      Simple expressions (variables, constants, p/pp) still work in trap context. \
      The 'connect' tool automatically detects and tries to escape this. \
      If escape fails (common when the process is blocked on IO like IO.select): \
      1. set_breakpoint on a line in your controller/action \
      2. trigger_request to send an HTTP request — this auto-resumes the process \
      3. Once stopped at the breakpoint, all operations work normally \
      Do NOT manually call continue_execution before trigger_request — \
      trigger_request handles resuming the process automatically.

      Rails debugging:
      When you connect to a Rails process, additional Rails-specific tools become available \
      automatically (rails_info, rails_routes, rails_model). These tools are NOT shown \
      when debugging plain Ruby scripts.

      Rails debugging workflow:
      1. Start the Rails server with debugging: RUBY_DEBUG_OPEN=true bin/rails server
      2. connect to attach to the Rails process (auto-detects trap context)
      3. set_breakpoint on a controller action (e.g., app/controllers/users_controller.rb:10)
      4. trigger_request to send an HTTP request — this auto-resumes the paused process, \
      sends the request, and waits for the breakpoint to hit. \
      CSRF protection is automatically disabled for non-GET requests. \
      You do NOT need to call continue_execution first.
      5. When the breakpoint hits, use get_context, evaluate_code, and rails_model to \
      inspect the current state and understand model structures
      6. continue_execution to let the request complete and see the response
      7. To debug another request, set new breakpoints and call trigger_request again
      8. When done debugging, use 'disconnect' to detach and resume the server

      Note: rails_info, rails_routes, and rails_model may not work in trap context. \
      Use them after hitting a breakpoint via trigger_request.
    TEXT

    # Register Rails tools on an MCP server instance and notify connected clients.
    # Safe to call multiple times — skips already-registered tools.
    def self.register_rails_tools(mcp_server)
      tools_hash = mcp_server.instance_variable_get(:@tools)
      tool_names = mcp_server.instance_variable_get(:@tool_names)
      added = false

      RAILS_TOOLS.each do |tool_class|
        name = tool_class.name_value
        next if tools_hash.key?(name)

        tools_hash[name] = tool_class
        tool_names << name
        added = true
      end

      mcp_server.notify_tools_list_changed if added
      added
    end

    def initialize(transport: nil, port: nil, host: nil, session_timeout: nil, **_)
      @transport_type = transport || "stdio"
      @http_port = port || DEFAULT_HTTP_PORT
      @http_host = host || DEFAULT_HTTP_HOST
      @session_manager = SessionManager.new(
        **(session_timeout ? { timeout: session_timeout } : {}),
      )
    end

    def start
      server_context = { session_manager: @session_manager }

      server = MCP::Server.new(
        name: "girb-mcp",
        version: GirbMcp::VERSION,
        instructions: INSTRUCTIONS,
        tools: TOOLS,
        server_context: server_context,
      )

      # Safety net: resume connected processes when the server exits for any reason.
      # This covers cases where Claude Code exits without calling 'disconnect',
      # stdin closes unexpectedly, or the MCP gem calls Kernel.exit directly.
      # disconnect_all is idempotent, so multiple calls (at_exit + ensure + signal) are safe.
      at_exit { @session_manager.disconnect_all }

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
      %w[INT TERM HUP].each do |sig|
        trap(sig) do
          @session_manager.disconnect_all
          exit(0)
        end
      rescue ArgumentError
        # Signal not supported on this platform (e.g., HUP on Windows)
      end
    end

    def setup_http_signal_handlers(webrick)
      %w[INT TERM HUP].each do |sig|
        trap(sig) do
          @session_manager.disconnect_all
          webrick.shutdown
        end
      rescue ArgumentError
        # Signal not supported on this platform
      end
    end
  end
end
