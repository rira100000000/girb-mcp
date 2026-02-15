# frozen_string_literal: true

module GirbMcp
  module ExitMessageBuilder
    module_function

    # Build a detailed exit message with exception detection.
    # Parses stderr and debugger output to determine whether the program
    # exited normally or due to an unhandled exception.
    def build_exit_message(header, final_output, client)
      # Wait for the process to fully exit so all output is flushed to files.
      # wait_thread is set by run_script; nil for connect sessions.
      exit_status = wait_for_process(client)

      stderr = client&.read_stderr_output
      stdout = client&.read_stdout_output

      # Try to detect exception from stderr first, then fall back to debugger output
      exception_info = detect_exception(stderr) || detect_exception(final_output)

      parts = []

      # Build a clear header with exit status
      if exit_status
        if exit_status.success?
          parts << "#{header}\nExit status: 0 (success)"
        elsif exit_status.signaled?
          parts << "#{header}\nKilled by signal #{exit_status.termsig}"
        else
          parts << "#{header}\nExit status: #{exit_status.exitstatus} (error)"
        end
      else
        parts << header
      end

      if exception_info
        parts << "Unhandled exception: #{exception_info}"
      end

      parts << "Debugger output:\n#{final_output}" if final_output
      parts << "Program output (stdout):\n#{stdout}" if stdout
      parts << "Process stderr:\n#{stderr}" if stderr

      if stdout.nil? && stderr.nil?
        # Connect session: no captured output, guide toward run_script
        tip = "stdout/stderr are not captured for sessions started with 'connect'."
        if exception_info
          tip += "\nCheck the terminal where the debug process was started for the full stack trace."
        else
          tip += "\nThe program may have exited due to an unhandled exception — " \
                 "check the terminal where the debug process was started for details."
        end
        tip += "\n\nTo get better diagnostics next time:\n" \
               "  - Use 'run_script' instead of 'connect' to capture stdout/stderr automatically\n" \
               "  - Use set_breakpoint(exception_class: 'NoMethodError') to stop BEFORE " \
               "an exception crashes the process"
        parts << tip
      else
        # run_script session: session is over, guide toward restart
        tip = "This debug session has ended."
        rerun_hint = build_rerun_hint(client)
        if exception_info
          exc_class = exception_info.split(":").first
          tip += "\n\nTo debug the crash:\n" \
                 "  1. #{rerun_hint}\n" \
                 "  2. set_breakpoint(exception_class: '#{exc_class}') to catch the exception before it crashes"
        else
          tip += "\n\nTo restart: #{rerun_hint}"
        end
        parts << tip
      end

      parts.join("\n\n")
    end

    # Wait for the spawned process to exit (up to 5 seconds).
    # Returns Process::Status or nil.
    def wait_for_process(client)
      return nil unless client&.wait_thread

      client.wait_thread.join(5)
      client.wait_thread.value
    rescue StandardError
      nil
    end

    # Build a concrete run_script hint with the exact file/args from the session.
    def build_rerun_hint(client)
      script_file = client&.script_file
      return "run_script(file: '...', restore_breakpoints: true)" unless script_file

      args_part = client.script_args&.any? ? ", args: #{client.script_args.inspect}" : ""
      "run_script(file: '#{script_file}'#{args_part}, restore_breakpoints: true)"
    end

    # Detect Ruby exception from output text.
    # Returns "ExceptionClass: message" string, or nil if no exception found.
    def detect_exception(output)
      return nil unless output && !output.empty?

      # Ruby stack trace format:
      #   /path/to/file.rb:10:in `method': message (ExceptionClass)
      if output =~ /:\d+:in `.+': (.+) \((\w+(?:::\w+)*)\)/
        "#{$2}: #{$1}"
      # Alternative format (e.g., from raise without stack trace context):
      #   ExceptionClass: message
      elsif output =~ /\A\s*((?:\w+::)*\w+(?:Error|Exception)): (.+)/
        "#{$1}: #{$2.strip}"
      end
    end
  end
end
