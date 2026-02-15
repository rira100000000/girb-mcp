# frozen_string_literal: true

require "mcp"

module GirbMcp
  module Tools
    class Disconnect < MCP::Tool
      description "[Control] Disconnect from the current debug session and clean up. " \
                  "For sessions started with 'run_script', the target process is also terminated. " \
                  "Use this when you are done debugging or want to restart with a clean state. " \
                  "After disconnecting, use 'run_script' or 'connect' to start a new session."

      input_schema(
        properties: {
          session_id: {
            type: "string",
            description: "Debug session ID to disconnect (uses default session if omitted)",
          },
        },
      )

      class << self
        def call(session_id: nil, server_context:)
          manager = server_context[:session_manager]

          # Get session info before disconnecting
          begin
            client = manager.client(session_id)
            pid = client.pid
            has_process = !client.wait_thread.nil?
          rescue GirbMcp::Error
            return MCP::Tool::Response.new([{ type: "text",
              text: "No active session to disconnect." }])
          end

          # Kill the target process if launched via run_script
          process_killed = false
          if has_process && pid
            begin
              Process.kill("TERM", pid.to_i)
              process_killed = true
            rescue Errno::ESRCH, Errno::EPERM
              # Process already exited
            end
          end

          # Disconnect the session (closes socket, cleans up temp files)
          manager.disconnect(session_id)

          text = "Disconnected from session."
          text += " Process #{pid} terminated." if process_killed
          text += "\n\nUse 'run_script' or 'connect' to start a new debug session."

          MCP::Tool::Response.new([{ type: "text", text: text }])
        end
      end
    end
  end
end
