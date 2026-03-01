# frozen_string_literal: true

module GirbMcp
  # Shared cleanup logic for graceful disconnect.
  # Used by Disconnect tool and SessionManager reaper to avoid ~100 lines of duplication.
  # Performs: stdout restore, breakpoint deletion, SIGINT handler restore,
  # process resume, and stale pause defense.
  module ClientCleanup
    # Perform best-effort cleanup and resume a paused debug client.
    # The client MUST be paused before calling this method.
    # @param client [DebugClient] the client to clean up
    # @param deadline [Time] hard deadline for all cleanup operations
    # @param max_stale_retries [Integer] max retries for stale pause defense
    def self.cleanup_and_resume(client, deadline:, max_stale_retries: 2)
      # Restore $stdout if evaluate_code left it redirected (its ensure block
      # fails when send_command timeout sets @paused=false).
      remaining = deadline - Time.now
      if remaining > 0
        begin
          client.send_command(
            '$stdout = STDOUT if $stdout != STDOUT',
            timeout: [remaining, 1].min,
          )
        rescue GirbMcp::Error
          # Best-effort
        end
      end

      # Delete all breakpoints FIRST — this is the most critical step.
      # If breakpoints remain and the process resumes without a client,
      # it will hit a breakpoint and become stuck with no way to continue.
      delete_all_breakpoints(client, deadline)

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

      # Stale pause defense: after 'c' → ensure_paused, the process might
      # have been re-paused by a stale `pause` message left in the debug
      # gem's socket buffer. If still paused, delete remaining BPs and
      # send 'c' again (bounded retries to prevent infinite loop).
      stale_retries = 0
      while client.paused && stale_retries < max_stale_retries
        stale_retries += 1
        remaining = deadline - Time.now
        break if remaining <= 0

        delete_all_breakpoints(client, deadline)

        remaining = deadline - Time.now
        break if remaining <= 0

        client.send_command_no_wait("c", force: true)
        client.ensure_paused(timeout: [remaining, 1].min)
      end
    end

    # Delete all breakpoints from the debug session.
    # @param client [DebugClient] the client
    # @param deadline [Time] hard deadline
    def self.delete_all_breakpoints(client, deadline)
      remaining = deadline - Time.now
      return if remaining <= 0

      bp_output = client.send_command("info breakpoints", timeout: [remaining, 2].min)
      return if bp_output.strip.empty?

      bp_output.each_line do |line|
        remaining = deadline - Time.now
        break if remaining <= 0

        if (match = line.match(/#(\d+)/))
          client.send_command("delete #{match[1]}", timeout: [remaining, 2].min) rescue nil
        end
      end
    rescue GirbMcp::Error
      # Best-effort
    end
  end
end
