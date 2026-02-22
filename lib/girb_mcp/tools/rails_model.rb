# frozen_string_literal: true

require "mcp"
require_relative "../rails_helper"

module GirbMcp
  module Tools
    class RailsModel < MCP::Tool
      description "[Investigation] Show ActiveRecord model structure: table name, columns (with types), " \
                  "associations, validations, enums, and scopes. " \
                  "Omit model_name to list all model files in the application. " \
                  "Use this to understand a model's schema and relationships during debugging."

      input_schema(
        properties: {
          model_name: {
            type: "string",
            description: "Model class name (e.g., 'User', 'Order', 'Admin::Account'). " \
                         "Omit to list all available models.",
          },
          session_id: {
            type: "string",
            description: "Debug session ID (uses default session if omitted)",
          },
        },
      )

      class << self
        def call(model_name: nil, session_id: nil, server_context:)
          client = server_context[:session_manager].client(session_id)
          client.auto_repause!
          RailsHelper.require_rails!(client)

          # List models when model_name is omitted
          return list_models(client) unless model_name

          # Verify model exists and is an ActiveRecord model.
          # Uses a single rescue-wrapped expression to distinguish:
          #   "ar"        — confirmed ActiveRecord model
          #   "not_ar"    — constant exists but not AR
          #   "undefined" — constant not defined (autoloading may have failed)
          #   "err:Class" — evaluation raised (ThreadError in trap context, etc.)
          verify_result = verify_ar_model(client, model_name)
          return verify_result if verify_result.is_a?(MCP::Tool::Response)

          parts = []

          # Header with table name
          table_name = eval_expr(client, "#{model_name}.table_name")
          parts << "=== #{model_name} (table: #{table_name || "unknown"}) ==="

          # Columns
          parts << build_columns_section(client, model_name)

          # Associations
          section = build_associations_section(client, model_name)
          parts << section if section

          # Validations
          section = build_validations_section(client, model_name)
          parts << section if section

          # Enums
          section = build_enums_section(client, model_name)
          parts << section if section

          # Scopes
          section = build_scopes_section(client, model_name)
          parts << section if section

          # Callbacks
          section = build_callbacks_section(client, model_name)
          parts << section if section

          text = parts.compact.join("\n\n")

          # If columns section shows an error, it likely failed due to trap context
          if text.include?("unable to retrieve") || text.include?("Error:")
            text += "\n\n#{RailsHelper::TRAP_CONTEXT_HINT}" if RailsHelper.trap_context?(client)
          end

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

        def list_models(client)
          models = RailsHelper.model_files(client)

          if models && models.any?
            text = "Models in app/models/ (#{models.size} files):\n"
            models.each do |m|
              # Convert file path to likely class name: "user" → "User", "admin/account" → "Admin::Account"
              class_name = m.split("/").map { |p| p.split("_").map(&:capitalize).join }.join("::")
              text += "  #{class_name} (#{m}.rb)\n"
            end
            text += "\nUse rails_model(model_name: \"ModelName\") to see details for a specific model."
          else
            text = "No model files found in app/models/."
            text += "\n\n#{RailsHelper::TRAP_CONTEXT_HINT}" if RailsHelper.trap_context?(client)
          end

          MCP::Tool::Response.new([{ type: "text", text: text }])
        end

        # Verify model is an ActiveRecord model using a single rescue-wrapped expression.
        # Returns nil on success (proceed with inspection), or an error Response.
        def verify_ar_model(client, model_name)
          # Single expression with rescue — captures the ACTUAL error class
          # instead of relying on external trap context detection.
          status = eval_expr(client,
            "begin; d = defined?(#{model_name}); " \
            "unless d; 'undefined'; else; " \
            "#{model_name} < ActiveRecord::Base ? 'ar' : 'not_ar'; end; " \
            "rescue => e; 'err:' + e.class.to_s; end")

          case status
          when "ar"
            nil # Verified, proceed
          when "not_ar"
            MCP::Tool::Response.new([{ type: "text",
              text: "Error: #{model_name} is not an ActiveRecord model." }])
          when /\Aerr:/
            # Evaluation raised an exception — ThreadError (trap context),
            # NameError (autoloading failed), etc.
            error_class = status.sub("err:", "")
            hint = if error_class == "ThreadError"
              "In signal trap context, model inspection requires DB connections and " \
              "autoloading, which need thread operations (Mutex/Thread). " \
              "Tools like rails_routes work because they use file I/O only.\n\n" \
              "#{RailsHelper::TRAP_CONTEXT_HINT}"
            else
              "The process may be in a restricted context where model " \
              "autoloading or class verification cannot run.\n\n" \
              "#{RailsHelper::TRAP_CONTEXT_HINT}"
            end
            MCP::Tool::Response.new([{ type: "text",
              text: "Error: Unable to inspect #{model_name} (#{error_class}). #{hint}" }])
          when "undefined"
            MCP::Tool::Response.new([{ type: "text",
              text: "Error: #{model_name} is not defined. " \
                    "The model may not be loaded yet (autoloading may be restricted " \
                    "in the current context).\n\n" \
                    "#{RailsHelper::TRAP_CONTEXT_HINT}" }])
          else
            # eval_expr returned nil — complete evaluation failure
            MCP::Tool::Response.new([{ type: "text",
              text: "Error: Unable to verify #{model_name}. " \
                    "Model verification failed (possible restricted context).\n\n" \
                    "#{RailsHelper::TRAP_CONTEXT_HINT}" }])
          end
        end

        def build_columns_section(client, model_name)
          result = RailsHelper.run_base64_script(client, build_columns_script(model_name))
          result || "Columns:\n  (unable to retrieve)"
        rescue GirbMcp::Error
          "Columns:\n  (unable to retrieve)"
        end

        def build_associations_section(client, model_name)
          RailsHelper.run_base64_script(client, build_associations_script(model_name))
        rescue GirbMcp::Error
          nil
        end

        def build_validations_section(client, model_name)
          RailsHelper.run_base64_script(client, build_validations_script(model_name))
        rescue GirbMcp::Error
          nil
        end

        def build_enums_section(client, model_name)
          RailsHelper.run_base64_script(client, build_enums_script(model_name))
        rescue GirbMcp::Error
          nil
        end

        def build_callbacks_section(client, model_name)
          RailsHelper.run_base64_script(client, build_callbacks_script(model_name))
        rescue GirbMcp::Error
          nil
        end

        def build_scopes_section(client, model_name)
          RailsHelper.run_base64_script(client, build_scopes_script(model_name))
        rescue GirbMcp::Error
          nil
        end

        def eval_expr(client, expr)
          RailsHelper.eval_expr(client, expr)
        end

        def build_columns_script(model_name)
          <<~RUBY
            begin
              cols = #{model_name}.columns
              pk = #{model_name}.primary_key
              lines = ["Columns:"]
              name_width = [cols.map { |c| c.name.length }.max || 0, 4].max
              type_width = [cols.map { |c| c.type.to_s.length }.max || 0, 4].max
              cols.each do |c|
                extras = []
                extras << "NOT NULL" unless c.null
                extras << "PK" if c.name == pk
                extras << "default: " + c.default.inspect unless c.default.nil?
                extra_str = extras.empty? ? "" : "  " + extras.join("  ")
                lines << "  " + c.name.ljust(name_width) + "  " + c.type.to_s.ljust(type_width) + extra_str
              end
              lines.join("\\n")
            rescue => e
              "Columns:\\n  Error: " + e.message
            end
          RUBY
        end

        def build_associations_script(model_name)
          <<~RUBY
            begin
              assocs = #{model_name}.reflect_on_all_associations
              if assocs.empty?
                nil
              else
                lines = ["Associations:"]
                macro_width = [assocs.map { |a| a.macro.to_s.length }.max, 10].max
                name_width = [assocs.map { |a| a.name.to_s.length + 1 }.max, 4].max
                assocs.each do |a|
                  class_name = begin; a.klass.name; rescue => e; a.options[:class_name] || a.name.to_s.classify; end
                  lines << "  " + a.macro.to_s.ljust(macro_width) + "  :" + a.name.to_s.ljust(name_width) + " -> " + class_name
                end
                lines.join("\\n")
              end
            rescue => e
              "Associations:\\n  Error: " + e.message
            end
          RUBY
        end

        def build_validations_script(model_name)
          <<~RUBY
            begin
              validators = #{model_name}.validators
              if validators.empty?
                nil
              else
                lines = ["Validations:"]
                grouped = {}
                validators.each do |v|
                  kind = v.kind.to_s
                  attrs = v.attributes.map(&:to_s)
                  grouped[kind] ||= []
                  grouped[kind].concat(attrs)
                end
                grouped.each do |kind, attrs|
                  lines << "  " + kind.ljust(14) + " [:" + attrs.uniq.join(", :") + "]"
                end
                lines.join("\\n")
              end
            rescue => e
              "Validations:\\n  Error: " + e.message
            end
          RUBY
        end

        def build_enums_script(model_name)
          <<~RUBY
            begin
              if #{model_name}.respond_to?(:defined_enums)
                enums = #{model_name}.defined_enums
                if enums.empty?
                  nil
                else
                  lines = ["Enums:"]
                  enums.each do |name, mapping|
                    lines << "  " + name + ": { " + mapping.map { |k, v| k.to_s + ": " + v.to_s }.join(", ") + " }"
                  end
                  lines.join("\\n")
                end
              end
            rescue => e
              "Enums:\\n  Error: " + e.message
            end
          RUBY
        end

        def build_scopes_script(model_name)
          <<~RUBY
            begin
              if #{model_name}.respond_to?(:scope_names)
                scope_list = #{model_name}.scope_names
              else
                # Fallback: detect scope methods by comparing with ActiveRecord::Base
                base_methods = ActiveRecord::Base.methods
                model_methods = #{model_name}.methods - base_methods
                # Scopes return ActiveRecord::Relation
                scope_list = model_methods.select do |m|
                  begin
                    #{model_name}.method(m).owner != Class && #{model_name}.method(m).arity <= 0
                  rescue
                    false
                  end
                end.sort
              end
              if scope_list && !scope_list.empty?
                "Scopes:\\n  " + scope_list.map(&:to_s).join(", ")
              end
            rescue => e
              nil
            end
          RUBY
        end

        def build_callbacks_script(model_name)
          <<~RUBY
            begin
              callback_types = %w[save create update destroy validate]
              sections = []
              callback_types.each do |type|
                method_name = "_\#{type}_callbacks"
                next unless #{model_name}.respond_to?(method_name)
                chain = #{model_name}.public_send(method_name)
                entries = []
                chain.each do |cb|
                  filter = cb.filter
                  next unless filter.is_a?(Symbol)
                  entries << [cb.kind.to_s, filter.to_s]
                end
                unless entries.empty?
                  lines = entries.map { |kind, filter| "    " + kind.ljust(7) + " :" + filter }
                  sections << "  " + type + ":\\n" + lines.join("\\n")
                end
              end
              if sections.empty?
                nil
              else
                "Callbacks:\\n" + sections.join("\\n")
              end
            rescue => e
              nil
            end
          RUBY
        end
      end
    end
  end
end
