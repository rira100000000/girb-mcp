# frozen_string_literal: true

require "mcp"
require_relative "../rails_helper"

module GirbMcp
  module Tools
    class GetSource < MCP::Tool
      MAX_SOURCE_LINES = 50

      description "[Investigation] Get the source code of a method or class from the running process. " \
                  "Use 'Class#method' for instance methods, 'Class.method' for class methods, " \
                  "or 'Class' for class info including ancestors and method lists."

      annotations(
        title: "Get Source Code",
        read_only_hint: true,
        destructive_hint: false,
        open_world_hint: false,
      )

      input_schema(
        properties: {
          target: {
            type: "string",
            description: "Method or class to get source for (e.g., 'User#save', 'User.find', 'User')",
          },
          session_id: {
            type: "string",
            description: "Debug session ID (uses default session if omitted)",
          },
        },
        required: ["target"],
      )

      class << self
        def call(target:, session_id: nil, server_context:)
          client = server_context[:session_manager].client(session_id)
          client.auto_repause!

          if target.include?("#") || target.include?(".")
            get_method_source(client, target)
          else
            get_class_info(client, target)
          end
        rescue GirbMcp::Error => e
          MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.message}" }])
        end

        private

        def get_method_source(client, target)
          if target.include?("#")
            class_name, method_name = target.split("#", 2)
            method_ref = "#{class_name}.instance_method(:#{method_name})"
          else
            class_name, method_name = target.split(".", 2)
            method_ref = "#{class_name}.method(:#{method_name})"
          end

          # Get source_location and parameters in one eval
          info_code = "[#{method_ref}.source_location, #{method_ref}.parameters]"
          raw = client.send_command("p #{info_code}").strip.sub(/\A=>\s*/, "")

          if raw == "nil" || raw.start_with?("[nil")
            return MCP::Tool::Response.new([{
              type: "text",
              text: "#{target}: source not available (native or C extension method)",
            }])
          end

          # Parse source_location from output: [["file.rb", 26], [[:req, :name], ...]]
          # Use a second eval to get clean values
          file_output = client.send_command("p #{method_ref}.source_location[0]").strip.sub(/\A=>\s*/, "")
          line_output = client.send_command("p #{method_ref}.source_location[1]").strip.sub(/\A=>\s*/, "")
          params_output = client.send_command("p #{method_ref}.parameters").strip.sub(/\A=>\s*/, "")

          file = file_output.delete('"')
          line = line_output.to_i

          # Read source directly from filesystem, or via remote if Docker/remote connection
          source = read_method_source(client, file, line)

          parts = [target]
          parts << "  File: #{file}:#{line}"
          parts << "  Parameters: #{params_output}" unless params_output.empty?
          if source
            parts << ""
            parts << source
          end

          MCP::Tool::Response.new([{ type: "text", text: parts.join("\n") }])
        end

        def get_class_info(client, target)
          parts = []

          name = client.send_command("p #{target}.name").strip.sub(/\A=>\s*/, "")
          parts << "Class: #{name}"

          ancestors = client.send_command("p #{target}.ancestors.first(10).map(&:to_s)").strip.sub(/\A=>\s*/, "")
          parts << "Ancestors: #{ancestors}"

          imethods = client.send_command("p #{target}.instance_methods(false).sort.first(30)").strip.sub(/\A=>\s*/, "")
          parts << "Instance methods: #{imethods}"

          cmethods = client.send_command("p (#{target}.methods - Class.methods).sort.first(30)").strip.sub(/\A=>\s*/, "")
          parts << "Class methods: #{cmethods}"

          MCP::Tool::Response.new([{ type: "text", text: parts.join("\n") }])
        end

        def read_method_source(client, file, start_line)
          if File.exist?(file)
            read_method_source_local(file, start_line)
          elsif client.remote
            read_method_source_remote(client, file, start_line)
          end
        rescue StandardError
          nil
        end

        def read_method_source_local(file, start_line)
          lines = File.readlines(file)
          return nil if start_line < 1 || start_line > lines.length

          end_line = find_method_end(lines, start_line - 1)
          selected = lines[(start_line - 1)..end_line]

          selected.map.with_index(start_line) { |line, num| "  #{num.to_s.rjust(4)}| #{line}" }.join
        end

        # Max lines to fetch per chunk via debug session
        REMOTE_CHUNK_SIZE = 50

        def read_method_source_remote(client, file, start_line)
          return nil if start_line < 1

          # Get total line count from remote
          count_str = RailsHelper.eval_expr(client, "File.readlines(#{file.inspect}).size")
          return nil unless count_str

          total_lines = count_str.to_i
          return nil if start_line > total_lines

          # Fetch enough lines to find method end (start_line through start_line + MAX_SOURCE_LINES)
          fetch_start = start_line - 1
          fetch_end = [fetch_start + MAX_SOURCE_LINES, total_lines - 1].min

          all_lines = []
          pos = fetch_start
          while pos <= fetch_end
            chunk_end = [pos + REMOTE_CHUNK_SIZE - 1, fetch_end].min
            chunk = RailsHelper.eval_expr(client,
              "File.readlines(#{file.inspect})[#{pos}..#{chunk_end}].join")
            break unless chunk

            all_lines << chunk
            pos = chunk_end + 1
          end

          return nil if all_lines.empty?

          lines = all_lines.join.lines
          end_index = find_method_end(lines, 0)
          selected = lines[0..end_index]

          selected.map.with_index(start_line) { |line, num| "  #{num.to_s.rjust(4)}| #{line}" }.join
        end

        # girb本家のロジックを流用: インデント解析でメソッド終端を探す
        # NOTE: girb-core切り出し時の共通化候補
        def find_method_end(lines, start_index)
          return [start_index + MAX_SOURCE_LINES, lines.length - 1].min if start_index >= lines.length

          base_indent = lines[start_index][/^\s*/].length

          (start_index + 1).upto([start_index + MAX_SOURCE_LINES, lines.length - 1].min) do |i|
            line = lines[i]
            next if line.strip.empty? || line.strip.start_with?("#")

            current_indent = line[/^\s*/].length
            if current_indent <= base_indent && line.strip.start_with?("end")
              return i
            end
          end

          [start_index + MAX_SOURCE_LINES, lines.length - 1].min
        end
      end
    end
  end
end
