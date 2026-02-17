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
          else
            # Restore original SIGINT handler before disconnecting
            begin
              client.send_command(
                "p $_girb_orig_int ? (trap('INT',$_girb_orig_int);$_girb_orig_int=nil;:ok) : nil"
              )
            rescue GirbMcp::Error
              # Best-effort
            end

            # For connect sessions (e.g., Rails server): delete all breakpoints
            # then resume the process before disconnecting.
            # Without BP deletion, the process may immediately hit a remaining
            # breakpoint and pause again with no debugger attached.
            begin
              bp_output = client.send_command("info breakpoints")
              unless bp_output.strip.empty?
                bp_output.each_line do |line|
                  if (match = line.match(/#(\d+)/))
                    client.send_command("delete #{match[1]}") rescue nil
                  end
                end
              end
            rescue GirbMcp::Error
              # Best-effort: proceed to continue even if BP deletion fails
            end
            client.send_command_no_wait("c")
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
