# frozen_string_literal: true

require "mcp"
require "set"
require "net/http"
require "uri"
require_relative "../rails_helper"

module GirbMcp
  module Tools
    class Connect < MCP::Tool
      description "[Entry Point] Connect to an already-running Ruby debug session " \
                  "(e.g., a Rails server or background process started with 'rdbg --open'). " \
                  "For debugging scripts, prefer 'run_script' which also captures stdout/stderr. " \
                  "If only one session exists, connects automatically. " \
                  "You can specify a TCP port (e.g., port: 12345) or a Unix socket path. " \
                  "After connecting, use 'get_context' to see the current state. " \
                  "Previous session breakpoints are NOT restored by default (use restore_breakpoints: true to restore). " \
                  "Note: stdout/stderr are NOT captured for connect sessions."

      input_schema(
        properties: {
          path: {
            type: "string",
            description: "Unix domain socket path (e.g., /tmp/rdbg-1000/rdbg-12345)",
          },
          host: {
            type: "string",
            description: "TCP host for remote debug connection (default: localhost)",
          },
          port: {
            type: "integer",
            description: "TCP port for remote debug connection",
          },
          session_id: {
            type: "string",
            description: "Custom session ID for this connection (auto-generated if omitted)",
          },
          restore_breakpoints: {
            type: "boolean",
            description: "If true, restores breakpoints saved from previous sessions. " \
                         "Useful when reconnecting to debug the same code with identical breakpoints. " \
                         "Default: false (starts fresh without inheriting previous breakpoints).",
          },
          auto_escape: {
            type: "boolean",
            description: "If false, skip automatic trap context escape. " \
                         "Default: true (automatically escape signal trap context when possible).",
          },
        },
      )

      class << self
        def call(path: nil, host: nil, port: nil, session_id: nil, restore_breakpoints: nil,
                 auto_escape: nil, server_context:)
          manager = server_context[:session_manager]

          # Clear saved breakpoints unless explicitly restoring
          manager.clear_breakpoint_specs unless restore_breakpoints

          result = manager.connect(
            session_id: session_id,
            path: path,
            host: host,
            port: port,
          )

          client = manager.client(result[:session_id])

          text = "Connected to debug session.\n" \
                 "  Session ID: #{result[:session_id]}\n" \
                 "  PID: #{result[:pid]}\n"

          # Detect listen ports (useful for trigger_request URL)
          listen_ports = detect_listen_ports(result[:pid])
          if listen_ports.any?
            port_list = listen_ports.map { |p| "http://127.0.0.1:#{p}" }.join(", ")
            text += "  Listening on: #{port_list}\n"
          end

          # Check if this is a Rails process (needed for auto-escape and summary)
          is_rails = RailsHelper.rails?(client)

          # Compute route summary before escape (trap-safe, needed for auto-escape target)
          route_info = is_rails ? RailsHelper.route_summary(client, limit: 5) : nil

          # Detect and escape signal trap context (common with Puma/SIGURG).
          # In trap context, Mutex/thread operations fail with ThreadError.
          auto_escape_enabled = auto_escape != false
          text += escape_trap_context(client,
            listen_ports: listen_ports,
            route_info: route_info,
            auto_escape: auto_escape_enabled)

          escaped = text.include?("Auto-escaped signal trap context")

          text += "\nIMPORTANT: The target process is now PAUSED. " \
                  "Use 'continue_execution' to resume it when done investigating, " \
                  "or 'disconnect' to detach (which also resumes the process).\n" \
                  "Note: stdout/stderr are not captured for 'connect' sessions " \
                  "(use 'run_script' for capture).\n\n" \
                  "Initial state:\n#{result[:output]}"

          if is_rails
            text += build_rails_summary(client, result[:output], listen_ports, route_info,
              escaped: escaped)
          end

          # Restore breakpoints from previous sessions
          restored = manager.restore_breakpoints(client)
          if restored.any?
            text += "\n\nRestored #{restored.size} breakpoint(s) from previous session:"
            restored.each do |r|
              text += if r[:error]
                "\n  #{r[:spec]} -> Error: #{r[:error]}"
              else
                "\n  #{r[:spec]} -> #{r[:output]}"
              end
            end
          end

          MCP::Tool::Response.new([{ type: "text", text: text }])
        rescue GirbMcp::Error => e
          MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.message}" }])
        end

        private

        # Detect TCP listen ports owned by the target process.
        # Cross-references /proc/PID/fd (socket inodes) with /proc/PID/net/tcp
        # to return only ports that belong to this specific process.
        # Returns an array of port numbers (e.g., [3000, 3035]).
        # Works without sending any commands to the debug session (safe in trap context).
        def detect_listen_ports(pid)
          return [] unless pid

          # Step 1: Find socket inodes owned by this process
          process_inodes = collect_socket_inodes(pid)
          return [] if process_inodes.empty?

          # Step 2: Find LISTEN ports matching those inodes
          ports = []
          ["/proc/#{pid}/net/tcp", "/proc/#{pid}/net/tcp6"].each do |path|
            next unless File.exist?(path)

            File.readlines(path).each do |line|
              fields = line.strip.split
              next if fields[0] == "sl" # header line

              state = fields[3]
              next unless state == "0A" # 0A = LISTEN

              inode = fields[9]
              next unless process_inodes.include?(inode)

              local_addr = fields[1]
              port = local_addr.split(":").last.to_i(16)
              ports << port if port > 0
            end
          end

          ports.uniq.sort
        rescue StandardError
          []
        end

        # Read /proc/PID/fd to find socket inodes owned by the process.
        # Each socket fd is a symlink like "socket:[12345]".
        def collect_socket_inodes(pid)
          fd_dir = "/proc/#{pid}/fd"
          return Set.new unless Dir.exist?(fd_dir)

          inodes = Set.new
          Dir.foreach(fd_dir) do |entry|
            next if entry == "." || entry == ".."

            link = File.readlink(File.join(fd_dir, entry))
            if link =~ /\Asocket:\[(\d+)\]\z/
              inodes.add($1)
            end
          rescue Errno::ENOENT, Errno::EACCES
            next
          end
          inodes
        rescue StandardError
          Set.new
        end

        # Build a comprehensive Rails summary including app info, routes, and models.
        # Uses lightweight (trap-safe) methods that work even in signal trap context.
        # Accepts precomputed route_info to avoid duplicate queries.
        def build_rails_summary(client, initial_output, listen_ports, route_info = nil, escaped: false)
          text = "\n"

          # App info header
          app_name = RailsHelper.eval_expr(client, "Rails.application.class.module_parent_name")
          rails_ver = RailsHelper.eval_expr(client, "Rails::VERSION::STRING")
          rails_env = RailsHelper.eval_expr(client, "Rails.env")
          ruby_ver = RailsHelper.eval_expr(client, "RUBY_VERSION")
          root_path = RailsHelper.eval_expr(client, "Rails.root.to_s")

          header = "=== Rails"
          header += ": #{app_name}" if app_name
          header += " (#{rails_env})" if rails_env
          header += " ==="
          text += "#{header}\n"

          version_parts = []
          version_parts << "Rails #{rails_ver}" if rails_ver
          version_parts << "Ruby #{ruby_ver}" if ruby_ver
          text += "#{version_parts.join(" / ")}\n" if version_parts.any?
          text += "Root: #{root_path}\n" if root_path

          # Route summary (use precomputed if available)
          route_info ||= RailsHelper.route_summary(client, limit: 5)
          if route_info && route_info[:count] > 0
            text += "\nRoutes: #{route_info[:count]} defined\n"
            route_info[:samples].each { |s| text += "  #{s}\n" }
            remaining = route_info[:count] - route_info[:samples].size
            text += "  ... and #{remaining} more (use 'rails_routes' for full list)\n" if remaining > 0
          end

          # Model files
          models = RailsHelper.model_files(client)
          if models && models.any?
            text += "\nModels: #{models.join(", ")}\n"
          end

          # Always show next steps for Rails apps
          in_gem_code = initial_output&.match?(%r{/gems/|/rubygems/|No sourcefile available})
          if escaped
            # Auto-escape succeeded — we're in app code now
            text += "\nYou are now in application code context. " \
                    "All tools (DB queries, model loading, etc.) work normally.\n"
          elsif in_gem_code
            # Stuck in gem/framework code — show concrete steps to reach app code
            text += build_next_steps(route_info, listen_ports)
          else
            # In app code already — show available actions
            text += build_app_code_next_steps(route_info, listen_ports)
          end

          text += "\nRails tools available: rails_info, rails_routes, rails_model\n"
          text
        end

        # Suggest actions when already in application code.
        def build_app_code_next_steps(route_info, listen_ports)
          text = "\nYou are in application code. Available actions:\n"
          text += "  - Use 'get_context' to inspect current variables and call stack\n"
          text += "  - Use 'set_breakpoint' to add breakpoints on specific actions\n"
          if listen_ports&.any?
            text += "  - Use 'trigger_request' to send HTTP requests (auto-resumes the process)\n"
          end
          text += "  - Use 'evaluate_code' to run Ruby expressions in the current context\n"
          text
        end

        # Build concrete next steps using discovered route and port info.
        def build_next_steps(route_info, listen_ports)
          text = "\nTo debug your application code:\n"

          # Suggest a specific controller if we have route info
          if route_info && route_info[:samples]&.any?
            sample = route_info[:samples].first
            # Parse "GET     /users users#index" to extract controller
            parts = sample.strip.split
            if parts.size >= 3
              controller_action = parts[2] # e.g., "users#index"
              controller = controller_action.split("#").first
              text += "  1. set_breakpoint on app/controllers/#{controller}_controller.rb\n"
            else
              text += "  1. set_breakpoint on a controller action\n"
            end

            # Suggest a specific URL if we have port info
            url_path = parts[1] if parts.size >= 2 # e.g., "/users"
            if listen_ports&.any? && url_path
              text += "  2. trigger_request with GET http://127.0.0.1:#{listen_ports.first}#{url_path}\n"
            else
              text += "  2. trigger_request to send an HTTP request\n"
            end
          else
            text += "  1. set_breakpoint on a controller action\n"
            if listen_ports&.any?
              text += "  2. trigger_request with GET http://127.0.0.1:#{listen_ports.first}/\n"
            else
              text += "  2. trigger_request to send an HTTP request\n"
            end
          end

          text += "  3. Once at the breakpoint, all tools work normally\n"
          text
        end

        def escape_trap_context(client, listen_ports: [], route_info: nil, auto_escape: true)
          return "" unless client.in_trap_context?

          # When a web server is detected (listen ports available), go directly to
          # breakpoint+HTTP auto-escape. The `next` command causes protocol desync
          # when the process is IO-blocked (common with Puma's IO.select loop):
          # `next` times out → command stays in-flight → subsequent commands receive
          # wrong responses → all auto-escape logic fails.
          if auto_escape && listen_ports.any?
            auto_result = auto_escape_trap_context(client, listen_ports, route_info)
            return auto_result if auto_result
          end

          # Fall back to simple step escape (only for non-web-server processes
          # where listen_ports is empty and auto-escape is not available)
          unless listen_ports.any?
            step_output = client.escape_trap_context!
            if step_output
              return "\n  Status: Escaped signal trap context (thread operations now available)\n"
            end
          end

          "\n  WARNING: Running in signal trap context (common with Puma/threaded servers).\n" \
          "  Thread operations (DB queries, model autoloading) will fail with ThreadError.\n" \
          "  Simple expressions (variables, constants, p/pp) still work.\n\n" \
          "  To escape to normal context:\n" \
          "    1. set_breakpoint on a line in your controller/action\n" \
          "    2. trigger_request to send an HTTP request (auto-resumes the process)\n" \
          "    3. Once stopped at the breakpoint, all operations work normally\n"
        end

        # Automatically escape trap context by setting a breakpoint on a controller action
        # and sending a GET request to trigger it.
        # Returns the status string on success, nil on failure.
        def auto_escape_trap_context(client, listen_ports, route_info)
          target = find_breakpoint_target(client, route_info)
          return nil unless target

          file, line, url_path = target[:file], target[:line], target[:path]

          # Set a temporary breakpoint
          bp_output = client.send_command("break #{file}:#{line}")
          bp_match = bp_output.match(/#(\d+)/)
          return nil unless bp_match

          bp_number = bp_match[1].to_i
          port = listen_ports.first
          url = "http://127.0.0.1:#{port}#{url_path || "/"}"

          # Send GET request in background thread and wait for breakpoint
          result = perform_escape_request(client, url)

          unless result
            # Escape failed: process may still be running after continue_and_wait
            # timed out. Try to re-pause it so subsequent commands don't all timeout.
            begin
              client.ensure_paused(timeout: 3)
            rescue GirbMcp::Error
              # Best-effort: if this fails, subsequent commands will also fail,
              # but at least we tried
            end
          end

          # Clean up the temporary breakpoint (only works if process is paused)
          begin
            client.send_command("delete #{bp_number}")
          rescue GirbMcp::Error
            # Best-effort cleanup
          end

          if result
            "\n  Status: Auto-escaped signal trap context (via #{url_path || "/"})\n" \
            "  Thread operations (DB, autoloading) now available.\n"
          else
            nil
          end
        rescue GirbMcp::Error
          nil
        end

        # Find a suitable breakpoint target for auto-escape.
        # Returns { file:, line:, path: } or nil.
        def find_breakpoint_target(client, route_info)
          # Strategy 1: Use route info to find a controller action
          target = find_target_from_routes(client, route_info)
          return target if target

          # Strategy 2: Use framework internal method as fallback
          url_path = extract_get_path(route_info)
          find_target_from_framework(client, url_path)
        end

        # Find a breakpoint target from route info by constructing the file path
        # directly from Rails.root + controller name convention.
        # Does NOT use const_source_location (which triggers autoloading and fails in trap context).
        def find_target_from_routes(client, route_info)
          return nil unless route_info && route_info[:samples]&.any?

          root = RailsHelper.eval_expr(client, "Rails.root.to_s")
          return nil unless root

          route_info[:samples].each do |sample|
            parts = sample.strip.split
            next unless parts.size >= 3 && parts[0] == "GET"

            url_path = parts[1]
            controller_action = parts[2]
            controller_name, action_name = controller_action.split("#")
            next unless controller_name && action_name

            # Construct file path directly from convention (no autoloading needed)
            file = "#{root}/app/controllers/#{controller_name}_controller.rb"

            # Verify the file exists and find the action line (File I/O is trap-safe)
            line_expr = "File.exist?(#{file.inspect}) && " \
                        "File.readlines(#{file.inspect}).each_with_index.detect{|l,i|" \
                        "l.strip.match?(/\\Adef\\s+#{action_name}\\b/)}&.last&.+(1)"
            line_str = RailsHelper.eval_expr(client, line_expr)
            next unless line_str && line_str != "false"

            line = line_str.to_i
            next unless line > 0

            return { file: file, line: line, path: url_path }
          end

          nil
        rescue GirbMcp::Error
          nil
        end

        # Fallback: find a breakpoint target using framework internals.
        # Uses a real GET URL from route_info instead of "/" (which may not be routed).
        def find_target_from_framework(client, url_path = nil)
          # Use ActionController::Metal#dispatch source location
          location = RailsHelper.eval_expr(client,
            "ActionController::Metal.instance_method(:dispatch).source_location.inspect")
          return nil unless location

          # Parse the [file, line] array
          match = location.match(/\["([^"]+)",\s*(\d+)\]/)
          return nil unless match

          # Use line + 1 to target the method body (def line may not trigger `:line` event)
          { file: match[1], line: match[2].to_i + 1, path: url_path || "/" }
        rescue GirbMcp::Error
          nil
        end

        # Extract the first GET path from route info.
        def extract_get_path(route_info)
          return nil unless route_info && route_info[:samples]&.any?

          route_info[:samples].each do |sample|
            parts = sample.strip.split
            return parts[1] if parts.size >= 3 && parts[0] == "GET"
          end
          nil
        end

        # Send an HTTP GET request in a background thread and wait for breakpoint hit.
        # Returns true if breakpoint was hit, false otherwise.
        def perform_escape_request(client, url)
          http_done = false
          http_thread = Thread.new do
            uri = URI.parse(url)
            http = Net::HTTP.new(uri.host, uri.port)
            http.open_timeout = 5
            http.read_timeout = 10
            http.get(uri.request_uri)
          rescue StandardError
            # Ignore HTTP errors — we only care about triggering the breakpoint
          ensure
            http_done = true
          end

          result = client.continue_and_wait(timeout: 10) { http_done }
          http_thread.join(1)

          result[:type] == :breakpoint
        rescue GirbMcp::Error
          http_thread&.join(1)
          false
        end
      end
    end
  end
end
