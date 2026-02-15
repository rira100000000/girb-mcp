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

          # Collect multiple pieces of information about the object
          parts = []

          # Get the value (primary - if this fails, the expression is likely invalid)
          value_output = client.send_command("pp #{expression}")
          parts << "Value:\n#{value_output}"

          # Get the class (secondary - graceful failure)
          begin
            class_output = client.send_command("p #{expression}.class")
            parts << "Class: #{class_output.strip}"
          rescue GirbMcp::TimeoutError
            parts << "Class: (timed out)"
          end

          # Get instance variables (secondary - graceful failure)
          begin
            ivars_output = client.send_command("p #{expression}.instance_variables")
            parts << "Instance variables: #{ivars_output.strip}"
          rescue GirbMcp::TimeoutError
            parts << "Instance variables: (timed out)"
          end

          MCP::Tool::Response.new([{ type: "text", text: parts.join("\n\n") }])
        rescue GirbMcp::Error => e
          MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.message}" }])
        end
      end
    end
  end
end
