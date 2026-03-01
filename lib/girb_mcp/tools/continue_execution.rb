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

      annotations(
        title: "Continue Execution",
        read_only_hint: false,
        destructive_hint: false,
        open_world_hint: false,
      )

      input_schema(
        properties: {
          session_id: {
            type: "string",
            description: "Debug session ID (uses default session if omitted)",
          },
        },
      )

      HTTP_JOIN_TIMEOUT = 10

      class << self
        def call(session_id: nil, server_context:)
          client = server_context[:session_manager].client(session_id)

          # Check breakpoint existence before continuing (for timeout message)
          has_breakpoints = check_breakpoints(client)

          # Retrieve and clear pending HTTP info before continuing
          pending = client.pending_http
          client.pending_http = nil if pending

          output = if pending
            client.send_continue { pending[:holder][:done] }
          else
            client.send_continue
          end

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
            ">>> PROCESS STATE: RUNNING (not paused) <<<\n\n" \
            "No breakpoint was hit within the timeout period.\n\n" \
            "Next steps:\n" \
            "1. set_breakpoint on a specific code path\n" \
            "2. trigger_request to send an HTTP request (auto-resumes)\n" \
            "3. disconnect to detach"
          else
            ">>> PROCESS STATE: RUNNING (not paused) <<<\n\n" \
            "Process resumed successfully (no breakpoints set).\n\n" \
            "Next steps:\n" \
            "1. set_breakpoint to add breakpoints\n" \
            "2. trigger_request to send an HTTP request and hit a breakpoint"
          end
          timeout_sec = server_context[:session_manager]&.timeout
          if timeout_sec
            text += "\n\nNote: The debug session will remain active for " \
                    "#{timeout_sec / 60} minutes of inactivity. Any tool call resets the timer."
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
            elapsed_note = format_http_elapsed(pending[:started_at])
            thread_note = thread.alive? ? "still running" : "thread exited without response"
            "#{text}\n\n--- HTTP Response ---\nHTTP #{method} #{url}\n" \
              "Request still in progress (#{thread_note}#{elapsed_note})."
          end
        rescue StandardError
          text
        end

        # Format elapsed time since HTTP request started.
        def format_http_elapsed(started_at)
          return "" unless started_at

          elapsed = (Time.now - started_at).to_i
          ", started #{elapsed}s ago"
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
