# frozen_string_literal: true

require "mcp"

module GirbMcp
  module Tools
    class GetContext < MCP::Tool
      description "[Investigation] Get the full execution context of the paused Ruby process: " \
                  "current source location, local variables, instance variables, call stack, " \
                  "and breakpoints. " \
                  "Best used: (1) after connecting/run_script to understand the initial state, " \
                  "(2) after continue_execution hits a breakpoint to see variable values, " \
                  "(3) when you need to check what breakpoints are set. " \
                  "Not needed after every next/step — those already include source listing in their output. " \
                  "Note: Variable values may be truncated. " \
                  "Use 'evaluate_code' or 'inspect_object' for full details on specific variables."

      input_schema(
        properties: {
          session_id: {
            type: "string",
            description: "Debug session ID (uses default session if omitted)",
          },
        },
      )

      # Pattern for detecting truncated values in debug gem output.
      # Matches lines where the value portion ends with "..." possibly followed
      # by closing delimiters like ], }, ", or >.
      TRUNCATION_PATTERN = /\.\.\.[\]}"'>)]*\s*\z/

      class << self
        def call(session_id: nil, server_context:)
          client = server_context[:session_manager].client(session_id)

          parts = []
          total_truncated = 0

          # Collect each section independently so partial results are still useful
          variable_commands = %w[info\ locals info\ ivars]
          sections = [
            ["Current Location", "list"],
            ["Local Variables", "info locals"],
            ["Instance Variables", "info ivars"],
            ["Call Stack", "bt"],
            ["Breakpoints", "info breakpoints"],
          ]

          sections.each do |title, command|
            output = client.send_command(command)

            # For variable sections, detect and annotate truncated values
            if variable_commands.include?(command)
              output, truncated_count = annotate_truncated_values(output)
              if truncated_count > 0
                total_truncated += truncated_count
                title += " (#{truncated_count} truncated)"
              end
            end

            parts << "=== #{title} ===\n#{output}"
          rescue GirbMcp::TimeoutError
            parts << "=== #{title} ===\n(timed out)"
          end

          # Best-effort: show return value if stopped at a method/block return event.
          # __return_value__ is only available at return/b_return TracePoint events.
          begin
            ret_val = client.send_command("p __return_value__")
            cleaned = ret_val.strip
            unless cleaned.include?("NameError") || cleaned.include?("undefined")
              return_section = "=== Return Value (at return event) ===\n#{cleaned}\n" \
                               "Note: The current line (=>) has ALREADY been executed. " \
                               "You are seeing the state AFTER this line ran."

              # Check if the return is due to an exception
              if (exception_info = client.check_current_exception)
                return_section += "\n\nException in scope: #{exception_info}\n" \
                                  "This method/block is returning due to an exception, not a normal return. " \
                                  "The return value above may be nil or meaningless."
              end

              parts << return_section
            end
          rescue GirbMcp::Error
            # __return_value__ not available at this stop point
          end

          if total_truncated > 0
            parts << "---\n#{total_truncated} variable(s) have truncated values. " \
                     "Use 'inspect_object' to see full contents (e.g., inspect_object(expression: 'variable_name'))."
          else
            parts << "---\nTip: Use 'evaluate_code' or 'inspect_object' for detailed variable inspection."
          end

          MCP::Tool::Response.new([{ type: "text", text: parts.join("\n\n") }])
        rescue GirbMcp::Error => e
          MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.message}" }])
        end

        private

        # Annotate truncated variable lines with [truncated] marker.
        # Returns [annotated_output, truncated_count].
        def annotate_truncated_values(output)
          truncated_count = 0
          annotated = output.each_line.map do |line|
            # Variable lines in `info locals`/`info ivars` follow the pattern:
            #   name = value
            # Only check lines that contain " = " (variable assignments)
            if line.include?(" = ") && line.match?(TRUNCATION_PATTERN)
              truncated_count += 1
              "#{line.chomp}  [truncated]\n"
            else
              line
            end
          end.join

          [annotated, truncated_count]
        end
      end
    end
  end
end
