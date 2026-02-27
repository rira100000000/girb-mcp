# frozen_string_literal: true

require "socket"
require "io/wait"
require "set"
require "net/http"
require "uri"

module GirbMcp
  class DebugClient
    DEFAULT_WIDTH = 500
    DEFAULT_TIMEOUT = 15
    CONTINUE_TIMEOUT = 30
    DISCONNECT_SOCKET_TIMEOUT = 2

    # ANSI escape code pattern
    ANSI_ESCAPE = /\e\[[0-9;]*m/

    attr_reader :pid, :connected, :paused, :trap_context, :remote, :port
    attr_accessor :stderr_file, :stdout_file, :wait_thread, :script_file, :script_args, :pending_http,
      :listen_ports, :escape_target

    def initialize
      @socket = nil
      @pid = nil
      @connected = false
      @paused = false
      @trap_context = nil
      @remote = false # True for TCP connections (e.g., Docker) where Process.kill won't work
      @port = nil
      @width = DEFAULT_WIDTH
      @mutex = Mutex.new
      @one_shot_breakpoints = Set.new
      @listen_ports = []
      @escape_target = nil
    end

    def connected?
      @connected && @socket && !@socket.closed?
    end

    # Connect to a debug session via Unix domain socket or TCP.
    # Accepts an optional block (&on_initial_timeout) that is called when the
    # initial read_until_input times out. This allows the caller to wake an
    # IO-blocked process (e.g., by sending an HTTP request) so that the debug
    # gem's pending pause (set by the SIGURG from greeting) can fire.
    # If the block is given and the initial read times out, the block is called
    # and read_until_input is retried once with a 10s timeout.
    def connect(path: nil, host: nil, port: nil, connect_timeout: nil, &on_initial_timeout)
      disconnect if connected?

      if path
        @socket = Socket.unix(path)
        @remote = false
      elsif port
        @socket = Socket.tcp(host || "localhost", port.to_i)
        @remote = true
        @port = port.to_i
      else
        path = discover_socket
        @socket = Socket.unix(path)
        @remote = false
      end

      # The debug gem protocol: client sends greeting first, then reads server output
      send_greeting
      initial_output = begin
        read_until_input(timeout: connect_timeout || DEFAULT_TIMEOUT)
      rescue TimeoutError
        raise unless on_initial_timeout
        on_initial_timeout.call
        read_until_input(timeout: 10)
      end
      @connected = true
      @paused = true

      { success: true, pid: @pid, output: initial_output }
    rescue Errno::ECONNREFUSED => e
      raise ConnectionError, "Connection refused: #{e.message}. " \
                             "Ensure the debug process is running with 'rdbg --open'."
    rescue Errno::ENOENT => e
      raise ConnectionError, "Socket not found: #{e.message}. " \
                             "The debug process may have exited. Use 'list_debug_sessions' to check."
    rescue TimeoutError
      disconnect
      raise ConnectionError, "Connection timed out: the debug process did not respond.\n" \
                             "Possible causes:\n" \
                             "  - Another debugger client is already connected " \
                             "(only one client allowed at a time)\n" \
                             "  - A previous debugger client disconnected uncleanly, " \
                             "leaving the session stuck\n" \
                             "  - The target process is blocked and cannot respond " \
                             "to the debug interrupt\n" \
                             "To resolve:\n" \
                             "  - Close other debugger clients " \
                             "(e.g., IDE debugger, other terminal sessions)\n" \
                             "  - Restart the target process with 'rdbg --open'"
    rescue GirbMcp::Error
      raise
    rescue StandardError => e
      disconnect
      raise ConnectionError, "Connection failed: #{e.class}: #{e.message}"
    end

    def disconnect
      force_close_socket
      @socket = nil
      @pid = nil
      @connected = false
      @paused = false
      @trap_context = nil
      @port = nil
      @pending_http = nil
      @listen_ports = []
      @escape_target = nil
      cleanup_captured_files
    end

    # Read captured stdout output (available for processes launched via run_script)
    # Returns the stdout content string, or nil
    def read_stdout_output
      read_captured_file(@stdout_file)
    end

    # Read captured stderr output (available for processes launched via run_script)
    # Returns the stderr content string, or nil
    def read_stderr_output
      read_captured_file(@stderr_file)
    end

    # Send a debugger command and return the output.
    def send_command(command, timeout: DEFAULT_TIMEOUT)
      raise SessionError, "Not connected to a debug session. Use 'connect' to establish a connection." unless connected?

      @mutex.synchronize do
        debug_log("send_command: paused=#{@paused} cmd=#{command[0, 60]}")

        # Drain stale data from previous operations (e.g., responses from
        # timed-out commands, late breakpoint `input PID` after continue timeout).
        # This prevents protocol desync where send_command reads a stale response
        # instead of the response to the command being sent.
        drain_stale_data

        unless @paused
          raise SessionError, "Process is not paused. Cannot send debug commands while the process is running. " \
                              "Use 'trigger_request' to send an HTTP request (which auto-resumes), " \
                              "or 'disconnect' and reconnect."
        end

        # Encode as binary to avoid Encoding::CompatibilityError when the
        # command contains non-ASCII characters (e.g., Japanese) and the
        # socket uses ASCII-8BIT encoding.
        msg = "command #{@pid} #{@width} #{command}\n"
        @socket.write(msg.b)
        @socket.flush
        debug_log("send_command: written OK, reading response...")
        output = read_until_input(timeout: timeout)
        debug_log("send_command: got response (#{output.length} bytes)")
        @paused = true
        output
      end
    rescue TimeoutError
      # The debug gem is still processing the command — it hasn't sent
      # `input PID` back. Mark as not paused so subsequent tool calls
      # trigger auto_repause! (SIGURG/SIGINT) instead of sending another
      # command into the unresponsive session.
      @paused = false
      raise
    rescue Errno::EPIPE, Errno::ECONNRESET, IOError => e
      @connected = false
      @paused = false
      raise ConnectionError, "Connection lost while executing '#{command}': #{e.message}. " \
                             "The debug process may have exited. Use 'connect' to reconnect."
    end

    # Send a command and wait briefly for the debug gem to read it, but don't
    # wait for a full response (which may never come, e.g., after `c` with no
    # breakpoint). Used when resuming a process before disconnecting.
    #
    # When force: true, bypasses the @paused check. Use ONLY during cleanup/disconnect
    # when a prior send_command timeout set @paused=false but the process is
    # actually still paused in the debugger.
    def send_command_no_wait(command, force: false)
      return unless connected?
      return unless force || @paused # Sending command while running crashes the reader thread

      @mutex.synchronize do
        msg = "command #{@pid} #{@width} #{command}\n"
        @socket.write(msg.b)
        @socket.flush
        @paused = false
      end
      # Give the debug gem time to read the command from the socket buffer
      # and begin processing it before the socket is closed.
      sleep 0.3
    rescue Errno::EPIPE, Errno::ECONNRESET, IOError
      # Socket already closed, ignore
    end

    # Send continue and wait for the next breakpoint.
    # Uses continue_and_wait (IO.select-based) instead of send_command to avoid
    # protocol desync: send_command sets @paused=true on timeout even when no
    # input prompt was received, causing subsequent commands to read stale responses.
    def send_continue(timeout: CONTINUE_TIMEOUT, &interrupt_check)
      result = continue_and_wait(timeout: timeout, &interrupt_check)
      case result[:type]
      when :breakpoint
        result[:output]
      when :timeout, :timeout_with_output
        raise TimeoutError, "Timeout after #{timeout}s waiting for breakpoint."
      when :interrupted
        result[:output]
      end
    end

    # Check if there is a current exception in scope ($!)
    # Returns "ExceptionClass: message" string, or nil if no exception
    def check_current_exception
      # Use a single expression to get "ClassName: message" format when $! is set.
      # The debug gem prefixes output with "=> ", which we strip.
      result = send_command('p(($!) ? "#{$!.class}: #{$!.message}" : nil)')
      cleaned = result.strip.sub(/\A=> /, "")
      return nil if cleaned == "nil" || cleaned.empty?

      # Remove surrounding quotes from string output (e.g., "NoMethodError: ..." -> NoMethodError: ...)
      cleaned = cleaned[1..-2] if cleaned.start_with?('"') && cleaned.end_with?('"')
      cleaned.empty? ? nil : cleaned
    rescue GirbMcp::Error
      nil
    end

    # Check if the spawned process has exited.
    # Waits briefly to allow the process to finish cleanup.
    # Only meaningful for run_script sessions (wait_thread is nil for connect sessions).
    def process_finished?(timeout: 1)
      return false unless wait_thread

      wait_thread.join(timeout)
      !wait_thread.alive?
    end

    # Find the most recently raised exception of a given class via ObjectSpace.
    # Used as a fallback at catch breakpoints where $! is not yet set
    # (the :raise TracePoint fires before $! is assigned).
    # Returns "ExceptionClass: message" string, or nil if not found.
    def find_raised_exception(exception_class_name)
      result = send_command(
        "p(begin; klass = Object.const_get(#{exception_class_name.inspect}); " \
        "e = ObjectSpace.each_object(klass).max_by(&:object_id); " \
        'e ? "#{e.class}: #{e.message}" : nil; rescue; nil; end)',
      )
      cleaned = result.strip.sub(/\A=> /, "")
      return nil if cleaned == "nil" || cleaned.empty?

      cleaned = cleaned[1..-2] if cleaned.start_with?('"') && cleaned.end_with?('"')
      cleaned.empty? ? nil : cleaned
    rescue GirbMcp::Error
      nil
    end

    # Check if the debugger is currently in a signal trap context.
    # This is common when connecting to Puma/Rails processes via SIGURG.
    # In trap context, thread operations (Mutex lock, DB pools, autoloading) fail
    # with ThreadError: "can't be called from trap context".
    # Note: Mutex.new alone succeeds in trap context (Ruby 3.3+) — it's just object
    # allocation. Mutex#lock is needed to actually test for trap context restrictions.
    def in_trap_context?
      result = send_command("p begin; Mutex.new.lock; 'normal'; rescue ThreadError; 'trap'; end")
      in_trap = result.strip.sub(/\A=> /, "").include?("trap")
      @trap_context = in_trap
      in_trap
    rescue GirbMcp::Error
      false
    end

    # Attempt to escape from signal trap context by stepping to the next line.
    # The 'next' command causes the debugger to return from the signal handler
    # and pause at the next Ruby line in normal context.
    # Uses a short timeout (3s) because if the process is blocked in IO.select
    # (common with Puma), 'next' will never complete regardless of wait time.
    # Returns the step output on success, nil on failure.
    def escape_trap_context!(timeout: 3)
      return nil unless in_trap_context?

      output = send_command("next", timeout: timeout)

      if in_trap_context?
        nil # Still in trap context (step didn't escape)
      else
        @trap_context = false
        output
      end
    rescue GirbMcp::Error
      nil
    end

    # Try to determine if the process is paused by draining any pending
    # output from the socket. Returns the pending output string if the
    # process is paused (input prompt found), or nil if still running.
    # Does NOT send any commands - safe to call at any time.
    def ensure_paused(timeout: 2)
      return "" if @paused
      return nil unless connected?

      @mutex.synchronize do
        return "" if @paused

        pending_output = []
        deadline = Time.now + timeout

        while Time.now < deadline
          remaining = [deadline - Time.now, 0.1].min
          break if remaining <= 0

          ready = @socket.wait_readable(remaining)
          next unless ready

          line = @socket.gets
          break unless line

          line = line.chomp.force_encoding(Encoding::UTF_8)
          line = line.scrub unless line.valid_encoding?

          case line
          when /\Aout (.*)/
            pending_output << strip_ansi($1)
          when /\Ainput (\d+)/
            @pid = $1
            @paused = true
            return pending_output.join("\n")
          when /\Aask (\d+) (.*)/
            @socket.write("answer #{$1} y\n".b)
            @socket.flush
          when /\Aquit/
            @connected = false
            @paused = false
            return nil
          end
        end

        nil # Still not paused (no input prompt received)
      end
    rescue Errno::EPIPE, Errno::ECONNRESET, IOError
      @connected = false
      @paused = false
      nil
    end

    # Interrupt a running process via SIGINT and wait for it to pause.
    # SIGINT can break through C-level blocking IO (unlike SIGURG used by repause).
    # Returns "" if the process is now paused, nil if the process couldn't be found
    # or the interrupt didn't work.
    def interrupt_and_wait(timeout: 5)
      return nil unless @pid
      return "" if @paused

      if @remote
        # For remote connections, SIGINT can't be sent directly.
        # The `pause` protocol message (sent by repause) is the best we can do.
        # Return nil to indicate we can't interrupt.
        return nil
      end

      Process.kill("INT", @pid.to_i)
      ensure_paused(timeout: timeout)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    # Automatically re-pause the process if it's running.
    # Returns false if already paused, true if repause was performed.
    # Raises SessionError if the process cannot be re-paused (e.g., blocked on I/O).
    def auto_repause!
      return false if @paused

      result = repause(timeout: 3)
      if result.nil?
        if @remote
          # Remote: interrupt_and_wait always returns nil (SIGINT can't reach the
          # target process in a different PID namespace). Retry repause instead —
          # the first `pause` message may still be in the TCP buffer and the second
          # drain_socket_buffer call inside repause can pick up the response.
          result = repause(timeout: 5)
        else
          # Local: SIGINT can interrupt IO.select and similar C-level blocking calls.
          result = interrupt_and_wait(timeout: 5)
        end

        if result.nil?
          raise SessionError, "Process is not paused and could not be interrupted. " \
                              "The process may have exited or be in an unrecoverable state. " \
                              "Use 'disconnect' and 'connect' to re-attach."
        end
      end

      # After repause via SIGURG, the process is in trap context.
      # Auto-escape if we have cached escape target and listen ports.
      if @trap_context && @listen_ports&.any? && @escape_target
        attempt_trap_escape!
      end

      true
    end

    # Re-pause a running process by sending SIGURG directly.
    #
    # First drains any buffered socket data (in case a breakpoint was hit but the
    # `input PID` wasn't consumed due to a timeout). If not already paused, sends
    # SIGURG to the target process to trigger the debug gem's pause handler.
    #
    # Uses Process.kill("URG") instead of the `pause` protocol message to avoid
    # leaving stale messages in the server's socket read buffer. When `pause` is
    # written to the socket and the reader thread is blocked (e.g., executing a
    # long-running eval), the message sits unread. After SIGINT recovery, the
    # reader thread eventually reads the stale `pause` and fires SIGURG at an
    # unexpected time — typically after disconnect, when `c` resumes the process.
    # This re-pauses the process with no client connected, leaving the session
    # thread stuck on process_group.sync and blocking future connections.
    #
    # Returns "" on success (process is paused), nil on timeout/failure.
    def repause(timeout: 3)
      return "" if @paused
      return nil unless connected?

      @mutex.synchronize do
        return "" if @paused

        # Step 1: Drain buffered data — a breakpoint may have been hit but
        # the `input PID` wasn't consumed (e.g., after continue_and_wait timeout).
        drain_socket_buffer

        return "" if @paused

        # Step 2: Pause the running process.
        # For local processes, send SIGURG directly — this avoids leaving stale
        # data in the server's socket read buffer (unlike the `pause` protocol message).
        # For remote/TCP connections (e.g., Docker), Process.kill won't reach the
        # target process (PID is in a different namespace), so use the `pause`
        # protocol message which the debug gem server sends as SIGURG to itself.
        if @remote
          @socket.write("pause #{@pid}\n".b)
          @socket.flush
        else
          Process.kill("URG", @pid.to_i)
        end

        # Step 3: Wait for `input PID` prompt
        result = wait_for_pause(timeout)

        # SIGURG puts the process in signal trap context. Mark it so callers
        # can adapt (e.g., avoid `require` or Mutex operations that hang in
        # trap context).
        @trap_context = true if result

        result
      end
    rescue Errno::ESRCH, Errno::EPERM
      # Process not found or no permission — can't repause
      nil
    rescue Errno::EPIPE, Errno::ECONNRESET, IOError => e
      @connected = false
      @paused = false
      raise ConnectionError, "Connection lost: #{e.message}"
    end

    # Resume the paused process and wait for the next breakpoint hit.
    # Supports an interrupt check block that is called every 0.5s.
    # If the block returns true, the wait is interrupted and :interrupted is returned.
    # Returns a hash: { type: :breakpoint/:interrupted/:timeout, output: String }
    def continue_and_wait(timeout: CONTINUE_TIMEOUT, &interrupt_check)
      raise SessionError, "Not connected to a debug session." unless connected?

      @mutex.synchronize do
        msg = "command #{@pid} #{@width} c\n"
        @socket.write(msg.b)
        @socket.flush
        @paused = false

        read_until_input_interruptible(timeout: timeout, interrupt_check: interrupt_check)
      end
    rescue Errno::EPIPE, Errno::ECONNRESET, IOError => e
      @connected = false
      @paused = false
      raise ConnectionError, "Connection lost: #{e.message}"
    end

    # Wait for the process to pause (breakpoint hit) without sending any command.
    # Use when the process is already running after a previous continue.
    # Returns a hash: { type: :breakpoint/:interrupted/:timeout, output: String }
    def wait_for_breakpoint(timeout: CONTINUE_TIMEOUT, &interrupt_check)
      raise SessionError, "Not connected to a debug session." unless connected?

      @mutex.synchronize do
        read_until_input_interruptible(timeout: timeout, interrupt_check: interrupt_check)
      end
    rescue Errno::EPIPE, Errno::ECONNRESET, IOError => e
      @connected = false
      @paused = false
      raise ConnectionError, "Connection lost: #{e.message}"
    end

    # Register a breakpoint number as one-shot (auto-remove after first hit)
    def register_one_shot(bp_number)
      @one_shot_breakpoints.add(bp_number)
    end

    # Check if a one-shot breakpoint was hit and auto-remove it.
    # Call this after execution commands (continue, next, step).
    # Returns the deleted breakpoint number, or nil.
    def cleanup_one_shot_breakpoints(output)
      return nil unless @one_shot_breakpoints.any?
      return nil unless output

      # Debug gem output when hitting a breakpoint: "Stop by #3  BP - Line  ..."
      match = output.match(/Stop by #(\d+)/)
      return nil unless match

      bp_num = match[1].to_i
      return nil unless @one_shot_breakpoints.delete?(bp_num)

      send_command("delete #{bp_num}")
      bp_num
    rescue GirbMcp::Error
      # Best-effort cleanup
      nil
    end

    # List available debug sessions.
    # Filters by: socket file exists and socket is connectable (liveness probe).
    # The connectable check is the sole authority — if the socket accepts
    # connections, a debug process is listening regardless of whether the
    # PID in the filename still matches (e.g. daemonized Rails servers fork
    # after creating the socket, so the original PID exits).
    def self.list_sessions
      dir = socket_dir
      return [] unless dir && Dir.exist?(dir)

      Dir.glob(File.join(dir, "rdbg*")).select do |path|
        File.socket?(path)
      end.filter_map do |path|
        pid = extract_pid(path)
        next unless pid && socket_connectable?(path)

        { path: path, pid: pid, name: extract_session_name(path) }
      end
    end

    # Get socket directory for current user
    def self.socket_dir
      if (dir = ENV["RUBY_DEBUG_SOCK_DIR"])
        dir
      elsif (dir = ENV["XDG_RUNTIME_DIR"])
        dir
      else
        tmpdir = Dir.tmpdir
        uid = Process.uid
        dir = File.join(tmpdir, "rdbg-#{uid}")
        dir if Dir.exist?(dir)
      end
    end

    private

    # Attempt to escape trap context after repause by setting a breakpoint
    # on the cached escape target (typically ActionController::Metal#dispatch)
    # and sending an HTTP GET to trigger it.
    # On success, sets @trap_context = false.
    # On failure, tries to re-pause and leaves @trap_context = true (same as before).
    def attempt_trap_escape!
      file = @escape_target[:file]
      line = @escape_target[:line]
      path = @escape_target[:path] || "/"
      port = @listen_ports.first

      # Set a temporary breakpoint
      bp_output = send_command("break #{file}:#{line}")
      bp_match = bp_output.match(/#(\d+)/)
      return unless bp_match

      bp_number = bp_match[1].to_i

      # Send GET request in background thread and wait for breakpoint
      url = "http://127.0.0.1:#{port}#{path}"
      http_done = false
      http_thread = Thread.new do
        uri = URI.parse(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.open_timeout = 5
        http.read_timeout = 10
        http.get(uri.request_uri)
      rescue StandardError
        # Ignore HTTP errors — we only care about triggering the breakpoint
      ensure
        http_done = true
      end

      result = continue_and_wait(timeout: 10) { http_done }
      http_thread.join(1)

      if result[:type] == :breakpoint
        @trap_context = false
      else
        # Escape failed — try to re-pause so subsequent commands work
        ensure_paused(timeout: 3)
      end

      # Clean up the temporary breakpoint (best-effort)
      begin
        send_command("delete #{bp_number}")
      rescue GirbMcp::Error
        # Best-effort cleanup
      end
    rescue GirbMcp::Error
      # Failed to escape — stay in trap context (same behavior as before)
    end

    def force_close_socket
      return unless @socket && !@socket.closed?

      socket = @socket
      closer = Thread.new do
        socket.shutdown(:RDWR) rescue nil
        socket.close rescue nil
      end
      unless closer.join(DISCONNECT_SOCKET_TIMEOUT)
        closer.kill
      end
    end

    def send_greeting
      debug_version = resolve_debug_version
      cookie = ENV["RUBY_DEBUG_COOKIE"] || "-"
      greeting = "version: #{debug_version} width: #{@width} cookie: #{cookie} nonstop: false\n"
      @socket.write(greeting.b)
      @socket.flush
    end

    def resolve_debug_version
      # Try to load the debug gem version
      return DEBUGGER__::VERSION if defined?(DEBUGGER__::VERSION)

      begin
        require "debug/version"
        return DEBUGGER__::VERSION if defined?(DEBUGGER__::VERSION)
      rescue LoadError
        # ignore
      end

      # Fallback: read from gem spec
      spec = Gem::Specification.find_by_name("debug")
      spec.version.to_s
    rescue StandardError
      "1.0.0"
    end

    # Read protocol messages from the socket until an `input` prompt is received.
    # Uses IO.select for safe, non-interruptible timeout handling (no Timeout.timeout).
    def read_until_input(timeout: DEFAULT_TIMEOUT)
      output_lines = []
      deadline = Time.now + timeout
      debug_log("read_until_input: start timeout=#{timeout}")

      while Time.now < deadline
        remaining = deadline - Time.now
        break if remaining <= 0

        # wait_readable checks Ruby's internal IO buffer first, then falls back
        # to the OS-level check. IO.select only checks the OS-level file descriptor
        # and misses data already buffered by Ruby (e.g., when multiple protocol
        # lines arrive in a single read), causing spurious timeouts.
        ready = @socket.wait_readable(remaining)
        unless ready
          debug_log("read_until_input: wait_readable returned nil (timeout)")
          break
        end

        line = @socket.gets
        unless line
          # EOF - connection closed
          debug_log("read_until_input: EOF!")
          @connected = false
          final = output_lines.join("\n")
          raise ConnectionError.new(
            "Debug session connection closed unexpectedly. The target process may have exited.",
            final_output: final.empty? ? nil : final,
          )
        end

        # Socket reads are ASCII-8BIT but debug gem output contains UTF-8 text
        line = line.chomp.force_encoding(Encoding::UTF_8)
        line = line.scrub unless line.valid_encoding?
        debug_log("read_until_input: line=#{line[0, 80]}")

        case line
        when /\Aout (.*)/
          output_lines << strip_ansi($1)
        when /\Ainput (\d+)/
          @pid = $1
          debug_log("read_until_input: got input prompt, returning")
          return output_lines.join("\n")
        when /\Aask (\d+) (.*)/
          # Auto-answer yes to questions
          @socket.write("answer #{$1} y\n".b)
          @socket.flush
        when /\Aquit/
          @connected = false
          final = output_lines.join("\n")
          raise SessionError.new(
            "Debug session ended. The target process has finished execution.",
            final_output: final.empty? ? nil : final,
          )
        end
      end

      # Timeout — always raise. Returning partial output without `input PID`
      # causes protocol desync: send_command sets @paused=true even though the
      # debug gem hasn't finished processing the command.
      final = output_lines.join("\n")
      debug_log("read_until_input: TIMEOUT lines=#{output_lines.size}")
      raise TimeoutError.new(
        "Timeout after #{timeout}s waiting for debugger response. " \
        "The evaluated code may be blocking or taking too long.\n\n" \
        "Recovery: the session will automatically try to interrupt and recover on the next command. " \
        "If this persists, use 'disconnect' and reconnect.",
        final_output: final.empty? ? nil : final,
      )
    end

    # Non-blocking read that uses IO.select instead of Timeout.timeout.
    # Supports an interrupt check that is polled every 0.5s.
    # Returns a hash: { type: :breakpoint/:interrupted/:timeout/:timeout_with_output, output: String }
    def read_until_input_interruptible(timeout:, interrupt_check: nil)
      output_lines = []
      deadline = Time.now + timeout
      debug_log("read_interruptible: start timeout=#{timeout}")

      while Time.now < deadline
        if interrupt_check&.call
          debug_log("read_interruptible: interrupt_check=true, draining...")
          # Before returning :interrupted, drain any buffered data. A breakpoint
          # may have been hit just before the interrupt — its `input PID` could
          # already be in the socket buffer. Prefer :breakpoint over :interrupted
          # to keep @paused consistent and avoid needing SIGURG-based repause.
          drain_socket_buffer(output_lines)
          if @paused
            debug_log("read_interruptible: drain found breakpoint!")
            @trap_context = false
            return { type: :breakpoint, output: output_lines.join("\n") }
          end
          debug_log("read_interruptible: returning :interrupted")
          return { type: :interrupted, output: output_lines.join("\n") }
        end

        remaining = [deadline - Time.now, 0.0].max
        wait_time = [0.5, remaining].min
        break if wait_time <= 0

        next unless @socket.wait_readable(wait_time)

        line = @socket.gets
        unless line
          @connected = false
          @paused = false
          final = output_lines.join("\n")
          raise ConnectionError.new(
            "Debug session connection closed unexpectedly.",
            final_output: final.empty? ? nil : final,
          )
        end

        line = line.chomp.force_encoding(Encoding::UTF_8)
        line = line.scrub unless line.valid_encoding?

        case line
        when /\Aout (.*)/
          output_lines << strip_ansi($1)
        when /\Ainput (\d+)/
          @pid = $1
          @paused = true
          @trap_context = false # Breakpoint hit implies normal context
          debug_log("read_interruptible: got input prompt → :breakpoint")
          return { type: :breakpoint, output: output_lines.join("\n") }
        when /\Aask (\d+) (.*)/
          @socket.write("answer #{$1} y\n".b)
          @socket.flush
        when /\Aquit/
          @connected = false
          @paused = false
          final = output_lines.join("\n")
          raise SessionError.new(
            "Debug session ended.",
            final_output: final.empty? ? nil : final,
          )
        end
      end

      debug_log("read_interruptible: main loop ended, entering grace period")
      # Timeout — but the breakpoint might have JUST arrived. Do a short grace
      # period to catch `input PID` that was buffered right at the deadline.
      # Without this, the stale `input PID` left in the socket causes protocol
      # desync on subsequent commands.
      grace_deadline = Time.now + 1
      while Time.now < grace_deadline
        remaining = grace_deadline - Time.now
        break if remaining <= 0
        break unless @socket.wait_readable(remaining)

        line = @socket.gets
        break unless line

        line = line.chomp.force_encoding(Encoding::UTF_8)
        line = line.scrub unless line.valid_encoding?

        case line
        when /\Aout (.*)/
          output_lines << strip_ansi($1)
        when /\Ainput (\d+)/
          @pid = $1
          @paused = true
          @trap_context = false
          return { type: :breakpoint, output: output_lines.join("\n") }
        when /\Aask (\d+) (.*)/
          @socket.write("answer #{$1} y\n".b)
          @socket.flush
        when /\Aquit/
          @connected = false
          @paused = false
          final = output_lines.join("\n")
          raise SessionError.new(
            "Debug session ended.",
            final_output: final.empty? ? nil : final,
          )
        end
      end

      meaningful = output_lines.reject { |l| l.strip.empty? }
      output = output_lines.join("\n")
      if meaningful.any?
        { type: :timeout_with_output, output: output }
      else
        { type: :timeout, output: output }
      end
    end

    # Drain ALL stale data from the socket buffer without blocking.
    # Unlike drain_socket_buffer, this does NOT stop at the first `input PID`.
    # It consumes everything available, tracking the LAST `input PID` seen.
    # This is essential for recovering from protocol desync (e.g., when a
    # previous send_command timed out and its response is still in the buffer).
    # Must be called inside @mutex.synchronize.
    def drain_stale_data
      last_input_pid = nil

      while @socket&.wait_readable(0)
        line = @socket.gets
        break unless line

        line = line.chomp.force_encoding(Encoding::UTF_8)
        line = line.scrub unless line.valid_encoding?

        case line
        when /\Ainput (\d+)/
          last_input_pid = $1
        when /\Aask (\d+) (.*)/
          @socket.write("answer #{$1} y\n".b)
          @socket.flush
        when /\Aquit/
          @connected = false
          @paused = false
          return
        end
        # `out` lines are silently discarded (stale data)
      end

      if last_input_pid
        @pid = last_input_pid
        @paused = true
      end
    end

    # Drain all buffered data from the socket without blocking.
    # This catches `input PID` that may have been buffered (e.g., from a
    # breakpoint hit during a continue_and_wait timeout or interrupt).
    # Sets @paused = true if `input PID` is found.
    # Optionally appends drained `out` lines to the provided array.
    def drain_socket_buffer(output_lines = nil)
      while @socket.wait_readable(0)
        line = @socket.gets
        return unless line

        line = line.chomp.force_encoding(Encoding::UTF_8)
        line = line.scrub unless line.valid_encoding?

        case line
        when /\Ainput (\d+)/
          @pid = $1
          @paused = true
          return
        when /\Aout (.*)/
          output_lines << strip_ansi($1) if output_lines
        when /\Aask (\d+) (.*)/
          @socket.write("answer #{$1} y\n".b)
          @socket.flush
        when /\Aquit/
          @connected = false
          @paused = false
          return
        end
      end
    end

    # Wait for `input PID` prompt after sending a `pause` protocol message.
    # Returns "" on success (process paused), nil on timeout.
    def wait_for_pause(timeout)
      deadline = Time.now + timeout

      while Time.now < deadline
        remaining = deadline - Time.now
        break if remaining <= 0

        break unless @socket.wait_readable(remaining)

        line = @socket.gets
        break unless line

        line = line.chomp.force_encoding(Encoding::UTF_8)
        line = line.scrub unless line.valid_encoding?

        case line
        when /\Ainput (\d+)/
          @pid = $1
          @paused = true
          return ""
        when /\Aout/
          # Consume output during pause
        when /\Aask (\d+) (.*)/
          @socket.write("answer #{$1} y\n".b)
          @socket.flush
        when /\Aquit/
          @connected = false
          @paused = false
          return nil
        end
      end

      nil # Timeout
    end

    DEBUG_LOG_PATH = "/tmp/girb_debug.log"

    def debug_log(msg)
      File.open(DEBUG_LOG_PATH, "a") do |f|
        f.puts "[#{Time.now.strftime('%H:%M:%S.%L')}] #{msg}"
      end
    rescue StandardError
      # ignore
    end

    def strip_ansi(str)
      str.gsub(ANSI_ESCAPE, "")
    end

    def read_captured_file(path)
      return nil unless path && File.exist?(path)

      content = File.read(path, encoding: "UTF-8")
      content = content.scrub unless content.valid_encoding?
      content.empty? ? nil : content.strip
    rescue StandardError
      nil
    end

    def cleanup_captured_files
      [@stderr_file, @stdout_file].each do |path|
        File.delete(path) if path && File.exist?(path)
      rescue StandardError
        # ignore
      end
      @stderr_file = nil
      @stdout_file = nil
    end

    def discover_socket
      sessions = self.class.list_sessions
      case sessions.size
      when 0
        raise ConnectionError, "No debug sessions found. Start a Ruby process with: rdbg --open <script.rb>"
      when 1
        sessions.first[:path]
      else
        paths = sessions.map { |s| "  PID #{s[:pid]}: #{s[:path]}" }.join("\n")
        raise ConnectionError, "Multiple debug sessions found. Specify a path:\n#{paths}"
      end
    end

    def self.extract_pid(path)
      basename = File.basename(path)
      if basename =~ /\Ardbg-(\d+)/
        $1.to_i
      end
    end

    def self.extract_session_name(path)
      basename = File.basename(path)
      if basename =~ /\Ardbg-\d+-(.*)/
        $1
      end
    end

    def self.process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    # Quick liveness probe: verify the Unix socket is actually accepting
    # connections. Filters out stale socket files where the PID was reused
    # by a different process that doesn't listen on the debug socket.
    # Does NOT send any protocol data — just connects and immediately closes.
    def self.socket_connectable?(path)
      sock = Socket.unix(path)
      sock.close
      true
    rescue Errno::ECONNREFUSED, Errno::ENOENT, Errno::EACCES, IOError
      false
    rescue StandardError
      false
    end
  end
end
