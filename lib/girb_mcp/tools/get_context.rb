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

      # Pattern for detecting framework/gem frames in call stack.
      FRAMEWORK_PATH_PATTERN = %r{/gems/|/\.rbenv/|/\.bundle/|/vendor/bundle/|\[C\]|/ruby/\d}

      class << self
        def call(session_id: nil, server_context:)
          client = server_context[:session_manager].client(session_id)
          client.auto_repause!

          parts = []
          total_truncated = 0

          # Show trap context warning as the first section.
          # Use cached value if available to avoid an extra round-trip.
          in_trap = if client.respond_to?(:trap_context) && !client.trap_context.nil?
            client.trap_context
          elsif client.respond_to?(:in_trap_context?)
            client.in_trap_context?
          end
          if in_trap
            parts << "=== Context: Signal Trap ===\n" \
                     "Restricted: DB queries, require, autoloading, method breakpoints\n" \
                     "Available: evaluate_code (simple expressions), set_breakpoint (file:line), rails_routes\n" \
                     "To escape: set_breakpoint(file, line) + trigger_request"
          end

          # Collect each section independently so partial results are still useful
          variable_commands = %w[info\ locals info\ ivars]
          sections = [
            ["Current Location", "list"],
            ["Local Variables", "info locals"],
            ["Instance Variables", "info ivars"],
            ["Call Stack", "bt"],
            ["Breakpoints", "info breakpoints"],
          ]

          bt_raw = nil
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

            # Summarize long call stacks by collapsing framework frames
            if command == "bt"
              bt_raw = output
              output = summarize_call_stack(output)
            end

            parts << "=== #{title} ===\n#{output}"
          rescue GirbMcp::TimeoutError
            parts << "=== #{title} ===\n(timed out)"
          end

          # Annotate return events: the return value is shown in bt output (#=>)
          # and in local variables (%return). Add a note so the agent understands
          # the current line has already executed.
          if bt_raw && return_event_frame?(bt_raw)
            return_note = "=== Stop Event: Return ===\n" \
                          "The current line (=>) has ALREADY been executed. " \
                          "You are seeing the state AFTER this line ran.\n" \
                          "Return value is shown in Call Stack (#=>) and Local Variables (%return)."

            # Check if the return is due to an exception
            begin
              if (exception_info = client.check_current_exception)
                return_note += "\n\nException in scope: #{exception_info}\n" \
                               "This method/block is returning due to an exception, not a normal return."
              end
            rescue GirbMcp::Error
              # Best-effort
            end

            parts << return_note
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

        # Check if the current frame (=>) in bt output indicates a return event.
        # The debug gem appends "#=>" to the frame line at return/b_return/c_return events:
        #   =>#0  Class#method at file.rb:10 #=> return_value
        def return_event_frame?(bt_output)
          bt_output.each_line do |line|
            return line.include?("#=>") if line.include?("=>#")
          end
          false
        end

        # Summarize a long call stack by collapsing consecutive framework frames.
        # App code frames are preserved; gem/internal frames are collapsed into
        # summary lines like "  ... 12 framework frames (actionpack, rack, puma) ..."
        def summarize_call_stack(output)
          lines = output.lines
          return output if lines.size <= 15

          result = []
          gem_group = []

          lines.each do |line|
            if framework_frame?(line)
              gem_group << line
            else
              if gem_group.any?
                result << collapse_gem_frames(gem_group)
                gem_group = []
              end
              result << line
            end
          end
          result << collapse_gem_frames(gem_group) if gem_group.any?

          result.join
        end

        def framework_frame?(line)
          line.match?(FRAMEWORK_PATH_PATTERN)
        end

        def collapse_gem_frames(frames)
          # Extract gem names from paths like /gems/actionpack-7.0.0/lib/...
          # Gem names always start with a letter, so we skip numeric directories
          # like /gems/3.3.0/ in paths such as ruby/gems/3.3.0/gems/actionpack-7.0.0/
          gem_names = frames.filter_map { |f|
            if (m = f.match(%r{/gems/([a-zA-Z][^/]*?)(?:-\d[\d.]*)?/}))
              m[1]
            elsif f.include?("[C]")
              "C"
            end
          }.uniq.sort

          label = gem_names.empty? ? "framework" : gem_names.join(", ")
          count_label = frames.size == 1 ? "1 framework frame" : "#{frames.size} framework frames"
          "  ... #{count_label} (#{label}) ...\n"
        end

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
