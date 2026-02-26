# frozen_string_literal: true

require "mcp"

module GirbMcp
  module Tools
    class RunDebugCommand < MCP::Tool
      description "[Control] Execute a raw debugger command for advanced operations not covered " \
                  "by other tools. Examples: 'up'/'down' (move stack frames), " \
                  "'info threads', 'watch @name'. " \
                  "Note: For catching exceptions, prefer set_breakpoint(exception_class: 'NoMethodError') instead."

      annotations(
        title: "Run Debug Command",
        read_only_hint: false,
        destructive_hint: false,
        open_world_hint: false,
      )

      input_schema(
        properties: {
          command: {
            type: "string",
            description: "Debugger command to execute (e.g., 'finish', 'up', 'down', " \
                         "'frame 3', 'info threads', 'watch @name', 'catch NoMethodError')",
          },
          session_id: {
            type: "string",
            description: "Debug session ID (uses default session if omitted)",
          },
        },
        required: ["command"],
      )

      class << self
        def call(command:, session_id: nil, server_context:)
          manager = server_context[:session_manager]
          client = manager.client(session_id)
          client.auto_repause!

          output = client.send_command(command)

          # Track catch breakpoints for preservation across sessions
          if command.strip =~ /\Acatch\s+(\S+)/
            manager.record_breakpoint(command.strip)
          end

          MCP::Tool::Response.new([{ type: "text", text: output }])
        rescue GirbMcp::Error => e
          MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.message}" }])
        end
      end
    end
  end
end
