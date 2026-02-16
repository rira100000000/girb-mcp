# frozen_string_literal: true

module GirbMcp
  class SessionManager
    # Default session timeout: 30 minutes of inactivity
    DEFAULT_TIMEOUT = 30 * 60
    # Reaper interval: check every 60 seconds
    REAPER_INTERVAL = 60

    SessionInfo = Struct.new(:client, :connected_at, :last_activity_at, keyword_init: true)

    def initialize(timeout: DEFAULT_TIMEOUT)
      @sessions = {}
      @default_session_id = nil
      @timeout = timeout
      @mutex = Mutex.new
      @reaper_thread = nil
      @breakpoint_specs = [] # Breakpoint commands to restore across sessions
      start_reaper
    end

    # Connect to a debug session and register it
    def connect(session_id: nil, path: nil, host: nil, port: nil)
      client = DebugClient.new
      result = client.connect(path: path, host: host, port: port)

      now = Time.now
      sid = session_id || "session_#{client.pid}"

      @mutex.synchronize do
        @sessions[sid] = SessionInfo.new(
          client: client,
          connected_at: now,
          last_activity_at: now,
        )
        @default_session_id = sid
      end

      result.merge(session_id: sid)
    end

    # Get the client for a session (also updates last_activity_at)
    def client(session_id = nil)
      @mutex.synchronize do
        sid = session_id || @default_session_id
        raise SessionError, "No active debug session. Use the 'connect' tool first." unless sid

        info = @sessions[sid]
        raise SessionError, "Session '#{sid}' not found. Use 'list_paused_sessions' to see active sessions." unless info
        raise SessionError, "Session '#{sid}' is disconnected. Use 'connect' to reconnect." unless info.client.connected?

        info.last_activity_at = Time.now
        info.client
      end
    end

    # Disconnect a session
    def disconnect(session_id = nil)
      @mutex.synchronize do
        sid = session_id || @default_session_id
        return unless sid

        info = @sessions.delete(sid)
        info&.client&.disconnect

        if @default_session_id == sid
          @default_session_id = @sessions.keys.first
        end
      end
    end

    # Disconnect all sessions and stop reaper
    # Note: safe to call from trap context (does not use mutex)
    def disconnect_all
      stop_reaper

      # Avoid mutex here so this can be called from signal trap context.
      # At shutdown, thread safety is not a concern.
      has_connect_sessions = false
      @sessions.each_value do |info|
        # Resume connect sessions (no wait_thread) so the target process
        # doesn't stay stuck at the debugger prompt after we disconnect.
        unless info.client.wait_thread
          socket = info.client.instance_variable_get(:@socket)
          next unless socket && !socket.closed?

          pid = info.client.pid
          # Delete breakpoints #0-#9 (best-effort) then continue.
          # In signal trap context we can't use send_command, so write raw
          # protocol messages directly to the socket.
          (0..9).reverse_each do |n|
            socket.write("command #{pid} 500 delete #{n}\n".b) rescue nil
          end
          socket.write("command #{pid} 500 c\n".b) rescue nil
          socket.flush rescue nil
          has_connect_sessions = true
        end
      rescue StandardError
        # ignore
      end
      # One sleep for all sessions — give debug gems time to process continue
      sleep 0.3 if has_connect_sessions
      @sessions.each_value do |info|
        info.client.disconnect rescue nil
      end
      @sessions.clear
      @default_session_id = nil
    end

    # Record a breakpoint spec for preservation across sessions.
    # Spec is the debugger command string (e.g., "break file.rb:42", "catch NoMethodError").
    def record_breakpoint(spec)
      @mutex.synchronize do
        @breakpoint_specs << spec unless @breakpoint_specs.include?(spec)
      end
    end

    # Clear all recorded breakpoint specs.
    def clear_breakpoint_specs
      @mutex.synchronize { @breakpoint_specs.clear }
    end

    # Remove breakpoint specs that match a pattern (substring match).
    def remove_breakpoint_specs_matching(pattern)
      @mutex.synchronize do
        @breakpoint_specs.reject! { |s| s.include?(pattern) }
      end
    end

    # Restore recorded breakpoints on a client. Returns an array of results.
    def restore_breakpoints(client)
      specs = @mutex.synchronize { @breakpoint_specs.dup }
      return [] if specs.empty?

      specs.filter_map do |spec|
        output = client.send_command(spec)
        { spec: spec, output: output.lines.first&.strip }
      rescue GirbMcp::Error => e
        { spec: spec, error: e.message }
      end
    end

    # Clean up sessions whose target process has died or whose socket has disconnected.
    # Returns an array of cleaned-up session info hashes.
    def cleanup_dead_sessions
      cleaned = []

      @mutex.synchronize do
        dead_sids = @sessions.each_with_object([]) do |(sid, info), acc|
          unless process_alive?(info.client.pid) && info.client.connected?
            acc << sid
          end
        end

        dead_sids.each do |sid|
          info = @sessions.delete(sid)
          cleaned << { session_id: sid, pid: info.client.pid }
          info.client.disconnect
        end

        if dead_sids.include?(@default_session_id)
          @default_session_id = @sessions.keys.first
        end
      end

      cleaned
    end

    # List active sessions with timing info
    def active_sessions
      @mutex.synchronize do
        @sessions.map do |sid, info|
          {
            session_id: sid,
            pid: info.client.pid,
            connected: info.client.connected?,
            connected_at: info.connected_at,
            last_activity_at: info.last_activity_at,
            idle_seconds: (Time.now - info.last_activity_at).to_i,
          }
        end
      end
    end

    private

    def start_reaper
      @reaper_thread = Thread.new do
        loop do
          sleep REAPER_INTERVAL
          reap_stale_sessions
        end
      rescue StandardError
        # Reaper should not crash the server
        retry
      end
      @reaper_thread.name = "girb-mcp-reaper"
    end

    def stop_reaper
      @reaper_thread&.kill
      @reaper_thread = nil
    end

    def reap_stale_sessions
      now = Time.now
      stale_sids = []

      @mutex.synchronize do
        @sessions.each do |sid, info|
          # Remove sessions whose target process has died
          unless process_alive?(info.client.pid)
            stale_sids << sid
            next
          end

          # Remove sessions that lost their socket connection
          unless info.client.connected?
            stale_sids << sid
            next
          end

          # Remove sessions that have been idle too long
          if (now - info.last_activity_at) > @timeout
            stale_sids << sid
          end
        end

        # Resume target processes before disconnecting, so they don't
        # stay stuck at the debugger prompt after we disconnect.
        stale_sids.each do |sid|
          info = @sessions[sid]
          next unless info

          resume_before_disconnect(info)
          @sessions.delete(sid)
          info.client.disconnect rescue nil
        end

        if stale_sids.include?(@default_session_id)
          @default_session_id = @sessions.keys.first
        end
      end
    end

    # Delete all breakpoints and send continue before disconnecting so the
    # target process resumes cleanly. Uses send_command (reaper runs in a
    # normal thread context where blocking is acceptable).
    def resume_before_disconnect(info)
      return unless info.client.connected?
      return if info.client.wait_thread # run_script sessions don't need resume

      # Delete all breakpoints so the process doesn't immediately pause again
      begin
        bp_output = info.client.send_command("info breakpoints", timeout: 3)
        unless bp_output.strip.empty?
          bp_output.each_line do |line|
            if (match = line.match(/#(\d+)/))
              info.client.send_command("delete #{match[1]}", timeout: 3) rescue nil
            end
          end
        end
      rescue GirbMcp::Error
        # Best-effort
      end

      info.client.send_command_no_wait("c")
    rescue StandardError
      # Best-effort: don't let resume failure prevent cleanup
    end

    def process_alive?(pid)
      return false unless pid

      Process.kill(0, pid.to_i)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end
  end
end
