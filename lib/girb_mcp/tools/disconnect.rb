# frozen_string_literal: true

require "mcp"
require_relative "../client_cleanup"

module GirbMcp
  module Tools
    class Disconnect < MCP::Tool
      description "[Control] Disconnect from the current debug session and clean up. " \
                  "For sessions started with 'run_script', the target process is also terminated. " \
                  "Use this when you are done debugging or want to restart with a clean state. " \
                  "After disconnecting, use 'run_script' or 'connect' to start a new session."

      annotations(
        title: "Disconnect Session",
        read_only_hint: false,
        destructive_hint: false,
        open_world_hint: false,
      )

      input_schema(
        properties: {
          session_id: {
            type: "string",
            description: "Debug session ID to disconnect (uses default session if omitted)",
          },
          force: {
            type: "boolean",
            description: "If true, skip all cleanup (breakpoint deletion, process resume) and " \
                         "immediately close the socket. Use when the process is unresponsive " \
                         "and normal disconnect times out. Default: false.",
          },
        },
      )

      CLEANUP_DEADLINE = 3

      class << self
        def call(session_id: nil, force: nil, server_context:)
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

          if force
            # Force disconnect: skip all cleanup, just close the socket immediately.
            # Use when the process is unresponsive and normal disconnect hangs.

            # For run_script sessions, still attempt to kill the spawned process
            # (Process.kill is non-blocking, so it won't hang even if the process is stuck).
            process_killed = false
            if has_process && pid
              begin
                Process.kill("TERM", pid.to_i)
                process_killed = true
              rescue Errno::ESRCH, Errno::EPERM
                # Process already exited
              end
            end

            manager.disconnect(session_id)

            text = "Force-disconnected from session (cleanup skipped)."
            text += " Process #{pid} terminated." if process_killed
            if has_process && !process_killed
              text += "\n\nWARNING: The spawned process (PID #{pid}) was NOT terminated and may still be running."
            else
              text += "\n\nWARNING: Breakpoints were NOT removed and the process was NOT resumed. " \
                      "The target process may be left in a paused state."
            end
            text += "\n\nUse 'run_script' or 'connect' to start a new debug session."
            return MCP::Tool::Response.new([{ type: "text", text: text }])
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
            # If not paused, try to re-pause before cleanup.
            unless client.paused
              # 1. Try repause() first — works for both remote (TCP/Docker) and local
              begin
                client.repause(timeout: 3)
              rescue GirbMcp::Error
                # Best-effort
              end

              # 2. Fall back to interrupt_and_wait (local SIGINT only)
              unless client.paused
                begin
                  client.interrupt_and_wait(timeout: 3)
                rescue GirbMcp::Error
                  # Best-effort
                end
              end

              # 3. For remote connections, try HTTP wake + check_paused
              #    (repause already sent the pause message at step 1 — avoid
              #    sending more to prevent stale messages after disconnect)
              unless client.paused
                if client.remote
                  if client.listen_ports&.any?
                    begin
                      client.wake_io_blocked_process(client.listen_ports.first)
                      sleep DebugClient::HTTP_WAKE_SETTLE_TIME
                      client.check_paused(timeout: 5)
                    rescue GirbMcp::Error
                      # Best-effort
                    end
                  else
                    begin
                      client.check_paused(timeout: 5)
                    rescue GirbMcp::Error
                      # Best-effort
                    end
                  end
                end
              end
            end

            if client.paused
              best_effort_cleanup(client)
            else
              # Both repause and interrupt failed — best-effort resume to prevent stuck process
              begin
                client.send_command_no_wait("c", force: true)
              rescue StandardError
                # Best-effort
              end
              force_warning = "Could not re-pause the process for cleanup. " \
                              "Breakpoints may remain. A resume command was sent to prevent the process from getting stuck."
            end
          end

          # Disconnect the session (closes socket, cleans up temp files)
          manager.disconnect(session_id)

          text = "Disconnected from session."
          text += " Process #{pid} terminated." if process_killed
          text += "\n\nWARNING: #{force_warning}" if force_warning
          text += "\n\nUse 'run_script' or 'connect' to start a new debug session."

          MCP::Tool::Response.new([{ type: "text", text: text }])
        end

        private

        def best_effort_cleanup(client)
          ClientCleanup.cleanup_and_resume(client, deadline: Time.now + CLEANUP_DEADLINE)
        end
      end
    end
  end
end
