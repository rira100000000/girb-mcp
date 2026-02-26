# frozen_string_literal: true

require "mcp"
require "tempfile"

module GirbMcp
  module Tools
    class RunScript < MCP::Tool
      description "[Entry Point] Launch a Ruby script under the debugger and automatically connect to it. " \
                  "The script starts and pauses at breakpoints or 'binding.break' in the source. " \
                  "Use breakpoints parameter to set initial breakpoints before execution starts " \
                  "(e.g., breakpoints: ['User#save', 'app/models/user.rb:10']). " \
                  "This is the easiest way to start debugging a script from scratch. " \
                  "Use restore_breakpoints: true to re-run with the same breakpoints after a crash."

      annotations(
        title: "Run Ruby Script",
        read_only_hint: false,
        destructive_hint: false,
        open_world_hint: true,
      )

      input_schema(
        properties: {
          file: {
            type: "string",
            description: "Path to the Ruby script to run",
          },
          args: {
            type: "array",
            items: { type: "string" },
            description: "Command-line arguments to pass to the script",
          },
          port: {
            type: "integer",
            description: "TCP port for debug connection (auto-assigned if omitted)",
          },
          breakpoints: {
            type: "array",
            items: { type: "string" },
            description: "Breakpoints to set before execution starts. Each entry is a breakpoint spec: " \
                         "'file.rb:10' for line, 'Class#method' for method, or 'catch ExceptionClass' for exception. " \
                         "The script pauses at line 1, breakpoints are set, then execution continues.",
          },
          restore_breakpoints: {
            type: "boolean",
            description: "If true, restores breakpoints saved from previous sessions. " \
                         "Useful for re-running the same script after a crash with identical breakpoints. " \
                         "Default: false (starts fresh without inheriting previous breakpoints).",
          },
        },
        required: ["file"],
      )

      class << self
        def call(file:, args: [], port: nil, breakpoints: nil, restore_breakpoints: nil, server_context:)
          manager = server_context[:session_manager]

          # Clean up dead sessions from previous runs
          cleaned = manager.cleanup_dead_sessions
          # Check if there are still active sessions
          still_active = manager.active_sessions.select { |s| s[:connected] }

          # Clear saved breakpoints unless explicitly restoring.
          # Explicit breakpoints parameter takes precedence over restore.
          manager.clear_breakpoint_specs if !restore_breakpoints || breakpoints&.any?

          unless File.exist?(file)
            return MCP::Tool::Response.new([{ type: "text", text: "Error: File not found: #{file}" }])
          end

          # Verify rdbg is available
          unless system("which rdbg > /dev/null 2>&1")
            return MCP::Tool::Response.new([{ type: "text", text:
              "Error: 'rdbg' command not found. Install the debug gem: gem install debug" }])
          end

          # Start rdbg with --open so we can connect to it.
          # When initial breakpoints are specified, omit --nonstop so the program
          # pauses at line 1, giving us time to set breakpoints before execution.
          debug_port = port || find_available_port
          has_initial_bps = breakpoints&.any?
          cmd = ["rdbg", "--open", "--port=#{debug_port}"]
          cmd << "--nonstop" unless has_initial_bps
          cmd += ["--", file, *args]

          # Capture stdout/stderr to temp files for post-mortem diagnostics
          stdout_tmpfile = Tempfile.create(["girb-mcp-stdout-", ".log"])
          stdout_path = stdout_tmpfile.path
          stdout_tmpfile.close

          stderr_tmpfile = Tempfile.create(["girb-mcp-stderr-", ".log"])
          stderr_path = stderr_tmpfile.path
          stderr_tmpfile.close

          pid = spawn(*cmd, out: stdout_path, err: stderr_path)
          wait_thread = Process.detach(pid)

          # Wait for the debug server to be ready
          connected = false
          10.times do
            sleep 0.5

            # Check if the process is still alive
            unless process_alive?(pid)
              return MCP::Tool::Response.new([{ type: "text", text:
                "Error: Script exited immediately (PID: #{pid}). " \
                "Check the script for syntax errors or missing dependencies." }])
            end

            begin
              result = manager.connect(host: "localhost", port: debug_port)
              connected = true

              # Store metadata on the client for post-mortem diagnostics and rerun
              client = manager.client(result[:session_id])
              client.stdout_file = stdout_path
              client.stderr_file = stderr_path
              client.wait_thread = wait_thread
              client.script_file = file
              client.script_args = args

              initial_output = result[:output]

              # Auto-skip if stopped at internal Ruby code (e.g., bundled_gems.rb due to SIGURG)
              initial_output, skipped = skip_internal_code(client, initial_output)

              # Set initial breakpoints and continue past the line-1 stop
              bp_results = []
              deferred_bps = []
              if has_initial_bps
                breakpoints.each do |bp|
                  bp_cmd = bp.start_with?("catch ") ? bp : "break #{bp}"
                  bp_output = client.send_command(bp_cmd)
                  first_line = bp_output.lines.first&.strip || ""

                  if first_line.include?("Unknown") || first_line.include?("not found")
                    # Class not defined yet at line 1 — defer until after continue
                    deferred_bps << { spec: bp, cmd: bp_cmd, reason: first_line }
                  else
                    display = first_line.include?("duplicated") ? "Already set (reused existing)" : first_line
                    bp_results << { spec: bp, output: display }
                    manager.record_breakpoint(bp_cmd)
                  end
                rescue GirbMcp::Error => e
                  bp_results << { spec: bp, error: e.message }
                end

                # Continue past the initial line-1 stop (loads class definitions)
                begin
                  initial_output = client.send_continue
                  initial_output, skipped = skip_internal_code(client, initial_output) unless skipped
                rescue GirbMcp::SessionError => e
                  # Program exited before hitting any breakpoint
                  text = GirbMcp::ExitMessageBuilder.build_exit_message(
                    "Program finished before hitting any breakpoint.", e.final_output, client,
                  )
                  return MCP::Tool::Response.new([{ type: "text", text: text }])
                end

                # Retry deferred breakpoints now that classes should be defined.
                # Don't continue again — the program is already stopped at a useful
                # point (debugger statement or an immediate breakpoint).
                deferred_bps.each do |db|
                  bp_output = client.send_command(db[:cmd])
                  first_line = bp_output.lines.first&.strip || ""
                  display = first_line.include?("duplicated") ? "Already set (reused existing)" : first_line
                  bp_results << { spec: db[:spec], output: display, deferred: true }
                  manager.record_breakpoint(db[:cmd])
                rescue GirbMcp::Error => e
                  bp_results << { spec: db[:spec], error: e.message }
                end
              end

              session_notes = []
              if cleaned.any?
                session_notes << "Cleaned up #{cleaned.size} previous session(s): " \
                                 "#{cleaned.map { |c| c[:session_id] }.join(", ")}"
              end
              if still_active.any?
                session_notes << "Note: #{still_active.size} other session(s) still active " \
                                 "(#{still_active.map { |s| s[:session_id] }.join(", ")})"
              end

              text = ""
              text += session_notes.join("\n") + "\n\n" if session_notes.any?
              text += "Script started (PID: #{pid}) and connected via port #{debug_port}.\n" \
                      "Session ID: #{result[:session_id]}"
              text += "\n(auto-skipped internal code stop)" if skipped
              text += "\n\n#{initial_output}"

              # Show initial breakpoint results
              if bp_results.any?
                text += "\n\nSet #{bp_results.size} initial breakpoint(s):"
                bp_results.each do |r|
                  text += if r[:error]
                    "\n  #{r[:spec]} -> Error: #{r[:error]}"
                  elsif r[:deferred]
                    "\n  #{r[:spec]} -> #{r[:output]} (set after class loaded)"
                  else
                    "\n  #{r[:spec]} -> #{r[:output]}"
                  end
                end
              end

              # Restore breakpoints from previous sessions (skip when initial BPs were provided)
              restored = has_initial_bps ? [] : manager.restore_breakpoints(client)
              if restored.any?
                text += "\n\nRestored #{restored.size} breakpoint(s) from previous session:"
                restored.each do |r|
                  text += if r[:error]
                    "\n  #{r[:spec]} -> Error: #{r[:error]}"
                  else
                    "\n  #{r[:spec]} -> #{r[:output]}"
                  end
                end
              end

              return MCP::Tool::Response.new([{ type: "text", text: text }])
            rescue GirbMcp::Error
              next
            end
          end

          unless connected
            Process.kill("TERM", pid) rescue nil
            # Read any captured output for diagnostics
            stdout_output = File.read(stdout_path, encoding: "UTF-8").strip rescue nil
            stderr_output = File.read(stderr_path, encoding: "UTF-8").strip rescue nil
            File.delete(stdout_path) rescue nil
            File.delete(stderr_path) rescue nil
            msg = "Error: Script started (PID: #{pid}) but could not connect to debug session " \
                  "on port #{debug_port} within 5 seconds. The script may have exited early."
            msg += "\n\nProgram output (stdout):\n#{stdout_output}" if stdout_output && !stdout_output.empty?
            msg += "\n\nProcess stderr:\n#{stderr_output}" if stderr_output && !stderr_output.empty?
            return MCP::Tool::Response.new([{ type: "text", text: msg }])
          end
        rescue Errno::ENOENT => e
          MCP::Tool::Response.new([{ type: "text", text: "Error: Command not found: #{e.message}" }])
        rescue StandardError => e
          MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.class}: #{e.message}" }])
        end

        private

        # Patterns indicating the debugger stopped at internal Ruby/gem code
        # rather than user code. This can happen due to SIGURG or other signals.
        INTERNAL_CODE_PATTERNS = [
          %r{/bundled_gems\.rb}i,
          %r{/rubygems/}i,
          %r{/ruby/lib/}i,
          %r{/lib/ruby/\d}i,
          %r{<internal:}i,
        ].freeze

        MAX_SKIP_ATTEMPTS = 5

        # Check if the debugger stopped at internal code and auto-continue if so.
        # Loops up to MAX_SKIP_ATTEMPTS times to skip through multiple internal stops.
        # Returns [output, skipped] where skipped is true if we continued past internal code.
        def skip_internal_code(client, output)
          skipped = false

          MAX_SKIP_ATTEMPTS.times do
            break unless INTERNAL_CODE_PATTERNS.any? { |pattern| output.match?(pattern) }

            output = client.send_continue
            skipped = true
          end

          [output, skipped]
        rescue GirbMcp::Error
          # If continue fails (e.g., program exited), return what we have
          [output, skipped || false]
        end

        def find_available_port
          server = TCPServer.new("127.0.0.1", 0)
          port = server.addr[1]
          server.close
          port
        end

        def process_alive?(pid)
          Process.kill(0, pid)
          true
        rescue Errno::ESRCH, Errno::EPERM
          false
        end
      end
    end
  end
end
