# frozen_string_literal: true

require "mcp"

module GirbMcp
  module Tools
    class ContinueExecution < MCP::Tool
      description "[Control] Resume execution of the paused Ruby process. " \
                  "Continues until the next breakpoint is hit or the program finishes. " \
                  "If the program exits (normally or due to an unhandled exception), " \
                  "the final output including any exception details will be returned. " \
                  "Use 'finish' to run until the current method/block returns instead. " \
                  "Tip: To catch exceptions before they crash the process, use " \
                  "set_breakpoint(exception_class: 'NoMethodError') before continuing. " \
                  "After resuming, use 'get_context' to see where execution stopped next."

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

          output = client.send_continue

          # The debug gem may send an `input` prompt just before the process exits
          # (e.g., on a return event from the main script). When output is empty,
          # check if the process has actually exited.
          if output.strip.empty? && client.process_finished?
            text = GirbMcp::ExitMessageBuilder.build_exit_message(
              "Program finished execution.", output, client,
            )
            return MCP::Tool::Response.new([{ type: "text", text: text }])
          end

          client.cleanup_one_shot_breakpoints(output)
          output = GirbMcp::StopEventAnnotator.annotate_breakpoint_hit(output)
          output = GirbMcp::StopEventAnnotator.enrich_stop_context(output, client)

          MCP::Tool::Response.new([{ type: "text", text: "Execution resumed.\n\n#{output}" }])
        rescue GirbMcp::SessionError => e
          text = if e.message.include?("session ended") || e.message.include?("finished execution")
            GirbMcp::ExitMessageBuilder.build_exit_message("Program finished execution.", e.final_output, client)
          else
            "Error: #{e.message}"
          end
          MCP::Tool::Response.new([{ type: "text", text: text }])
        rescue GirbMcp::TimeoutError
          MCP::Tool::Response.new([{ type: "text", text:
            "Execution continued but no breakpoint was hit within the timeout period.\n" \
            "The program may still be running. Use 'get_context' to check the current state." }])
        rescue GirbMcp::ConnectionError => e
          text = if e.message.include?("Connection lost") || e.message.include?("connection closed")
            GirbMcp::ExitMessageBuilder.build_exit_message(
              "Program finished execution (connection closed).", e.final_output, client,
            )
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
