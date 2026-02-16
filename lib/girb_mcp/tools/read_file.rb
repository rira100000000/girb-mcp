# frozen_string_literal: true

require "mcp"

module GirbMcp
  module Tools
    class ReadFile < MCP::Tool
      MAX_LINES = 500

      description "[Investigation] Read a source file from the debug session's machine. " \
                  "Use this to view code around a breakpoint or understand the surrounding logic. " \
                  "Relative paths are resolved against the debugged process's working directory."

      input_schema(
        properties: {
          path: {
            type: "string",
            description: "File path (relative to working directory or absolute)",
          },
          start_line: {
            type: "integer",
            description: "Start line number (1-indexed, optional)",
          },
          end_line: {
            type: "integer",
            description: "End line number (1-indexed, optional)",
          },
        },
        required: ["path"],
      )

      class << self
        def call(path:, start_line: nil, end_line: nil, server_context:)
          full_path = resolve_path(path, server_context)

          unless File.exist?(full_path)
            return MCP::Tool::Response.new([{ type: "text", text: "Error: File not found: #{path}" }])
          end

          lines = File.readlines(full_path)
          total_lines = lines.length

          if start_line || end_line
            start_idx = [(start_line || 1) - 1, 0].max
            end_idx = [(end_line || total_lines) - 1, total_lines - 1].min
            end_idx = [end_idx, start_idx + MAX_LINES - 1].min
            selected = lines[start_idx..end_idx]
            content = selected.map.with_index(start_idx + 1) { |line, num| "#{num}: #{line}" }.join
            header = "#{full_path} (lines #{start_idx + 1}-#{end_idx + 1} of #{total_lines})"
          else
            if lines.length > MAX_LINES
              content = lines.first(MAX_LINES).map.with_index(1) { |line, num| "#{num}: #{line}" }.join
              header = "#{full_path} (lines 1-#{MAX_LINES} of #{total_lines}, truncated)"
            else
              content = lines.map.with_index(1) { |line, num| "#{num}: #{line}" }.join
              header = "#{full_path} (#{total_lines} lines)"
            end
          end

          MCP::Tool::Response.new([{ type: "text", text: "#{header}\n\n#{content}" }])
        rescue StandardError => e
          MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.class}: #{e.message}" }])
        end

        private

        # Resolve relative paths against the debugged process's working directory.
        # Falls back to MCP server's working directory if no active session.
        def resolve_path(path, server_context)
          return File.expand_path(path) if path.start_with?("/")

          # Try to get the debugged process's working directory
          cwd = remote_cwd(server_context)
          if cwd
            File.join(cwd, path)
          else
            File.expand_path(path)
          end
        end

        def remote_cwd(server_context)
          client = server_context[:session_manager].client
          result = client.send_command("p Dir.pwd")
          cleaned = result.strip.sub(/\A=> /, "")
          return nil if cleaned == "nil" || cleaned.empty?

          if cleaned.start_with?('"') && cleaned.end_with?('"')
            cleaned = cleaned[1..-2]
          end
          cleaned.empty? ? nil : cleaned
        rescue GirbMcp::Error
          nil
        end
      end
    end
  end
end
