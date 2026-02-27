# frozen_string_literal: true

module GirbMcp
  module PendingHttpHelper
    module_function

    # Check for pending HTTP request status and return a note string.
    # Returns nil when there is no pending HTTP or when it is still running (normal state).
    def pending_http_note(client)
      pending = client.pending_http
      return nil unless pending

      holder = pending[:holder]
      return nil unless holder[:done]

      if holder[:error]
        "Note: HTTP request (#{pending[:method]} #{pending[:url]}) failed: #{holder[:error].message}. " \
          "Use 'continue_execution' to resume."
      elsif holder[:response]
        "Note: HTTP response received (#{holder[:response][:status]}). " \
          "Use 'continue_execution' to see the full response."
      end
    end
  end
end
