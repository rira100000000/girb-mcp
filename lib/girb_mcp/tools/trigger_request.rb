# frozen_string_literal: true

require "mcp"
require "net/http"
require "uri"

module GirbMcp
  module Tools
    class TriggerRequest < MCP::Tool
      DEFAULT_TIMEOUT = 30

      description "[Entry Point] Send an HTTP request to a Rails app running under the debugger. " \
                  "If a breakpoint is set, execution pauses there and you can inspect the state. " \
                  "If no breakpoint is hit, the HTTP response is returned. " \
                  "Use this with 'set_breakpoint' to debug specific Rails controller actions."

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
            description: "Request body (for POST/PUT/PATCH)",
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
        def call(method:, url:, headers: {}, body: nil, timeout: nil, session_id: nil, server_context:)
          manager = server_context[:session_manager]
          timeout_sec = timeout || DEFAULT_TIMEOUT

          # Send the HTTP request in a separate thread
          response_holder = { done: false, response: nil, error: nil }
          request_thread = Thread.new do
            response_holder[:response] = send_http_request(method, url, headers, body, timeout_sec)
            response_holder[:done] = true
          rescue StandardError => e
            response_holder[:error] = e
            response_holder[:done] = true
          end

          # If we have a connected debug session, check if a breakpoint is hit
          begin
            client = manager.client(session_id)
            # The debug session might pause at a breakpoint triggered by our request.
            # We check by trying to read from the socket with a timeout.
            # If the debugger sends new output (breakpoint hit), we report it.
            # Otherwise, we wait for the HTTP response.

            # Wait a moment for potential breakpoint hit
            sleep 0.5

            if !response_holder[:done] && client.connected?
              text = "HTTP #{method} #{url} sent.\n" \
                     "The request is in progress. The debug session is active.\n" \
                     "Use 'get_context' to check if a breakpoint was hit, or wait for the response."
              request_thread.join(timeout_sec)

              if response_holder[:done]
                if response_holder[:error]
                  text += "\n\nRequest error: #{response_holder[:error].message}"
                else
                  resp = response_holder[:response]
                  text += "\n\nHTTP Response: #{resp[:status]}\n#{resp[:body]}"
                end
              else
                text += "\n\nRequest still pending (may be paused at a breakpoint)."
              end

              return MCP::Tool::Response.new([{ type: "text", text: text }])
            end
          rescue GirbMcp::SessionError
            # No active debug session, just do a normal HTTP request
          end

          request_thread.join(timeout_sec)

          if response_holder[:error]
            text = "Request error: #{response_holder[:error].message}"
          elsif response_holder[:done]
            resp = response_holder[:response]
            text = "HTTP #{resp[:status]}\n"
            text += "Headers: #{resp[:headers].to_h.inspect}\n\n" if resp[:headers]
            text += resp[:body] || "(empty body)"
          else
            text = "Request timed out after #{timeout_sec} seconds.\n" \
                   "The server may be paused at a breakpoint. Use 'get_context' to check."
          end

          MCP::Tool::Response.new([{ type: "text", text: text }])
        rescue StandardError => e
          MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.class}: #{e.message}" }])
        end

        private

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
