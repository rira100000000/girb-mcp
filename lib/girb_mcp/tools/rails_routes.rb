# frozen_string_literal: true

require "mcp"
require_relative "../rails_helper"

module GirbMcp
  module Tools
    class RailsRoutes < MCP::Tool
      description "[Investigation] Show Rails application routes. " \
                  "Displays HTTP verb, path, controller#action, and route name. " \
                  "Can filter by controller name or path pattern. " \
                  "Works in trap context (lightweight mode)."

      annotations(
        title: "Rails Routes",
        read_only_hint: true,
        destructive_hint: false,
        open_world_hint: false,
      )

      input_schema(
        properties: {
          controller: {
            type: "string",
            description: "Filter by controller name (e.g., 'users', 'api/v1/orders')",
          },
          path: {
            type: "string",
            description: "Filter by path pattern (partial match, e.g., '/users')",
          },
          session_id: {
            type: "string",
            description: "Debug session ID (uses default session if omitted)",
          },
        },
      )

      class << self
        def call(controller: nil, path: nil, session_id: nil, server_context:)
          client = server_context[:session_manager].client(session_id)
          client.auto_repause!
          RailsHelper.require_rails!(client)

          # Try Base64 script first (better formatting with aligned columns)
          text = fetch_routes_base64(client, controller, path)
          return MCP::Tool::Response.new([{ type: "text", text: text }]) if text

          # Fall back to lightweight approach (works in trap context)
          text = fetch_routes_lightweight(client, controller, path)
          return MCP::Tool::Response.new([{ type: "text", text: text }]) if text

          # Both failed — show clear unavailable message
          text = "Routes: unavailable."
          text += "\n\n#{RailsHelper::TRAP_CONTEXT_HINT}" if RailsHelper.trap_context?(client)
          MCP::Tool::Response.new([{ type: "text", text: text }])
        rescue GirbMcp::Error => e
          text = "Error: #{e.message}"
          text += "\n\n#{RailsHelper::TRAP_CONTEXT_HINT}" if begin
            RailsHelper.trap_context?(client)
          rescue StandardError
            false
          end
          MCP::Tool::Response.new([{ type: "text", text: text }])
        end

        private

        # Full Base64 script approach — better formatting but may fail in trap context
        # because `require 'base64'` or `puts` may not work.
        def fetch_routes_base64(client, controller, path)
          result = RailsHelper.run_base64_script(client, build_routes_script(controller, path), timeout: 30)
          return nil unless result
          return nil if result.include?("Error loading routes:")

          result
        rescue GirbMcp::Error
          nil
        end

        # Lightweight approach using `p` expression — works in trap context.
        # Uses expression return values (captured by debug gem) instead of `puts`.
        def fetch_routes_lightweight(client, controller, path)
          result = RailsHelper.lightweight_routes(client, controller: controller, path: path)
          return nil unless result

          lines = result[:lines]
          count = result[:count]

          if lines.empty?
            filter_desc = build_filter_description(controller, path)
            if filter_desc
              "No routes found matching #{filter_desc}.\n\nTotal routes in app: #{count}"
            else
              "No routes found."
            end
          else
            text = ""
            filter_desc = build_filter_description(controller, path)
            text += filter_desc ? "Routes (filtered by #{filter_desc}):\n" : "Routes:\n"
            lines.each_line { |line| text += "  #{line}" }
            shown = lines.count("\n") + 1
            text += "\nTotal: #{count} routes"
            text += " (showing #{shown})" if shown < count
            text
          end
        rescue GirbMcp::Error
          nil
        end

        def build_filter_description(controller, path)
          parts = []
          parts << "controller: \"#{controller}\"" if controller
          parts << "path: \"#{path}\"" if path
          parts.empty? ? nil : parts.join(", ")
        end

        # Base64 script that RETURNS a value instead of using puts.
        # In trap context, puts output is not captured by the debug gem,
        # but expression return values are always captured.
        def build_routes_script(controller, path)
          <<~RUBY
            begin
              routes = Rails.application.routes.routes
              controller_filter = #{controller&.to_s.inspect}
              path_filter = #{path&.to_s.inspect}

              results = []
              routes.each do |route|
                defaults = route.defaults
                ctrl = defaults[:controller].to_s
                action = defaults[:action].to_s
                next if ctrl.empty? && action.empty?

                route_path = route.path.spec.to_s.sub('(.:format)', '')
                verb = route.verb.to_s
                verb = "ANY" if verb.empty?
                name = route.name.to_s

                if controller_filter
                  next unless ctrl.include?(controller_filter)
                end
                if path_filter
                  next unless route_path.include?(path_filter)
                end

                results << { verb: verb, path: route_path, controller: ctrl, action: action, name: name }
              end

              if results.empty?
                filter_desc = []
                filter_desc << "controller: \\\"" + controller_filter + "\\\"" if controller_filter
                filter_desc << "path: \\\"" + path_filter + "\\\"" if path_filter
                if filter_desc.empty?
                  "No routes found."
                else
                  "No routes found matching " + filter_desc.join(", ") + "."
                end
              else
                lines = []
                filter_desc = []
                filter_desc << "controller: \\\"" + controller_filter + "\\\"" if controller_filter
                filter_desc << "path: \\\"" + path_filter + "\\\"" if path_filter
                header = filter_desc.empty? ? "Routes:" : "Routes (filtered by " + filter_desc.join(", ") + "):"
                lines << header

                verb_width = [results.map { |r| r[:verb].length }.max, 6].max
                path_width = [results.map { |r| r[:path].length }.max, 4].max

                results.each do |r|
                  name_part = r[:name].empty? ? "" : "  (" + r[:name] + ")"
                  lines << "  " + r[:verb].ljust(verb_width) + "  " + r[:path].ljust(path_width) + "  " + r[:controller] + "#" + r[:action] + name_part
                end

                lines << ""
                lines << "Total: " + results.length.to_s + " routes"
                lines.join("\\n")
              end
            rescue => e
              "Error loading routes: " + e.class.to_s + ": " + e.message
            end
          RUBY
        end
      end
    end
  end
end
