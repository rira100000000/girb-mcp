# frozen_string_literal: true

require "mcp"

module GirbMcp
  module Tools
    class Finish < MCP::Tool
      description "[Control] Run until the current method or block returns, then pause. " \
                  "After finish, execution stops at the CALLER's frame (the line that invoked the method). " \
                  "The line shown with => has already been executed. " \
                  "This exits the current block/method entirely — for iterators like each/map, " \
                  "this skips ALL remaining iterations. " \
                  "To skip to just the NEXT ITERATION instead, use set_breakpoint with one_shot: true " \
                  "on the first line of the block body, then continue_execution."

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

          output = client.send_command("finish", timeout: DebugClient::CONTINUE_TIMEOUT)

          if output.strip.empty? && client.process_finished?
            text = GirbMcp::ExitMessageBuilder.build_exit_message(
              "Program exited during finish.", output, client,
            )
            return MCP::Tool::Response.new([{ type: "text", text: text }])
          end

          client.cleanup_one_shot_breakpoints(output)
          output = GirbMcp::StopEventAnnotator.annotate_breakpoint_hit(output)
          output = GirbMcp::StopEventAnnotator.enrich_stop_context(output, client)

          header = "Method/block returned (stopped at caller's frame)."
          MCP::Tool::Response.new([{ type: "text", text: "#{header}\n\n#{output}" }])
        rescue GirbMcp::SessionError => e
          text = if e.message.include?("session ended") || e.message.include?("finished execution")
            GirbMcp::ExitMessageBuilder.build_exit_message("Program exited during finish.", e.final_output, client)
          else
            "Error: #{e.message}"
          end
          MCP::Tool::Response.new([{ type: "text", text: text }])
        rescue GirbMcp::ConnectionError => e
          text = if e.message.include?("Connection lost") || e.message.include?("connection closed")
            GirbMcp::ExitMessageBuilder.build_exit_message("Program exited during finish.", e.final_output, client)
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
