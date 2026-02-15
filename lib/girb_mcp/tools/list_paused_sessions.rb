# frozen_string_literal: true

require "mcp"

module GirbMcp
  module Tools
    class ListPausedSessions < MCP::Tool
      description "[Discovery] List all active debug sessions managed by girb-mcp. " \
                  "Shows connected sessions, their PIDs, and idle time."

      input_schema(
        properties: {},
      )

      class << self
        def call(server_context:)
          manager = server_context[:session_manager]
          sessions = manager.active_sessions

          if sessions.empty?
            text = "No active debug sessions. Use 'connect' or 'run_script' to start one."
          else
            lines = sessions.map do |s|
              status = s[:connected] ? "connected" : "disconnected"
              idle = format_duration(s[:idle_seconds])
              "  #{s[:session_id]} (PID: #{s[:pid]}, #{status}, idle: #{idle})"
            end
            text = "Active debug sessions:\n#{lines.join("\n")}"
          end

          MCP::Tool::Response.new([{ type: "text", text: text }])
        end

        private

        def format_duration(seconds)
          if seconds < 60
            "#{seconds}s"
          elsif seconds < 3600
            "#{seconds / 60}m #{seconds % 60}s"
          else
            "#{seconds / 3600}h #{(seconds % 3600) / 60}m"
          end
        end
      end
    end
  end
end
