# frozen_string_literal: true

require "mcp"
require_relative "../rails_helper"

module GirbMcp
  module Tools
    class ReadFile < MCP::Tool
      MAX_LINES = 500
      # Max lines to fetch per chunk via debug session (keeps output within debug gem's width limit)
      REMOTE_CHUNK_SIZE = 50

      description "[Investigation] Read a source file from the debug session's machine. " \
                  "Use this to view code around a breakpoint or understand the surrounding logic. " \
                  "Relative paths are resolved against the debugged process's working directory."

      annotations(
        title: "Read Source File",
        read_only_hint: true,
        destructive_hint: false,
        open_world_hint: false,
      )

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
          # Check if we should read via the debug session (remote/Docker connection)
          client = get_client(server_context)
          if client&.remote
            return read_remote_file(client, path, start_line, end_line)
          end

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
        rescue FileNotFoundError => e
          MCP::Tool::Response.new([{ type: "text", text:
            "Error: File not found: #{e.message}\n\n" \
            "This is a relative path but no active debug session is available to resolve it. " \
            "Use an absolute path, or connect to a debug session first." }])
        rescue StandardError => e
          MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.class}: #{e.message}" }])
        end

        private

        # Get the debug client, or nil if no active session.
        def get_client(server_context)
          server_context[:session_manager].client
        rescue GirbMcp::Error
          nil
        end

        # Read a file via the debug session (for remote/Docker connections).
        # Uses eval_expr to call File operations in the target process.
        def read_remote_file(client, path, start_line, end_line)
          client.auto_repause!

          # Resolve relative path via remote cwd
          full_path = if path.start_with?("/")
            path
          else
            cwd = RailsHelper.eval_expr(client, "Dir.pwd")
            cwd ? File.join(cwd, path) : path
          end

          # Check file existence
          exists = RailsHelper.eval_expr(client, "File.exist?(#{full_path.inspect})")
          unless exists == "true"
            return MCP::Tool::Response.new([{ type: "text",
              text: "Error: File not found on remote process: #{full_path}" }])
          end

          # Get total line count
          count_str = RailsHelper.eval_expr(client, "File.readlines(#{full_path.inspect}).size")
          total_lines = count_str.to_i

          # Determine line range
          if start_line || end_line
            start_idx = [(start_line || 1) - 1, 0].max
            end_idx = [(end_line || total_lines) - 1, total_lines - 1].min
            end_idx = [end_idx, start_idx + MAX_LINES - 1].min
          else
            start_idx = 0
            end_idx = [total_lines - 1, MAX_LINES - 1].min
          end

          # Fetch lines in chunks to stay within debug gem output width limits
          all_lines = []
          pos = start_idx
          while pos <= end_idx
            chunk_end = [pos + REMOTE_CHUNK_SIZE - 1, end_idx].min
            chunk = RailsHelper.eval_expr(client,
              "File.readlines(#{full_path.inspect})[#{pos}..#{chunk_end}].join")
            break unless chunk

            all_lines << chunk
            pos = chunk_end + 1
          end

          content_raw = all_lines.join
          lines = content_raw.lines
          content = lines.map.with_index(start_idx + 1) { |line, num| "#{num}: #{line}" }.join

          if start_line || end_line
            header = "#{full_path} (lines #{start_idx + 1}-#{end_idx + 1} of #{total_lines}) [remote]"
          elsif total_lines > MAX_LINES
            header = "#{full_path} (lines 1-#{MAX_LINES} of #{total_lines}, truncated) [remote]"
          else
            header = "#{full_path} (#{total_lines} lines) [remote]"
          end

          MCP::Tool::Response.new([{ type: "text", text: "#{header}\n\n#{content}" }])
        rescue GirbMcp::Error => e
          MCP::Tool::Response.new([{ type: "text", text: "Error reading remote file: #{e.message}" }])
        end

        # Resolve relative paths against the debugged process's working directory.
        # Falls back to MCP server's working directory if no active session.
        def resolve_path(path, server_context)
          return File.expand_path(path) if path.start_with?("/") || path.start_with?("~")

          # Try to get the debugged process's working directory
          cwd = remote_cwd(server_context)
          if cwd
            File.join(cwd, path)
          else
            # No active session — try local resolution but warn in error message
            local_path = File.expand_path(path)
            return local_path if File.exist?(local_path)

            # File doesn't exist locally either — raise with helpful context
            raise FileNotFoundError, path
          end
        end

        # Custom error to distinguish "no session for relative path" from other errors
        class FileNotFoundError < StandardError; end

        def remote_cwd(server_context)
          client = server_context[:session_manager].client
          client.auto_repause!
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
