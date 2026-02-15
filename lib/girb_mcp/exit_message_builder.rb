# frozen_string_literal: true

module GirbMcp
  module ExitMessageBuilder
    module_function

    # Build a detailed exit message with exception detection.
    # Parses stderr and debugger output to determine whether the program
    # exited normally or due to an unhandled exception.
    def build_exit_message(header, final_output, client)
      stderr = client&.read_stderr_output
      stdout = client&.read_stdout_output

      # Try to detect exception from stderr first, then fall back to debugger output
      exception_info = detect_exception(stderr) || detect_exception(final_output)

      parts = [header]

      if exception_info
        parts << "Unhandled exception: #{exception_info}"
      end

      parts << "Debugger output:\n#{final_output}" if final_output
      parts << "Program output (stdout):\n#{stdout}" if stdout
      parts << "Process stderr:\n#{stderr}" if stderr

      # If no stdout/stderr captured (connect session without temp files),
      # give actionable guidance
      if stdout.nil? && stderr.nil?
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
      end

      parts.join("\n\n")
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
