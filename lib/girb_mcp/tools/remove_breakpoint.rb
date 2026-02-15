# frozen_string_literal: true

require "mcp"

module GirbMcp
  module Tools
    class RemoveBreakpoint < MCP::Tool
      description "[Control] Remove a breakpoint. Can specify: " \
                  "(1) file + line for line breakpoints, " \
                  "(2) exception_class for catch breakpoints (e.g., 'NoMethodError'), or " \
                  "(3) breakpoint_number as a fallback. " \
                  "Using file + line or exception_class is recommended, as breakpoint numbers can shift. " \
                  "Use 'get_context' to see current breakpoints."

      input_schema(
        properties: {
          breakpoint_number: {
            type: "integer",
            description: "Breakpoint number to remove (shown in breakpoint listing). " \
                         "Use this as a fallback when file+line or exception_class don't apply.",
          },
          file: {
            type: "string",
            description: "File path of the breakpoint to remove (e.g., 'app/models/user.rb'). " \
                         "Must be used together with 'line'.",
          },
          line: {
            type: "integer",
            description: "Line number of the breakpoint to remove. Must be used together with 'file'.",
          },
          exception_class: {
            type: "string",
            description: "Exception class name to remove catch breakpoints for (e.g., 'NoMethodError'). " \
                         "Removes all catch breakpoints matching this class.",
          },
          session_id: {
            type: "string",
            description: "Debug session ID (uses default session if omitted)",
          },
        },
      )

      class << self
        def call(breakpoint_number: nil, file: nil, line: nil, exception_class: nil, session_id: nil, server_context:)
          client = server_context[:session_manager].client(session_id)
          manager = server_context[:session_manager]

          if exception_class
            remove_catch_breakpoint(client, manager, exception_class)
          elsif file && line
            remove_by_location(client, manager, file, line)
          elsif breakpoint_number
            output = client.send_command("delete #{breakpoint_number}")
            MCP::Tool::Response.new([{ type: "text", text: output }])
          else
            MCP::Tool::Response.new([{ type: "text",
              text: "Error: Provide 'file' + 'line', 'exception_class', or 'breakpoint_number'." }])
          end
        rescue GirbMcp::Error => e
          MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.message}" }])
        end

        private

        def remove_by_location(client, manager, file, line)
          bp_list = client.send_command("info breakpoints")
          target = "#{file}:#{line}"

          deleted = []
          bp_list.each_line do |bp_line|
            # Match lines like: #0  BP - Line  /path/to/file.rb:47 (if: ...)
            next unless (match = bp_line.match(/#(\d+)/))
            next unless bp_line.include?(target)

            num = match[1].to_i
            client.send_command("delete #{num}")
            deleted << num
          end

          if deleted.any?
            manager.remove_breakpoint_specs_matching(target)
            "Deleted breakpoint ##{deleted.join(', #')} at #{target}."
          else
            "No breakpoint found at #{target}.\n\nCurrent breakpoints:\n#{bp_list}"
          end.then { |text| MCP::Tool::Response.new([{ type: "text", text: text }]) }
        end

        def remove_catch_breakpoint(client, manager, exception_class)
          bp_list = client.send_command("info breakpoints")

          deleted = []
          bp_list.each_line do |bp_line|
            next unless bp_line.include?("BP - Catch")
            next unless bp_line.include?(exception_class)
            next unless (match = bp_line.match(/#(\d+)/))

            num = match[1].to_i
            client.send_command("delete #{num}")
            deleted << num
          end

          if deleted.any?
            manager.remove_breakpoint_specs_matching("catch #{exception_class}")
            "Deleted catch breakpoint ##{deleted.join(', #')} for '#{exception_class}'."
          else
            "No catch breakpoint found for '#{exception_class}'.\n\nCurrent breakpoints:\n#{bp_list}"
          end.then { |text| MCP::Tool::Response.new([{ type: "text", text: text }]) }
        end
      end
    end
  end
end
