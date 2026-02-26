# frozen_string_literal: true

require "mcp"
require "base64"

module GirbMcp
  module Tools
    class SetBreakpoint < MCP::Tool
      description "[Control] Set a breakpoint. Three modes are available:\n" \
                  "1. Line breakpoint: provide file + line. Pauses when the line is reached. " \
                  "Use condition to break only when criteria are met (e.g., condition: \"user.id == 1\"). " \
                  "Use one_shot: true to fire only once and auto-remove (useful in loops/blocks).\n" \
                  "2. Method breakpoint: provide method (e.g., 'DataPipeline#validate', 'User.find'). " \
                  "Pauses when the method is called. Use 'Class#method' for instance methods, " \
                  "'Class.method' for class methods. No need to know the file or line number.\n" \
                  "3. Exception breakpoint: provide exception_class (e.g., 'NoMethodError') to pause " \
                  "when that exception is raised, BEFORE it crashes the process."

      annotations(
        title: "Set Breakpoint",
        read_only_hint: false,
        destructive_hint: false,
        open_world_hint: false,
      )

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
          method: {
            type: "string",
            description: "Method name to break on (e.g., 'DataPipeline#validate' for instance method, " \
                         "'User.find' for class method). Pauses when the method is called. " \
                         "No need to know the file path or line number.",
          },
          exception_class: {
            type: "string",
            description: "Exception class to catch (e.g., 'NoMethodError', 'RuntimeError', 'ArgumentError'). " \
                         "When this exception is raised anywhere, execution pauses BEFORE the exception propagates. " \
                         "This is the best way to debug crashes — set it before calling continue_execution.",
          },
          condition: {
            type: "string",
            description: "Optional condition expression for line/method breakpoints (e.g., 'user.id == 1')",
          },
          one_shot: {
            type: "boolean",
            description: "If true, the breakpoint fires only once and is automatically removed after " \
                         "the first hit. Useful for stopping inside a block/loop without repeated stops. " \
                         "Applies to line and method breakpoints.",
          },
          session_id: {
            type: "string",
            description: "Debug session ID (uses default session if omitted)",
          },
        },
      )

      class << self
        def call(file: nil, line: nil, method: nil, exception_class: nil, condition: nil, one_shot: nil, session_id: nil, server_context:)
          manager = server_context[:session_manager]
          client = manager.client(session_id)
          client.auto_repause!

          if exception_class
            set_catch_breakpoint(client, manager, exception_class)
          elsif method
            set_method_breakpoint(client, manager, method, condition: condition, one_shot: one_shot)
          elsif file && line
            set_line_breakpoint(client, manager, file, line, condition: condition, one_shot: one_shot)
          else
            MCP::Tool::Response.new([{ type: "text",
              text: "Error: Provide 'file' + 'line' for a line breakpoint, " \
                    "'method' for a method breakpoint (e.g., 'User#save'), " \
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

          output = append_condition_warning(client, condition, output)
          MCP::Tool::Response.new([{ type: "text", text: output }])
        end

        def set_method_breakpoint(client, manager, method, condition: nil, one_shot: nil)
          command = "break #{method}"
          command += " if: #{condition}" if condition

          output = client.send_command(command)
          output = GirbMcp::StopEventAnnotator.annotate_breakpoint_set(output)

          manager.record_breakpoint(command) unless one_shot

          if one_shot
            if (match = output.match(/#(\d+)/))
              bp_num = match[1].to_i
              client.register_one_shot(bp_num)
              output += "\n(one-shot: will be auto-removed after first hit)"
            end
          end

          output = append_condition_warning(client, condition, output)
          MCP::Tool::Response.new([{ type: "text", text: output }])
        end

        # Validate condition syntax and append warning if invalid.
        def append_condition_warning(client, condition, output)
          return output unless condition

          warning = validate_condition(client, condition)
          warning ? "#{output}\n\n#{warning}" : output
        end

        # Check condition syntax via RubyVM::InstructionSequence.compile in the target process.
        # Uses Base64 encoding to safely pass arbitrary condition strings without escaping issues.
        # Returns a warning string if syntax error detected, nil otherwise.
        def validate_condition(client, condition)
          encoded = Base64.strict_encode64(condition.encode(Encoding::UTF_8))
          result = client.send_command(
            "p begin; require 'base64'; " \
            "RubyVM::InstructionSequence.compile(Base64.decode64('#{encoded}')); " \
            "nil; rescue SyntaxError => e; e.message; rescue LoadError; " \
            "RubyVM::InstructionSequence.compile(#{condition.inspect}); nil; " \
            "rescue SyntaxError => e; e.message; end",
          )
          cleaned = result.strip.sub(/\A=> /, "")
          return nil if cleaned == "nil" || cleaned.empty?

          # Remove surrounding quotes
          cleaned = cleaned[1..-2] if cleaned.start_with?('"') && cleaned.end_with?('"')
          return nil if cleaned == "nil" || cleaned.empty?

          "WARNING: Condition may have a syntax error: #{cleaned}\n" \
          "The breakpoint was set but will never fire if the condition is invalid."
        rescue GirbMcp::Error
          nil
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
