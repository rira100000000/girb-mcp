# frozen_string_literal: true

require "mcp"

module GirbMcp
  module Tools
    class Step < MCP::Tool
      description "[Control] Step into the next method call. Enters called methods to trace " \
                  "execution in detail. Use 'next' instead to stay in the current method. " \
                  "Use 'finish' to run until the current method/block returns. " \
                  "If an exception is raised and rescued during the step, it will be reported automatically."

      input_schema(
        properties: {
          session_id: {
            type: "string",
            description: "Debug session ID (uses default session if omitted)",
          },
        },
      )

      class << self
        def call(session_id: nil, server_context:)
          client = server_context[:session_manager].client(session_id)

          output = client.send_command("step")

          if output.strip.empty? && client.process_finished?
            text = GirbMcp::ExitMessageBuilder.build_exit_message(
              "Program exited during step.", output, client,
            )
            return MCP::Tool::Response.new([{ type: "text", text: text }])
          end

          client.cleanup_one_shot_breakpoints(output)
          output = GirbMcp::StopEventAnnotator.annotate_breakpoint_hit(output)
          output = GirbMcp::StopEventAnnotator.enrich_stop_context(output, client)

          MCP::Tool::Response.new([{ type: "text", text: output }])
        rescue GirbMcp::SessionError => e
          text = if e.message.include?("session ended") || e.message.include?("finished execution")
            GirbMcp::ExitMessageBuilder.build_exit_message("Program exited during step.", e.final_output, client)
          else
            "Error: #{e.message}"
          end
          MCP::Tool::Response.new([{ type: "text", text: text }])
        rescue GirbMcp::ConnectionError => e
          text = if e.message.include?("Connection lost") || e.message.include?("connection closed")
            GirbMcp::ExitMessageBuilder.build_exit_message("Program exited during step.", e.final_output, client)
          else
            "Error: #{e.message}"
          end
          MCP::Tool::Response.new([{ type: "text", text: text }])
        rescue GirbMcp::Error => e
          MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.message}" }])
        end
      end
    end
  end
end
