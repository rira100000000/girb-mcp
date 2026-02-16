# frozen_string_literal: true

require "mcp"

module GirbMcp
  module Tools
    class ContinueExecution < MCP::Tool
      description "[Control] Resume execution of the paused Ruby process. " \
                  "Continues until the next breakpoint is hit or the program finishes. " \
                  "If the program exits, the final output including any exception details will be returned. " \
                  "Use 'finish' to run until the current method/block returns instead. " \
                  "Tip: To catch exceptions before they crash the process, use " \
                  "set_breakpoint(exception_class: 'NoMethodError') before continuing."

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

          # Check breakpoint existence before continuing (for timeout message)
          has_breakpoints = check_breakpoints(client)

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
          text = if has_breakpoints
            "Execution continued but no breakpoint was hit within the timeout period.\n" \
            "The process is still running. Use 'get_context' to check the current state."
          else
            "Process resumed successfully (running normally, no breakpoints set).\n" \
            "Use 'set_breakpoint' to add breakpoints, then 'trigger_request' or wait for the code path to execute."
          end
          MCP::Tool::Response.new([{ type: "text", text: text }])
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

        private

        # Check if any breakpoints are currently set.
        # Returns true if breakpoints exist, false otherwise.
        def check_breakpoints(client)
          output = client.send_command("info breakpoints")
          !output.strip.empty? && !output.include?("No breakpoints")
        rescue GirbMcp::Error
          false
        end
      end
    end
  end
end
