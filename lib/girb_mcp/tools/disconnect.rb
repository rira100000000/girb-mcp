# frozen_string_literal: true

require "mcp"

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
            manager.disconnect(session_id)

            text = "Force-disconnected from session (cleanup skipped)."
            text += "\n\nWARNING: Breakpoints were NOT removed and the process was NOT resumed. " \
                    "The target process may be left in a paused state."
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
            # If not paused, try SIGINT to re-pause before cleanup.
            unless client.paused
              begin
                client.interrupt_and_wait(timeout: 3)
              rescue GirbMcp::Error
                # Best-effort — if interrupt fails, skip cleanup
              end
            end
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

          # Restore $stdout if evaluate_code left it redirected (its ensure block
          # fails when send_command timeout sets @paused=false).
          remaining = deadline - Time.now
          if remaining > 0
            begin
              client.send_command(
                '$stdout = $__girb_old if defined?($__girb_old) && $__girb_old',
                timeout: [remaining, 1].min,
              )
            rescue GirbMcp::Error
              # Best-effort
            end
          end

          # Delete all breakpoints FIRST — this is the most critical step.
          # If breakpoints remain and the process resumes without a client,
          # it will hit a breakpoint and become stuck with no way to continue.
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

          # Resume the process. If a cleanup command timed out (setting
          # @paused=false even though the process is actually still paused),
          # use force: true to bypass the @paused check.
          client.send_command_no_wait("c", force: true)

          # Wait for the debug gem to settle after 'c'. After SIGINT recovery,
          # the main thread needs to finish the interrupted eval and re-enter
          # the command loop (sending `input PID`). If we close the socket
          # before this completes, the debug gem's cleanup_reader closes @q_msg
          # while the main thread is still pushing results, leaving it stuck
          # on a futex. Draining here gives the debug gem time to settle.
          client.ensure_paused(timeout: 2)
        end
      end
    end
  end
end
