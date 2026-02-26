# frozen_string_literal: true

require "mcp"

module GirbMcp
  module Tools
    class ListPausedSessions < MCP::Tool
      description "[Discovery] List all active debug sessions managed by girb-mcp. " \
                  "Shows connected sessions, their PIDs, and idle time."

      annotations(
        title: "List Active Sessions",
        read_only_hint: true,
        destructive_hint: false,
        open_world_hint: false,
      )

      input_schema(
        properties: {},
      )

      class << self
        def call(server_context:)
          manager = server_context[:session_manager]
          sessions = manager.active_sessions(include_client: true)

          if sessions.empty?
            text = "No active debug sessions. Use 'connect' or 'run_script' to start one."
          else
            lines = sessions.map { |s| format_session(s) }
            text = "Active debug sessions:\n#{lines.join("\n")}"
            text += "\n\nNote: Sessions expire after inactivity. Any tool call resets the timer."
          end

          MCP::Tool::Response.new([{ type: "text", text: text }])
        end

        private

        def format_session(s)
          status = s[:connected] ? "connected" : "disconnected"
          status += ", paused" if s[:paused]
          idle = format_duration(s[:idle_seconds])

          line = "  #{s[:session_id]} (PID: #{s[:pid]}, #{status}, idle: #{idle})"

          # Show remaining time before timeout
          if s[:timeout_seconds]
            remaining = s[:timeout_seconds] - s[:idle_seconds]
            if remaining > 300
              line += "\n    Timeout: #{format_duration(remaining)} remaining"
            elsif remaining > 0
              line += "\n    Timeout: #{format_duration(remaining)} remaining (WARNING: expiring soon)"
            else
              line += "\n    Timeout: EXPIRED (will be reaped on next check)"
            end
          end

          # Query current stop location and breakpoint count from the client
          client = s[:client]
          if client&.connected? && client.paused
            location = query_stop_location(client)
            line += "\n    Location: #{location}" if location

            bp_count = query_breakpoint_count(client)
            line += "\n    Breakpoints: #{bp_count}" if bp_count
          end

          line
        end

        # Query the current stop location from the debug session.
        # Returns "file.rb:10 in ClassName#method" or nil.
        def query_stop_location(client)
          output = client.send_command("frame")
          if (match = output.match(/#\d+\s+(.+?)\s+at\s+(.+:\d+)/))
            "#{match[2]} in #{match[1].strip}"
          end
        rescue GirbMcp::Error
          nil
        end

        # Query the number of breakpoints set.
        # Returns a string like "3 set" or nil.
        def query_breakpoint_count(client)
          output = client.send_command("info breakpoints")
          cleaned = output.strip
          return nil if cleaned.empty? || cleaned.include?("No breakpoints")

          count = cleaned.lines.count { |l| l.match?(/\A\s*#\d+/) }
          count > 0 ? "#{count} set" : nil
        rescue GirbMcp::Error
          nil
        end

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
