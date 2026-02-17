# frozen_string_literal: true

require "mcp"

module GirbMcp
  module Tools
    class InspectObject < MCP::Tool
      description "[Investigation] Deep-inspect a Ruby object in the paused process. " \
                  "Returns the value, class, and instance variables. " \
                  "More detailed than evaluate_code — use this to understand an object's internal state."

      input_schema(
        properties: {
          expression: {
            type: "string",
            description: "Variable name or Ruby expression to inspect (e.g., 'user', '@items.first')",
          },
          session_id: {
            type: "string",
            description: "Debug session ID (uses default session if omitted)",
          },
        },
        required: ["expression"],
      )

      class << self
        def call(expression:, session_id: nil, server_context:)
          client = server_context[:session_manager].client(session_id)

          parts = []

          # RT 1: Get the pretty-printed value (primary - if this fails, expression is invalid)
          value_output = client.send_command("pp #{expression}")
          parts << "Value:\n#{value_output}"

          # RT 2: Get class + instance variables in a single command
          begin
            meta_output = client.send_command(
              "p [(#{expression}).class.to_s, (#{expression}).instance_variables]",
            )
            class_name, ivars = parse_meta(meta_output)
            parts << "Class: #{class_name}" if class_name
            parts << "Instance variables: #{ivars}" if ivars
          rescue GirbMcp::TimeoutError
            parts << "Class: (timed out)"
            parts << "Instance variables: (timed out)"
          end

          text = parts.join("\n\n")
          text = append_trap_context_note(client, text)
          MCP::Tool::Response.new([{ type: "text", text: text }])
        rescue GirbMcp::Error => e
          MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.message}" }])
        end

        private

        # Parse combined meta output: => ["ClassName", [:@ivar1, :@ivar2]]
        # Returns [class_name, ivars_string] or falls back to raw output.
        def parse_meta(output)
          cleaned = output.strip.sub(/\A=> /, "")
          # Match: ["ClassName", [...]]
          if (match = cleaned.match(/\A\["([^"]*)",\s*(\[.*\])\]\z/))
            [match[1], match[2]]
          else
            # Fallback: return raw output as class info
            [cleaned, nil]
          end
        end

        def append_trap_context_note(client, text)
          return text unless client.respond_to?(:trap_context) && client.trap_context
          "#{text}\n\n[trap context]"
        end
      end
    end
  end
end
