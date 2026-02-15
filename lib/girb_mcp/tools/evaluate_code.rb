# frozen_string_literal: true

require "mcp"
require "base64"

module GirbMcp
  module Tools
    class EvaluateCode < MCP::Tool
      description "[Investigation] Execute Ruby code in the live context of the paused process. " \
                  "The code runs in the current binding — you can access local variables, " \
                  "call methods, inspect return values, or test fixes. " \
                  "stdout output (from puts, print, etc.) is automatically captured and returned. " \
                  "Example: evaluate_code(code: \"user.errors.full_messages\")"

      input_schema(
        properties: {
          code: {
            type: "string",
            description: "Ruby code to execute (e.g., 'user.valid?', 'Order.where(status: :pending).count')",
          },
          session_id: {
            type: "string",
            description: "Debug session ID (uses default session if omitted)",
          },
        },
        required: ["code"],
      )

      class << self
        def call(code:, session_id: nil, server_context:)
          client = server_context[:session_manager].client(session_id)

          stdout_redirected = false
          suspended_catch_bps = []

          begin
            # Temporarily disable catch breakpoints to prevent them from
            # firing on exceptions raised during code evaluation
            suspended_catch_bps = suspend_catch_breakpoints(client)

            # Redirect $stdout to capture puts/print output
            client.send_command(
              'require "stringio"; $__girb_cap = StringIO.new; $__girb_old = $stdout; $stdout = $__girb_cap',
            )
            stdout_redirected = true

            # Evaluate user code (pp formats the return value)
            # The debug gem protocol is line-based, so multi-line code must be
            # encoded into a single line to avoid breaking the protocol.
            # The code is wrapped in begin/rescue to capture exceptions in
            # $__girb_err, allowing us to distinguish errors from normal nil.
            output = client.send_command(build_eval_command(code))

            # Restore $stdout and read captured output
            client.send_command("$stdout = $__girb_old")
            stdout_redirected = false
            captured = read_captured_stdout(client)

            # Check if evaluation raised an exception
            err_info = read_eval_error(client)

            if err_info
              text = "Error: #{err_info}"
              text += "\n\nDebugger output:\n#{output}" if output && !output.strip.empty? && output.strip != "nil"
            else
              text = output
            end
            text += "\n\nCaptured stdout:\n#{captured}" if captured
            MCP::Tool::Response.new([{ type: "text", text: text }])
          rescue GirbMcp::TimeoutError => e
            MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.message}\n\n" \
              "The code may be taking too long to execute. Consider:\n" \
              "- Breaking the expression into smaller parts\n" \
              "- Using 'run_debug_command' with a custom timeout" }])
          rescue GirbMcp::Error => e
            MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.message}" }])
          ensure
            if stdout_redirected
              client.send_command('$stdout = $__girb_old if defined?($__girb_old)') rescue nil
            end
            restore_catch_breakpoints(client, suspended_catch_bps)
          end
        end

        private

        # Build a debug command that evaluates the given code.
        # The code is wrapped in begin/rescue to capture exceptions in
        # $__girb_err. On error, the rescue returns nil (which pp shows),
        # but the error is preserved in the global variable for structured
        # error reporting.
        # Base64-encoding is used when the code contains newlines (the debug
        # gem protocol is line-based) or non-ASCII characters (to avoid
        # encoding conflicts on the socket).
        def build_eval_command(code)
          if code.include?("\n") || !code.ascii_only?
            encoded = Base64.strict_encode64(code.encode(Encoding::UTF_8))
            "$__girb_err=nil; pp(begin; " \
            "eval(Base64.decode64('#{encoded}').force_encoding('UTF-8'), binding); " \
            'rescue => __e; $__girb_err="#{__e.class}: #{__e.message}"; nil; end)'
          else
            "$__girb_err=nil; pp(begin; (#{code}); " \
            'rescue => __e; $__girb_err="#{__e.class}: #{__e.message}"; nil; end)'
          end
        end

        # Check $__girb_err for a captured exception from the eval wrapper.
        # Returns "ClassName: message" string, or nil if no error.
        def read_eval_error(client)
          result = client.send_command("p $__girb_err")
          cleaned = result.strip.sub(/\A=> /, "")
          return nil if cleaned == "nil" || cleaned.empty?

          cleaned = cleaned[1..-2] if cleaned.start_with?('"') && cleaned.end_with?('"')
          cleaned.empty? ? nil : cleaned
        rescue GirbMcp::Error
          nil
        end

        def read_captured_stdout(client)
          result = client.send_command("p $__girb_cap.string")
          cleaned = result.strip.sub(/\A=> /, "")
          return nil if cleaned == '""' || cleaned == "nil" || cleaned.empty?

          # Remove surrounding quotes and unescape Ruby string escapes
          if cleaned.start_with?('"') && cleaned.end_with?('"')
            cleaned = cleaned[1..-2]
            cleaned = unescape_ruby_string(cleaned)
          end
          cleaned.empty? ? nil : cleaned
        rescue GirbMcp::Error
          nil
        end

        def unescape_ruby_string(str)
          str.gsub(/\\([nrt\\"'])/) do
            case $1
            when "n" then "\n"
            when "r" then "\r"
            when "t" then "\t"
            when "\\" then "\\"
            when '"' then '"'
            when "'" then "'"
            end
          end
        end

        # Temporarily remove all catch breakpoints by deleting them.
        # Returns an array of exception class names that were removed.
        # The debug gem does not support disable/enable, so we must
        # delete and recreate catch breakpoints.
        def suspend_catch_breakpoints(client)
          output = client.send_command("info break")
          suspended = []

          output.each_line do |line|
            next unless line.include?("BP - Catch")
            # Match: #1  BP - Catch  "NoMethodError"
            next unless (match = line.match(/#(\d+)\s+BP - Catch\s+"([^"]+)"/))

            bp_num = match[1]
            exception_class = match[2]
            client.send_command("delete #{bp_num}")
            suspended << exception_class
          end

          suspended
        rescue GirbMcp::Error
          []
        end

        # Recreate catch breakpoints that were previously suspended.
        def restore_catch_breakpoints(client, exception_classes)
          exception_classes.each do |exc_class|
            client.send_command("catch #{exc_class}")
          rescue GirbMcp::Error
            # Best-effort: session may have ended
          end
        end
      end
    end
  end
end
