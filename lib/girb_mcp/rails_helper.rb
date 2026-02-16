# frozen_string_literal: true

module GirbMcp
  module RailsHelper
    module_function

    # Verify that the connected process is a Rails application.
    # Raises SessionError if Rails is not defined.
    def require_rails!(client)
      result = client.send_command("p defined?(Rails)")
      unless result.strip.sub(/\A=> /, "").include?("constant")
        raise GirbMcp::SessionError, "Not a Rails application. This tool requires a connected Rails process."
      end
    end

    # Check if Rails is available without raising.
    # Returns true if the connected process has Rails loaded.
    def rails?(client)
      result = client.send_command("p defined?(Rails)")
      result.strip.sub(/\A=> /, "").include?("constant")
    rescue GirbMcp::Error
      false
    end

    # Check if the client is in signal trap context.
    # Returns true if thread operations are restricted.
    def trap_context?(client)
      client.respond_to?(:in_trap_context?) && client.in_trap_context?
    rescue GirbMcp::Error
      false
    end

    # --- Lightweight methods (trap-safe, no Base64/require/puts) ---

    # Evaluate a simple `p` expression and return the cleaned string result.
    # Uses `p` (not `puts`) because `p` output is captured as the expression
    # result by the debug gem, which works even in signal trap context.
    # Returns nil if the result is nil or evaluation fails.
    def eval_expr(client, expr)
      result = client.send_command("p #{expr}")
      cleaned = result.strip.sub(/\A=> /, "")
      return nil if cleaned == "nil" || cleaned.empty?

      if cleaned.start_with?('"') && cleaned.end_with?('"')
        cleaned = cleaned[1..-2]
        cleaned = cleaned.gsub('\\n', "\n").gsub('\\"', '"').gsub("\\\\", "\\")
      end
      cleaned.empty? ? nil : cleaned
    rescue GirbMcp::Error
      nil
    end

    # Fetch routes using a single `p` expression (trap-safe).
    # Returns { count: Integer, lines: String } or nil on failure.
    def lightweight_routes(client, controller: nil, path: nil, limit: 200)
      filter_parts = ["r.defaults[:controller].to_s!=''"]
      filter_parts << "r.defaults[:controller].to_s.include?(#{controller.inspect})" if controller
      filter_parts << "r.path.spec.to_s.include?(#{path.inspect})" if path
      filter = filter_parts.join(" && ")

      count_output = eval_expr(client,
        "Rails.application.routes.routes.count{|r|r.defaults[:controller].to_s!=''}")
      return nil if count_output.nil? # eval failed — can't access routes

      count = count_output.to_i

      expr = "Rails.application.routes.routes.select{|r|#{filter}}." \
             "first(#{limit}).map{|r|" \
             "r.verb.to_s.ljust(7)+' '+" \
             "r.path.spec.to_s.sub('(.:format)','')+' '+" \
             "r.defaults[:controller].to_s+'#'+r.defaults[:action].to_s+" \
             "(r.name.to_s.empty? ? '' : '  ('+r.name.to_s+')')}.join(\"\\n\")"
      lines = eval_expr(client, expr)

      { count: count, lines: lines || "" }
    rescue GirbMcp::Error
      nil
    end

    # Fetch a compact route summary for connect output (trap-safe).
    # Returns { count: Integer, samples: [String] } or nil.
    def route_summary(client, limit: 5)
      count_output = eval_expr(client,
        "Rails.application.routes.routes.count{|r|r.defaults[:controller].to_s!=''}")
      return nil if count_output.nil?

      count = count_output.to_i

      sample_expr = "Rails.application.routes.routes.select{|r|r.defaults[:controller].to_s!=''}." \
                    "first(#{limit}).map{|r|" \
                    "r.verb.to_s.ljust(7)+' '+" \
                    "r.path.spec.to_s.sub('(.:format)','')+' '+" \
                    "r.defaults[:controller].to_s+'#'+r.defaults[:action].to_s}.join(\"\\n\")"
      samples = eval_expr(client, sample_expr)

      { count: count, samples: samples&.split("\n") || [] }
    rescue GirbMcp::Error
      nil
    end

    # List model files from app/models/ using Dir.glob (trap-safe).
    # Returns array of model file names (e.g., ["user", "post", "admin/account"]) or nil.
    def model_files(client)
      output = eval_expr(client,
        "Dir.glob(Rails.root.join('app','models','**','*.rb').to_s)." \
        "sort.map{|f|f.split('/models/').last.sub('.rb','')}.reject{|f|f=='application_record'}.join(', ')")
      return nil if output.nil? || output.empty?

      output.split(", ")
    rescue GirbMcp::Error
      nil
    end

    TRAP_CONTEXT_HINT = "Note: The process may be in signal trap context (common with Puma). " \
                        "Set a breakpoint and use trigger_request to escape trap context first."
  end
end
