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

      HTTP_JOIN_TIMEOUT = 5

      class << self
        def call(session_id: nil, server_context:)
          client = server_context[:session_manager].client(session_id)

          # Check breakpoint existence before continuing (for timeout message)
          has_breakpoints = check_breakpoints(client)

          # Retrieve and clear pending HTTP info before continuing
          pending = client.pending_http
          client.pending_http = nil if pending

          output = client.send_continue

          # The debug gem may send an `input` prompt just before the process exits
          # (e.g., on a return event from the main script). When output is empty,
          # check if the process has actually exited.
          if output.strip.empty? && client.process_finished?
            text = GirbMcp::ExitMessageBuilder.build_exit_message(
              "Program finished execution.", output, client,
            )
            text = append_http_response(text, pending)
            return MCP::Tool::Response.new([{ type: "text", text: text }])
          end

          client.cleanup_one_shot_breakpoints(output)
          output = GirbMcp::StopEventAnnotator.annotate_breakpoint_hit(output)
          output = GirbMcp::StopEventAnnotator.enrich_stop_context(output, client)

          text = "Execution resumed.\n\n#{output}"
          text = append_http_response(text, pending)
          MCP::Tool::Response.new([{ type: "text", text: text }])
        rescue GirbMcp::SessionError => e
          text = if e.message.include?("session ended") || e.message.include?("finished execution")
            GirbMcp::ExitMessageBuilder.build_exit_message("Program finished execution.", e.final_output, client)
          else
            "Error: #{e.message}"
          end
          text = append_http_response(text, pending)
          MCP::Tool::Response.new([{ type: "text", text: text }])
        rescue GirbMcp::TimeoutError
          text = if has_breakpoints
            "Execution continued but no breakpoint was hit within the timeout period.\n" \
            "The process is still running. Use 'get_context' to check the current state."
          else
            "Process resumed successfully (running normally, no breakpoints set).\n" \
            "Use 'set_breakpoint' to add breakpoints, then 'trigger_request' or wait for the code path to execute."
          end
          text = append_http_response(text, pending)
          MCP::Tool::Response.new([{ type: "text", text: text }])
        rescue GirbMcp::ConnectionError => e
          text = if e.message.include?("Connection lost") || e.message.include?("connection closed")
            GirbMcp::ExitMessageBuilder.build_exit_message(
              "Program finished execution (connection closed).", e.final_output, client,
            )
          else
            "Error: #{e.message}"
          end
          text = append_http_response(text, pending)
          MCP::Tool::Response.new([{ type: "text", text: text }])
        rescue GirbMcp::Error => e
          MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.message}" }])
        end

        private

        # Join the pending HTTP thread and append the response to the text.
        def append_http_response(text, pending)
          return text unless pending

          thread = pending[:thread]
          holder = pending[:holder]
          method = pending[:method]
          url = pending[:url]

          thread.join(HTTP_JOIN_TIMEOUT)

          if holder[:error]
            "#{text}\n\n--- HTTP Response ---\nHTTP #{method} #{url}\nRequest error: #{holder[:error].message}"
          elsif holder[:response]
            formatted = GirbMcp::Tools::TriggerRequest.send(:format_response, holder[:response])
            "#{text}\n\n--- HTTP Response ---\nHTTP #{method} #{url}\n#{formatted}"
          elsif holder[:done]
            "#{text}\n\n--- HTTP Response ---\nHTTP #{method} #{url}\nUnexpected state: request completed without response."
          else
            "#{text}\n\n--- HTTP Response ---\nHTTP #{method} #{url}\nRequest still in progress (timed out waiting)."
          end
        rescue StandardError
          text
        end

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
