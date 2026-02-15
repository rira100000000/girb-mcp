# frozen_string_literal: true

require "mcp"

module GirbMcp
  module Tools
    class SetBreakpoint < MCP::Tool
      description "[Control] Set a breakpoint at a file and line number, or catch an exception class. " \
                  "For line breakpoints: provide file + line. Execution will pause when the line is reached. " \
                  "Use a condition to break only when specific criteria are met " \
                  "(e.g., condition: \"user.id == 1\"). " \
                  "Use one_shot: true for breakpoints that should fire only once and auto-remove themselves " \
                  "(useful inside blocks/loops to avoid repeated stops on every iteration). " \
                  "For exception breakpoints: provide exception_class (e.g., 'NoMethodError') to pause " \
                  "execution when that exception is raised, BEFORE it crashes the process."

      input_schema(
        properties: {
          file: {
            type: "string",
            description: "File path (e.g., 'app/controllers/users_controller.rb'). Required for line breakpoints.",
          },
          line: {
            type: "integer",
            description: "Line number to break at. Required for line breakpoints.",
          },
          exception_class: {
            type: "string",
            description: "Exception class to catch (e.g., 'NoMethodError', 'RuntimeError', 'ArgumentError'). " \
                         "When this exception is raised anywhere, execution pauses BEFORE the exception propagates. " \
                         "This is the best way to debug crashes — set it before calling continue_execution.",
          },
          condition: {
            type: "string",
            description: "Optional condition expression for line breakpoints (e.g., 'user.id == 1')",
          },
          one_shot: {
            type: "boolean",
            description: "If true, the breakpoint fires only once and is automatically removed after " \
                         "the first hit. Useful for stopping inside a block/loop without repeated stops. " \
                         "Only applies to line breakpoints.",
          },
          session_id: {
            type: "string",
            description: "Debug session ID (uses default session if omitted)",
          },
        },
      )

      class << self
        def call(file: nil, line: nil, exception_class: nil, condition: nil, one_shot: nil, session_id: nil, server_context:)
          manager = server_context[:session_manager]
          client = manager.client(session_id)

          if exception_class
            set_catch_breakpoint(client, manager, exception_class)
          elsif file && line
            set_line_breakpoint(client, manager, file, line, condition: condition, one_shot: one_shot)
          else
            MCP::Tool::Response.new([{ type: "text",
              text: "Error: Provide 'file' + 'line' for a line breakpoint, " \
                    "or 'exception_class' for an exception breakpoint." }])
          end
        rescue GirbMcp::Error => e
          MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.message}" }])
        end

        private

        def set_line_breakpoint(client, manager, file, line, condition: nil, one_shot: nil)
          command = "break #{file}:#{line}"
          command += " if: #{condition}" if condition

          output = client.send_command(command)
          output = GirbMcp::StopEventAnnotator.annotate_breakpoint_set(output)

          # Record for preservation across sessions (skip one-shot breakpoints)
          manager.record_breakpoint(command) unless one_shot

          if one_shot
            # Parse breakpoint number from output like "#3  BP - Line  /path:47"
            if (match = output.match(/#(\d+)/))
              bp_num = match[1].to_i
              client.register_one_shot(bp_num)
              output += "\n(one-shot: will be auto-removed after first hit)"
            end
          end

          MCP::Tool::Response.new([{ type: "text", text: output }])
        end

        def set_catch_breakpoint(client, manager, exception_class)
          command = "catch #{exception_class}"
          output = client.send_command(command)
          manager.record_breakpoint(command)

          MCP::Tool::Response.new([{ type: "text", text: output }])
        end
      end
    end
  end
end
