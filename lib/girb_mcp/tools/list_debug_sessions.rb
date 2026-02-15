# frozen_string_literal: true

require "mcp"

module GirbMcp
  module Tools
    class ListDebugSessions < MCP::Tool
      description "[Discovery] List available Ruby debug sessions on this machine. " \
                  "Shows running Ruby processes started with 'rdbg --open' that can be " \
                  "connected to. Use this first to find sessions before calling 'connect'."

      input_schema(
        properties: {},
      )

      class << self
        def call(server_context:)
          sessions = DebugClient.list_sessions

          if sessions.empty?
            text = "No debug sessions found.\n\n" \
                   "To start a debuggable Ruby process:\n" \
                   "  rdbg --open <script.rb>\n" \
                   "  rdbg --open --port=12345 <script.rb>\n" \
                   "  RUBY_DEBUG_OPEN=true ruby <script.rb>"
          else
            lines = sessions.map do |s|
              name_info = s[:name] ? " (#{s[:name]})" : ""
              "  PID #{s[:pid]}#{name_info}: #{s[:path]}"
            end
            text = "Found #{sessions.size} debug session(s):\n#{lines.join("\n")}"
          end

          MCP::Tool::Response.new([{ type: "text", text: text }])
        end
      end
    end
  end
end
