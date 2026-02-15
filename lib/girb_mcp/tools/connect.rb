# frozen_string_literal: true

require "mcp"

module GirbMcp
  module Tools
    class Connect < MCP::Tool
      description "[Entry Point] Connect to a running Ruby debug session. " \
                  "Call this first to start debugging. If only one session exists, " \
                  "connects automatically. You can specify a TCP port (e.g., port: 12345) " \
                  "or a Unix socket path. After connecting, use 'get_context' to see the current state. " \
                  "Previous session breakpoints are NOT restored by default (use restore_breakpoints: true to restore). " \
                  "Note: stdout/stderr are NOT captured for connect sessions — use run_script if you need output capture."

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
        },
      )

      class << self
        def call(path: nil, host: nil, port: nil, session_id: nil, restore_breakpoints: nil, server_context:)
          manager = server_context[:session_manager]

          # Clear saved breakpoints unless explicitly restoring
          manager.clear_breakpoint_specs unless restore_breakpoints

          result = manager.connect(
            session_id: session_id,
            path: path,
            host: host,
            port: port,
          )

          text = "Connected to debug session.\n" \
                 "  Session ID: #{result[:session_id]}\n" \
                 "  PID: #{result[:pid]}\n\n" \
                 "Note: stdout/stderr are not captured for sessions started with 'connect'.\n" \
                 "Program output will appear in the terminal where the debug process was started.\n" \
                 "Use 'run_script' instead if you need stdout/stderr capture.\n\n" \
                 "Initial state:\n#{result[:output]}"

          # Restore breakpoints from previous sessions
          restored = manager.restore_breakpoints(manager.client(result[:session_id]))
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
      end
    end
  end
end
