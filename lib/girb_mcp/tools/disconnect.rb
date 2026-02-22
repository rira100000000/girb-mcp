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

      CLEANUP_DEADLINE = 3

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
            # For connect sessions: best-effort cleanup (restore SIGINT,
            # delete BPs, continue) bounded by a hard deadline.
            # Skip entirely if process is not paused — sending commands to
            # a running process violates the debug protocol.
            best_effort_cleanup(client) if client.paused
          end

          # Disconnect the session (closes socket, cleans up temp files)
          manager.disconnect(session_id)

          text = "Disconnected from session."
          text += " Process #{pid} terminated." if process_killed
          text += "\n\nUse 'run_script' or 'connect' to start a new debug session."

          MCP::Tool::Response.new([{ type: "text", text: text }])
        end

        private

        def best_effort_cleanup(client)
          deadline = Time.now + CLEANUP_DEADLINE

          # Restore original SIGINT handler
          remaining = deadline - Time.now
          if remaining > 0
            begin
              client.send_command(
                "p $_girb_orig_int ? (trap('INT',$_girb_orig_int);$_girb_orig_int=nil;:ok) : nil",
                timeout: [remaining, 2].min,
              )
            rescue GirbMcp::Error
              # Best-effort
            end
          end

          # Delete all breakpoints so process doesn't pause again
          remaining = deadline - Time.now
          if remaining > 0
            begin
              bp_output = client.send_command("info breakpoints", timeout: [remaining, 2].min)
              unless bp_output.strip.empty?
                bp_output.each_line do |line|
                  remaining = deadline - Time.now
                  break if remaining <= 0

                  if (match = line.match(/#(\d+)/))
                    client.send_command("delete #{match[1]}", timeout: [remaining, 2].min) rescue nil
                  end
                end
              end
            rescue GirbMcp::Error
              # Best-effort
            end
          end

          client.send_command_no_wait("c")
        end
      end
    end
  end
end
