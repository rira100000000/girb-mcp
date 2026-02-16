# frozen_string_literal: true

require "socket"
require "timeout"
require "set"

module GirbMcp
  class DebugClient
    DEFAULT_WIDTH = 500
    DEFAULT_TIMEOUT = 15
    CONTINUE_TIMEOUT = 30

    # ANSI escape code pattern
    ANSI_ESCAPE = /\e\[[0-9;]*m/

    attr_reader :pid, :connected, :paused
    attr_accessor :stderr_file, :stdout_file, :wait_thread, :script_file, :script_args

    def initialize
      @socket = nil
      @pid = nil
      @connected = false
      @paused = false
      @width = DEFAULT_WIDTH
      @mutex = Mutex.new
      @one_shot_breakpoints = Set.new
    end

    def connected?
      @connected && @socket && !@socket.closed?
    end

    # Connect to a debug session via Unix domain socket or TCP
    def connect(path: nil, host: nil, port: nil)
      disconnect if connected?

      if path
        @socket = Socket.unix(path)
      elsif port
        @socket = Socket.tcp(host || "localhost", port.to_i)
      else
        path = discover_socket
        @socket = Socket.unix(path)
      end

      # The debug gem protocol: client sends greeting first, then reads server output
      send_greeting
      initial_output = read_until_input
      @connected = true
      @paused = true

      { success: true, pid: @pid, output: initial_output }
    rescue Errno::ECONNREFUSED => e
      raise ConnectionError, "Connection refused: #{e.message}. " \
                             "Ensure the debug process is running with 'rdbg --open'."
    rescue Errno::ENOENT => e
      raise ConnectionError, "Socket not found: #{e.message}. " \
                             "The debug process may have exited. Use 'list_debug_sessions' to check."
    rescue GirbMcp::Error
      raise
    rescue StandardError => e
      disconnect
      raise ConnectionError, "Connection failed: #{e.class}: #{e.message}"
    end

    def disconnect
      if @socket && !@socket.closed?
        @socket.flush rescue nil
        @socket.close
      end
      @socket = nil
      @pid = nil
      @connected = false
      @paused = false
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

    # Send a debugger command and return the output
    def send_command(command, timeout: DEFAULT_TIMEOUT)
      raise SessionError, "Not connected to a debug session. Use 'connect' to establish a connection." unless connected?

      @mutex.synchronize do
        # Encode as binary to avoid Encoding::CompatibilityError when the
        # command contains non-ASCII characters (e.g., Japanese) and the
        # socket uses ASCII-8BIT encoding.
        msg = "command #{@pid} #{@width} #{command}\n"
        @socket.write(msg.b)
        output = read_until_input(timeout: timeout)
        @paused = true
        output
      end
    rescue Errno::EPIPE, Errno::ECONNRESET, IOError => e
      @connected = false
      @paused = false
      raise ConnectionError, "Connection lost while executing '#{command}': #{e.message}. " \
                             "The debug process may have exited. Use 'connect' to reconnect."
    end

    # Send a command and wait briefly for the debug gem to read it, but don't
    # wait for a full response (which may never come, e.g., after `c` with no
    # breakpoint). Used when resuming a process before disconnecting.
    def send_command_no_wait(command)
      return unless connected?

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

    # Send continue and wait longer (execution may take time to hit next breakpoint)
    def send_continue(timeout: CONTINUE_TIMEOUT)
      send_command("c", timeout: timeout)
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

    # Check if the debugger is currently in a signal trap context.
    # This is common when connecting to Puma/Rails processes via SIGURG.
    # In trap context, thread operations (Mutex lock, DB pools, autoloading) fail
    # with ThreadError: "can't be called from trap context".
    # Note: Mutex.new alone succeeds in trap context (Ruby 3.3+) — it's just object
    # allocation. Mutex#lock is needed to actually test for trap context restrictions.
    def in_trap_context?
      result = send_command("p begin; Mutex.new.lock; 'normal'; rescue ThreadError; 'trap'; end")
      result.strip.sub(/\A=> /, "").include?("trap")
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

          ready = IO.select([@socket], nil, nil, remaining)
          break unless ready

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

    # List available debug sessions
    def self.list_sessions
      dir = socket_dir
      return [] unless dir && Dir.exist?(dir)

      Dir.glob(File.join(dir, "rdbg*")).select do |path|
        File.socket?(path)
      end.filter_map do |path|
        pid = extract_pid(path)
        next unless pid && process_alive?(pid)

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

    def send_greeting
      debug_version = resolve_debug_version
      cookie = ENV["RUBY_DEBUG_COOKIE"] || "-"
      greeting = "version: #{debug_version} width: #{@width} cookie: #{cookie} nonstop: false\n"
      @socket.write(greeting.b)
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

    def read_until_input(timeout: DEFAULT_TIMEOUT)
      output_lines = []
      received_input = false

      Timeout.timeout(timeout) do
        while (line = @socket.gets)
          # Socket reads are ASCII-8BIT but debug gem output contains UTF-8 text
          line = line.chomp.force_encoding(Encoding::UTF_8)
          line = line.scrub unless line.valid_encoding?
          case line
          when /\Aout (.*)/
            output_lines << strip_ansi($1)
          when /\Ainput (\d+)/
            @pid = $1
            received_input = true
            break
          when /\Aask (\d+) (.*)/
            # Auto-answer yes to questions
            @socket.write("answer #{$1} y\n".b)
          when /\Aquit/
            @connected = false
            final = output_lines.join("\n")
            raise SessionError.new(
              "Debug session ended. The target process has finished execution.",
              final_output: final.empty? ? nil : final,
            )
          end
        end

        # Socket returned nil (EOF) without receiving input prompt - connection closed
        unless received_input
          @connected = false
          final = output_lines.join("\n")
          raise ConnectionError.new(
            "Debug session connection closed unexpectedly. The target process may have exited.",
            final_output: final.empty? ? nil : final,
          )
        end
      end

      output_lines.join("\n")
    rescue Timeout::Error
      # If we got meaningful output before timeout, return it.
      # Filter out empty lines to avoid treating blank `out` messages as real output.
      meaningful_output = output_lines.reject { |l| l.strip.empty? }
      if meaningful_output.any?
        output_lines.join("\n")
      else
        raise TimeoutError, "Timeout after #{timeout}s waiting for debugger response. " \
                            "The target process may be busy or stuck. " \
                            "Try again or use 'run_debug_command' with a longer timeout."
      end
    end

    # Non-blocking read that uses IO.select instead of Timeout.timeout.
    # Supports an interrupt check that is polled every 0.5s.
    # Returns a hash: { type: :breakpoint/:interrupted/:timeout/:timeout_with_output, output: String }
    def read_until_input_interruptible(timeout:, interrupt_check: nil)
      output_lines = []
      deadline = Time.now + timeout

      while Time.now < deadline
        if interrupt_check&.call
          return { type: :interrupted, output: output_lines.join("\n") }
        end

        remaining = [deadline - Time.now, 0.0].max
        wait_time = [0.5, remaining].min
        break if wait_time <= 0

        ready = IO.select([@socket], nil, nil, wait_time)
        next unless ready

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
          return { type: :breakpoint, output: output_lines.join("\n") }
        when /\Aask (\d+) (.*)/
          @socket.write("answer #{$1} y\n".b)
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

      # Timeout
      meaningful = output_lines.reject { |l| l.strip.empty? }
      output = output_lines.join("\n")
      if meaningful.any?
        { type: :timeout_with_output, output: output }
      else
        { type: :timeout, output: output }
      end
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
  end
end
