# frozen_string_literal: true

require "mcp"

module GirbMcp
  module Tools
    class ListDebugSessions < MCP::Tool
      description "[Discovery] List available Ruby debug sessions on this machine. " \
                  "Shows running Ruby processes started with 'rdbg --open' that can be " \
                  "connected to. Use this first to find sessions before calling 'connect'."

      annotations(
        title: "List Debug Sessions",
        read_only_hint: true,
        destructive_hint: false,
        open_world_hint: false,
      )

      input_schema(
        properties: {},
      )

      class << self
        def call(server_context:)
          unix_sessions = DebugClient.list_sessions
          tcp_sessions = TcpSessionDiscovery.discover

          if unix_sessions.empty? && tcp_sessions.empty?
            text = "No debug sessions found.\n\n" \
                   "To start a debuggable Ruby process:\n" \
                   "  rdbg --open <script.rb>\n" \
                   "  rdbg --open --port=12345 <script.rb>\n" \
                   "  RUBY_DEBUG_OPEN=true ruby <script.rb>\n\n" \
                   "For Docker containers:\n" \
                   "  docker run -e RUBY_DEBUG_OPEN=true -e RUBY_DEBUG_HOST=0.0.0.0 " \
                   "-e RUBY_DEBUG_PORT=12345 -p 12345:12345 <image>"
          else
            lines = []

            unix_sessions.each do |s|
              name_info = s[:name] ? " (#{s[:name]})" : ""
              lines << "  PID #{s[:pid]}#{name_info}: #{s[:path]}"
            end

            tcp_sessions.each do |s|
              source_label = s[:source] == :docker ? "Docker" : "TCP"
              lines << "  #{source_label} \"#{s[:name]}\": #{s[:host]}:#{s[:port]} " \
                       "(connect with port: #{s[:port]})"
            end

            total = unix_sessions.size + tcp_sessions.size
            text = "Found #{total} debug session(s):\n#{lines.join("\n")}"
          end

          MCP::Tool::Response.new([{ type: "text", text: text }])
        end
      end
    end
  end
end
