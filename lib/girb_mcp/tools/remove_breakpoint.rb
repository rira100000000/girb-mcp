# frozen_string_literal: true

require "mcp"

module GirbMcp
  module Tools
    class RemoveBreakpoint < MCP::Tool
      description "[Control] Remove a breakpoint. Can specify: " \
                  "(1) file + line for line breakpoints, " \
                  "(2) method for method breakpoints (e.g., 'User#save', 'User.find'), " \
                  "(3) exception_class for catch breakpoints (e.g., 'NoMethodError'), or " \
                  "(4) breakpoint_number as a fallback. " \
                  "Using named parameters is recommended over breakpoint_number, " \
                  "as numbers can shift when breakpoints are deleted. " \
                  "Use 'get_context' to see current breakpoints."

      input_schema(
        properties: {
          breakpoint_number: {
            type: "integer",
            description: "Breakpoint number to remove (shown in breakpoint listing). " \
                         "Use this as a fallback when file+line, method, or exception_class don't apply.",
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
          method: {
            type: "string",
            description: "Method name to remove breakpoints for (e.g., 'User#save', 'DataPipeline#validate'). " \
                         "Matches against method breakpoints set with set_breakpoint(method: ...).",
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
        def call(breakpoint_number: nil, file: nil, line: nil, method: nil, exception_class: nil, session_id: nil, server_context:)
          client = server_context[:session_manager].client(session_id)
          manager = server_context[:session_manager]

          if exception_class
            remove_catch_breakpoint(client, manager, exception_class)
          elsif method
            remove_method_breakpoint(client, manager, method)
          elsif file && line
            remove_by_location(client, manager, file, line)
          elsif breakpoint_number
            output = client.send_command("delete #{breakpoint_number}")
            MCP::Tool::Response.new([{ type: "text", text: output }])
          else
            MCP::Tool::Response.new([{ type: "text",
              text: "Error: Provide 'file' + 'line', 'method', 'exception_class', or 'breakpoint_number'." }])
          end
        rescue GirbMcp::Error => e
          MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.message}" }])
        end

        private

        def remove_by_location(client, manager, file, line)
          bp_list = client.send_command("info breakpoints")
          target = "#{file}:#{line}"

          nums = collect_matching_bp_numbers(bp_list) { |bp_line| bp_line.include?(target) }
          delete_breakpoints_reversed(client, nums)

          if nums.any?
            manager.remove_breakpoint_specs_matching(target)
            "Deleted breakpoint ##{nums.join(', #')} at #{target}."
          else
            "No breakpoint found at #{target}.\n\nCurrent breakpoints:\n#{bp_list}"
          end.then { |text| MCP::Tool::Response.new([{ type: "text", text: text }]) }
        end

        def remove_method_breakpoint(client, manager, method)
          bp_list = client.send_command("info breakpoints")

          nums = collect_matching_bp_numbers(bp_list) do |bp_line|
            bp_line.include?("BP - Method") && bp_line.include?(method)
          end
          delete_breakpoints_reversed(client, nums)

          if nums.any?
            manager.remove_breakpoint_specs_matching(method)
            "Deleted method breakpoint ##{nums.join(', #')} for '#{method}'."
          else
            "No method breakpoint found for '#{method}'.\n\nCurrent breakpoints:\n#{bp_list}"
          end.then { |text| MCP::Tool::Response.new([{ type: "text", text: text }]) }
        end

        def remove_catch_breakpoint(client, manager, exception_class)
          bp_list = client.send_command("info breakpoints")

          nums = collect_matching_bp_numbers(bp_list) do |bp_line|
            bp_line.include?("BP - Catch") && bp_line.include?(exception_class)
          end
          delete_breakpoints_reversed(client, nums)

          if nums.any?
            manager.remove_breakpoint_specs_matching("catch #{exception_class}")
            "Deleted catch breakpoint ##{nums.join(', #')} for '#{exception_class}'."
          else
            "No catch breakpoint found for '#{exception_class}'.\n\nCurrent breakpoints:\n#{bp_list}"
          end.then { |text| MCP::Tool::Response.new([{ type: "text", text: text }]) }
        end

        # Collect breakpoint numbers from info output that match the given block condition.
        def collect_matching_bp_numbers(bp_list)
          nums = []
          bp_list.each_line do |bp_line|
            next unless (match = bp_line.match(/#(\d+)/))
            next unless yield(bp_line)

            nums << match[1].to_i
          end
          nums
        end

        # Delete breakpoints in reverse numerical order to prevent number shifting.
        # The debug gem renumbers breakpoints after each deletion, so deleting
        # higher numbers first ensures lower numbers remain stable.
        def delete_breakpoints_reversed(client, nums)
          nums.sort.reverse_each { |num| client.send_command("delete #{num}") }
        end
      end
    end
  end
end
