# frozen_string_literal: true

require "mcp"

module DebugMcp
  module Tools
    class Next < MCP::Tool
      description "[Control] Step over to the next line without entering method calls. " \
                  "Use 'step' instead to enter called methods. " \
                  "Inside a block (e.g., each, map, reject), 'next' advances within the current " \
                  "block iteration. To skip to the NEXT ITERATION, use set_breakpoint with one_shot: true " \
                  "on the first line of the block body, then continue_execution. " \
                  "Use 'finish' to exit the current block/method entirely. " \
                  "If an exception is raised and rescued during the step, it will be reported automatically."

      annotations(
        title: "Step Over",
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

      class << self
        def call(session_id: nil, server_context:)
          client = server_context[:session_manager].client(session_id)

          output = client.send_command("next")

          if output.strip.empty? && client.process_finished?
            text = DebugMcp::ExitMessageBuilder.build_exit_message(
              "Program exited during step.", output, client,
            )
            return MCP::Tool::Response.new([{ type: "text", text: text }])
          end

          client.cleanup_one_shot_breakpoints(output)
          output = DebugMcp::StopEventAnnotator.annotate_breakpoint_hit(output)
          output = DebugMcp::StopEventAnnotator.enrich_stop_context(output, client)

          MCP::Tool::Response.new([{ type: "text", text: output }])
        rescue DebugMcp::SessionError => e
          text = if e.message.include?("session ended") || e.message.include?("finished execution")
            DebugMcp::ExitMessageBuilder.build_exit_message("Program exited during step.", e.final_output, client)
          else
            "Error: #{e.message}"
          end
          MCP::Tool::Response.new([{ type: "text", text: text }])
        rescue DebugMcp::ConnectionError => e
          text = if e.message.include?("Connection lost") || e.message.include?("connection closed")
            DebugMcp::ExitMessageBuilder.build_exit_message("Program exited during step.", e.final_output, client)
          else
            "Error: #{e.message}"
          end
          MCP::Tool::Response.new([{ type: "text", text: text }])
        rescue DebugMcp::Error => e
          MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.message}" }])
        end
      end
    end
  end
end
