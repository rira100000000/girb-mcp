# frozen_string_literal: true

require "mcp"
require "net/http"
require "uri"
require "json"
require_relative "../rails_helper"

module GirbMcp
  module Tools
    class TriggerRequest < MCP::Tool
      DEFAULT_TIMEOUT = 30
      HTTP_JOIN_TIMEOUT = 5

      description "[Entry Point] Send an HTTP request to a Rails app running under the debugger. " \
                  "If a breakpoint is set, execution pauses there and you can inspect the state. " \
                  "If no breakpoint is hit, the HTTP response is returned. " \
                  "Use this with 'set_breakpoint' to debug specific Rails controller actions. " \
                  "IMPORTANT: This tool automatically resumes the paused process before sending the request. " \
                  "You do NOT need to call 'continue_execution' first — just set your breakpoints, then call this tool. " \
                  "For non-GET requests to Rails, CSRF protection is automatically disabled during the request."

      input_schema(
        properties: {
          method: {
            type: "string",
            enum: ["GET", "POST", "PUT", "PATCH", "DELETE"],
            description: "HTTP method",
          },
          url: {
            type: "string",
            description: "Request URL (e.g., 'http://localhost:3000/users/1')",
          },
          headers: {
            type: "object",
            description: "HTTP headers as key-value pairs",
          },
          body: {
            type: "string",
            description: "Request body (for POST/PUT/PATCH). JSON bodies are auto-detected.",
          },
          cookies: {
            type: "object",
            description: "Cookies to send as key-value pairs (e.g., {\"_session_id\": \"abc123\"})",
          },
          skip_csrf: {
            type: "boolean",
            description: "Control CSRF handling: true=always disable, false=never disable, omit=auto-detect Rails",
          },
          timeout: {
            type: "integer",
            description: "Request timeout in seconds (default: #{DEFAULT_TIMEOUT})",
          },
          session_id: {
            type: "string",
            description: "Debug session ID to monitor for breakpoint hits (uses default if omitted)",
          },
        },
        required: ["method", "url"],
      )

      class << self
        MAX_LOG_BYTES = 4000

        def call(method:, url:, headers: {}, body: nil, cookies: nil, skip_csrf: nil,
                 timeout: nil, session_id: nil, server_context:)
          manager = server_context[:session_manager]
          timeout_sec = timeout || DEFAULT_TIMEOUT

          # Auto-detect Content-Type if body is present and no Content-Type header set
          headers = (headers || {}).dup
          if body && !headers.any? { |k, _| k.to_s.downcase == "content-type" }
            headers["Content-Type"] = detect_content_type(body)
          end

          # Build Cookie header from cookies hash
          if cookies && !cookies.empty?
            cookie_str = cookies.map { |k, v| "#{k}=#{v}" }.join("; ")
            existing = headers.find { |k, _| k.to_s.downcase == "cookie" }
            if existing
              headers[existing[0]] = "#{existing[1]}; #{cookie_str}"
            else
              headers["Cookie"] = cookie_str
            end
          end

          # CSRF handling: disable forgery protection for non-GET requests on Rails
          csrf_disabled = false
          client = nil
          log_capture = nil
          begin
            client = manager.client(session_id)
            # Only send debug commands if the process is paused (at an input prompt).
            # After a continue_execution timeout, the process is running and sending
            # commands would violate the debug protocol, causing connection loss.
            if client.paused
              if method != "GET" && should_disable_csrf?(skip_csrf, client)
                csrf_disabled = temporarily_disable_csrf(client)
              end
              # Snapshot log file position before request for Rails log capture
              log_capture = start_log_capture(client)
            end
          rescue GirbMcp::SessionError
            client = nil
          end

          begin
            response = if client&.connected?
              handle_with_debug_session(client, method, url, headers, body, timeout_sec)
            else
              handle_without_session(method, url, headers, body, timeout_sec)
            end

            append_captured_logs(response, log_capture)
          ensure
            # Only restore CSRF when the process is paused (at a breakpoint).
            # If the process is running (interrupted/timeout), sending commands
            # would corrupt the debug protocol and cause session disconnection.
            if csrf_disabled && client&.connected? && client.paused
              restore_csrf(client)
            end
          end
        rescue StandardError => e
          MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.class}: #{e.message}" }])
        end

        private

        def handle_with_debug_session(client, method, url, headers, body, timeout)
          http_holder = { response: nil, error: nil, done: false }

          if client.paused
            # Start HTTP request in a background thread (concurrent with continue)
            http_thread = start_http_thread(method, url, headers, body, timeout, http_holder)

            pending_output = client.ensure_paused(timeout: 2)

            if pending_output&.include?("Stop by")
              return build_breakpoint_response(client, method, url, pending_output,
                                               http_thread: http_thread, http_holder: http_holder)
            end

            # Process is confirmed paused. Resume and wait for breakpoint.
            # The HTTP request (sent concurrently) will trigger the breakpoint.
            result = client.continue_and_wait(timeout: timeout) { http_holder[:done] }
          else
            # Process is running (e.g., after continue_execution timeout).
            # Start HTTP request, then wait for the breakpoint to be hit.
            http_thread = start_http_thread(method, url, headers, body, timeout, http_holder)
            result = client.wait_for_breakpoint(timeout: timeout) { http_holder[:done] }
          end

          handle_debug_result(result, client, method, url, http_thread, http_holder, timeout)
        rescue GirbMcp::SessionError, GirbMcp::ConnectionError => e
          # Debug session died — wait for HTTP response
          http_thread&.join(timeout)
          if http_holder[:done] && http_holder[:response]
            text = "Debug session lost: #{e.message}\n\n#{format_response(http_holder[:response])}"
          elsif http_holder[:done] && http_holder[:error]
            text = "Debug session lost: #{e.message}\nHTTP error: #{http_holder[:error].message}"
          else
            text = "Error: #{e.message}"
          end
          MCP::Tool::Response.new([{ type: "text", text: text }])
        end

        def handle_without_session(method, url, headers, body, timeout)
          response = send_http_request(method, url, headers, body, timeout)
          text = format_response(response)
          MCP::Tool::Response.new([{ type: "text", text: text }])
        rescue StandardError => e
          MCP::Tool::Response.new([{ type: "text", text: "Request error: #{e.message}" }])
        end

        def handle_debug_result(result, client, method, url, http_thread, http_holder, timeout)
          case result[:type]
          when :breakpoint
            build_breakpoint_response(client, method, url, result[:output],
                                      http_thread: http_thread, http_holder: http_holder)

          when :interrupted
            # HTTP response triggered the interrupt — wait for thread to finish
            http_thread.join(HTTP_JOIN_TIMEOUT)
            build_http_done_response(method, url, http_holder)

          when :timeout, :timeout_with_output
            # Neither breakpoint nor HTTP response in time
            http_thread.join(HTTP_JOIN_TIMEOUT) # Give HTTP a bit more time
            if http_holder[:done]
              build_http_done_response(method, url, http_holder)
            else
              text = "HTTP #{method} #{url}\n\n" \
                     "No breakpoint was hit and the request has not completed after #{timeout}s.\n" \
                     "Possible causes:\n" \
                     "  - No breakpoints are set on the code path for this request\n" \
                     "  - The URL may be incorrect (check the path and port)\n" \
                     "  - The server may be processing a long-running operation\n\n"
              text += breakpoint_diagnostics(client)
              MCP::Tool::Response.new([{ type: "text", text: text }])
            end
          end
        end

        def build_breakpoint_response(client, method, url, bp_output,
                                      http_thread: nil, http_holder: nil)
          client.cleanup_one_shot_breakpoints(bp_output)
          bp_output = StopEventAnnotator.annotate_breakpoint_hit(bp_output)
          bp_output = StopEventAnnotator.enrich_stop_context(bp_output, client)

          # Save pending HTTP info so continue_execution can retrieve the response
          if http_thread && http_holder
            client.pending_http = { thread: http_thread, holder: http_holder,
                                    method: method, url: url }
          end

          text = "HTTP #{method} #{url} — request sent.\n\n" \
                 "Breakpoint hit:\n#{bp_output}\n\n" \
                 "The request is paused at the breakpoint. " \
                 "Use 'get_context' to inspect variables, " \
                 "then 'continue_execution' to let the request complete and see the HTTP response."
          MCP::Tool::Response.new([{ type: "text", text: text }])
        end

        def build_http_done_response(method, url, http_holder, client: nil)
          if http_holder[:error]
            text = "HTTP #{method} #{url}\n\nRequest error: #{http_holder[:error].message}"
          elsif http_holder[:response]
            text = "HTTP #{method} #{url}\n\nNo breakpoint hit.\n\n#{format_response(http_holder[:response])}"
          else
            text = "HTTP #{method} #{url}\n\nUnexpected state: request completed without response."
          end
          MCP::Tool::Response.new([{ type: "text", text: text }])
        end

        def detect_content_type(body)
          stripped = body.strip
          if stripped.start_with?("{") || stripped.start_with?("[")
            "application/json"
          else
            "application/x-www-form-urlencoded"
          end
        end

        def should_disable_csrf?(skip_csrf, client)
          return skip_csrf unless skip_csrf.nil?

          # Auto-detect: disable if connected to a Rails app
          RailsHelper.rails?(client)
        end

        def temporarily_disable_csrf(client)
          result = client.send_command(
            "p defined?(ActionController::Base) && ActionController::Base.allow_forgery_protection",
          )
          cleaned = result.strip.sub(/\A=> /, "")
          return false unless cleaned == "true"

          client.send_command("ActionController::Base.allow_forgery_protection = false")
          true
        rescue GirbMcp::Error
          false
        end

        def restore_csrf(client)
          client.send_command("ActionController::Base.allow_forgery_protection = true")
        rescue GirbMcp::Error
          # Best-effort: session may have ended
        end

        def format_response(resp)
          parts = []
          status = resp[:status]
          parts << "HTTP #{status}"

          # Show redirect location prominently
          headers = resp[:headers] || {}
          location = headers["location"]&.first
          parts << "Location: #{location}" if location

          # Show Set-Cookie headers
          set_cookies = headers["set-cookie"]
          if set_cookies && !set_cookies.empty?
            parts << "Set-Cookie: #{set_cookies.join("; ")}"
          end

          parts << ""

          # Format body based on content type
          body = resp[:body]
          content_type = headers["content-type"]&.first || ""

          if body.nil? || body.empty?
            parts << "(empty body)"
          elsif content_type.include?("application/json")
            parts << format_json_body(body)
          elsif content_type.include?("text/html")
            parts << format_html_body(body)
          else
            parts << body
          end

          parts.join("\n")
        end

        def format_json_body(body)
          parsed = JSON.parse(body)
          JSON.pretty_generate(parsed)
        rescue JSON::ParserError
          body
        end

        def format_html_body(body)
          if body.length > 1000
            "#{body[0, 1000]}\n\n... (HTML truncated, #{body.length} bytes total)"
          else
            body
          end
        end

        # Build diagnostic info about current breakpoints for timeout/no-hit messages.
        def breakpoint_diagnostics(client)
          return "Use 'get_context' to check the current debugger state.\n" unless client&.connected? && client.paused

          bp_list = client.send_command("info breakpoints")
          cleaned = bp_list.strip
          if cleaned.empty? || cleaned.include?("No breakpoints")
            "Current breakpoints: (none set)\n" \
            "Hint: Use 'set_breakpoint' to add a breakpoint before calling trigger_request.\n"
          else
            "Current breakpoints:\n#{cleaned}\n\n" \
            "Verify that the breakpoint file paths match your request's code path.\n"
          end
        rescue GirbMcp::Error
          "Use 'get_context' to check the current debugger state.\n"
        end

        # Snapshot the Rails log file position before the request.
        # Returns { path:, position: } or nil if not available.
        def start_log_capture(client)
          return nil unless RailsHelper.rails?(client)

          log_path = RailsHelper.log_file_path(client)
          return nil unless log_path && File.exist?(log_path)

          { path: log_path, position: File.size(log_path) }
        rescue StandardError
          nil
        end

        # Read new log entries since the snapshot and append to the response.
        def append_captured_logs(response, log_capture)
          return response unless log_capture

          logs = read_log_diff(log_capture[:path], log_capture[:position])
          return response if logs.nil? || logs.empty?

          # Append log section to the existing response text
          existing = response.content.first
          return response unless existing.is_a?(Hash) && existing[:type] == "text"

          log_section = "\n\n--- Server Log ---\n#{logs}"
          updated_text = existing[:text] + log_section
          MCP::Tool::Response.new([{ type: "text", text: updated_text }])
        end

        # Read log file content from a saved position.
        # Returns the new log content (truncated if too long) or nil.
        def read_log_diff(log_path, start_position)
          return nil unless File.exist?(log_path)

          current_size = File.size(log_path)
          return nil if current_size <= start_position

          bytes_to_read = current_size - start_position
          content = File.binread(log_path, bytes_to_read, start_position)
          content = content.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
          content.strip!
          return nil if content.empty?

          if content.length > MAX_LOG_BYTES
            content = content[0, MAX_LOG_BYTES] + "\n... (log truncated, #{bytes_to_read} bytes total)"
          end

          content
        rescue StandardError
          nil
        end

        def start_http_thread(method, url, headers, body, timeout, http_holder)
          Thread.new do
            http_holder[:response] = send_http_request(method, url, headers, body, timeout)
          rescue StandardError => e
            http_holder[:error] = e
          ensure
            http_holder[:done] = true
          end
        end

        def send_http_request(method, url, headers, body, timeout)
          uri = URI.parse(url)
          http = Net::HTTP.new(uri.host, uri.port)
          http.open_timeout = timeout
          http.read_timeout = timeout
          http.use_ssl = uri.scheme == "https"

          request_class = {
            "GET" => Net::HTTP::Get,
            "POST" => Net::HTTP::Post,
            "PUT" => Net::HTTP::Put,
            "PATCH" => Net::HTTP::Patch,
            "DELETE" => Net::HTTP::Delete,
          }[method]

          request = request_class.new(uri)
          headers.each { |k, v| request[k] = v } if headers
          request.body = body if body

          response = http.request(request)

          {
            status: "#{response.code} #{response.message}",
            headers: response.to_hash,
            body: response.body&.force_encoding("UTF-8"),
          }
        end
      end
    end
  end
end
