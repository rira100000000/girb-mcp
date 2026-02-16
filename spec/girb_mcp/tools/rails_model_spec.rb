# frozen_string_literal: true

RSpec.describe GirbMcp::Tools::RailsModel do
  let(:client) { build_mock_client }
  let(:manager) { build_mock_manager(client: client) }
  let(:server_context) { { session_manager: manager } }

  describe ".call" do
    before do
      allow(client).to receive(:send_command).with("p defined?(Rails)").and_return('=> "constant"')
      # Default: Base64-encoded scripts return nil
      allow(client).to receive(:send_command).with(kind_of(String), timeout: 15).and_return("=> nil")
    end

    # Helper: mock the verify_ar_model expression to return a status code
    def mock_verify(model_name, status)
      allow(client).to receive(:send_command)
        .with(/p begin; d = defined\?\(#{model_name}\)/)
        .and_return("=> \"#{status}\"")
    end

    it "displays model structure" do
      mock_verify("User", "ar")
      allow(client).to receive(:send_command)
        .with("p User.table_name")
        .and_return('=> "users"')

      call_count = 0
      allow(client).to receive(:send_command).with(/Base64/, timeout: 15) do
        call_count += 1
        case call_count
        when 1
          '=> "Columns:\n  id      integer  NOT NULL  PK\n  email   string   NOT NULL\n  name    string"'
        else
          "=> nil"
        end
      end

      response = described_class.call(model_name: "User", server_context: server_context)
      text = response_text(response)

      expect(text).to include("=== User (table: users) ===")
      expect(text).to include("Columns:")
      expect(text).to include("id")
      expect(text).to include("email")
    end

    it "displays associations" do
      mock_verify("User", "ar")
      allow(client).to receive(:send_command)
        .with("p User.table_name")
        .and_return('=> "users"')

      call_count = 0
      allow(client).to receive(:send_command).with(/Base64/, timeout: 15) do
        call_count += 1
        case call_count
        when 1
          '=> "Columns:\n  id  integer  NOT NULL  PK"'
        when 2
          '=> "Associations:\n  has_many    :posts   -> Post\n  belongs_to  :org     -> Organization"'
        else
          "=> nil"
        end
      end

      response = described_class.call(model_name: "User", server_context: server_context)
      text = response_text(response)

      expect(text).to include("Associations:")
      expect(text).to include("has_many")
      expect(text).to include(":posts")
    end

    it "displays validations" do
      mock_verify("User", "ar")
      allow(client).to receive(:send_command)
        .with("p User.table_name")
        .and_return('=> "users"')

      call_count = 0
      allow(client).to receive(:send_command).with(/Base64/, timeout: 15) do
        call_count += 1
        case call_count
        when 1
          '=> "Columns:\n  id  integer  NOT NULL  PK"'
        when 2 then "=> nil"
        when 3
          '=> "Validations:\n  presence       [:email, :name]\n  uniqueness     [:email]"'
        else
          "=> nil"
        end
      end

      response = described_class.call(model_name: "User", server_context: server_context)
      text = response_text(response)

      expect(text).to include("Validations:")
      expect(text).to include("presence")
    end

    it "displays enums" do
      mock_verify("User", "ar")
      allow(client).to receive(:send_command)
        .with("p User.table_name")
        .and_return('=> "users"')

      call_count = 0
      allow(client).to receive(:send_command).with(/Base64/, timeout: 15) do
        call_count += 1
        case call_count
        when 1
          '=> "Columns:\n  id  integer  NOT NULL  PK"'
        when 2 then "=> nil"
        when 3 then "=> nil"
        when 4
          '=> "Enums:\n  role: { guest: 0, member: 1, admin: 2 }"'
        else
          "=> nil"
        end
      end

      response = described_class.call(model_name: "User", server_context: server_context)
      text = response_text(response)

      expect(text).to include("Enums:")
      expect(text).to include("role:")
    end

    it "handles model not found" do
      mock_verify("Nonexistent", "undefined")

      response = described_class.call(model_name: "Nonexistent", server_context: server_context)
      text = response_text(response)

      expect(text).to include("Nonexistent is not defined")
      expect(text).to include("not be loaded yet")
    end

    it "handles non-ActiveRecord model" do
      mock_verify("String", "not_ar")

      response = described_class.call(model_name: "String", server_context: server_context)
      text = response_text(response)

      expect(text).to include("Error: String is not an ActiveRecord model")
    end

    context "trap context / restricted context" do
      it "shows ThreadError with trap context hint explaining why routes work but models don't" do
        mock_verify("User", "err:ThreadError")

        response = described_class.call(model_name: "User", server_context: server_context)
        text = response_text(response)

        expect(text).to include("Unable to inspect User")
        expect(text).to include("ThreadError")
        expect(text).to include("DB connections and autoloading")
        expect(text).to include("rails_routes work because they use file I/O only")
        expect(text).to include("trigger_request")
        expect(text).not_to include("is not an ActiveRecord model")
      end

      it "shows NameError when autoloading fails" do
        mock_verify("User", "err:NameError")

        response = described_class.call(model_name: "User", server_context: server_context)
        text = response_text(response)

        expect(text).to include("Unable to inspect User")
        expect(text).to include("NameError")
        expect(text).to include("trigger_request")
      end

      it "shows helpful message when verification completely fails" do
        # eval_expr returns nil (complete failure)
        allow(client).to receive(:send_command)
          .with(/p begin; d = defined/)
          .and_return("")

        response = described_class.call(model_name: "User", server_context: server_context)
        text = response_text(response)

        expect(text).to include("Unable to verify User")
        expect(text).to include("trigger_request")
        expect(text).not_to include("is not an ActiveRecord model")
      end
    end

    it "handles non-Rails process" do
      allow(client).to receive(:send_command).with("p defined?(Rails)").and_return("=> nil")

      response = described_class.call(model_name: "User", server_context: server_context)
      text = response_text(response)

      expect(text).to include("Error: Not a Rails application")
    end

    it "handles session error" do
      allow(manager).to receive(:client).and_raise(GirbMcp::SessionError, "No session")

      response = described_class.call(model_name: "User", server_context: server_context)
      text = response_text(response)

      expect(text).to include("Error: No session")
    end

    context "model listing (model_name omitted)" do
      it "lists model files with class names" do
        allow(client).to receive(:send_command)
          .with(/Dir\.glob.*models/)
          .and_return('=> "user, post, admin/account"')

        response = described_class.call(server_context: server_context)
        text = response_text(response)

        expect(text).to include("Models in app/models/")
        expect(text).to include("3 files")
        expect(text).to include("User (user.rb)")
        expect(text).to include("Post (post.rb)")
        expect(text).to include("Admin::Account (admin/account.rb)")
        expect(text).to include("rails_model(model_name:")
      end

      it "shows no models message when empty" do
        allow(client).to receive(:send_command)
          .with(/Dir\.glob.*models/)
          .and_return('=> ""')

        response = described_class.call(server_context: server_context)
        text = response_text(response)

        expect(text).to include("No model files found")
      end

      it "shows trap context hint when model listing fails" do
        allow(client).to receive(:send_command)
          .with(/Dir\.glob.*models/)
          .and_return('=> ""')
        allow(client).to receive(:in_trap_context?).and_return(true)

        response = described_class.call(server_context: server_context)
        text = response_text(response)

        expect(text).to include("No model files found")
        expect(text).to include("trap context")
      end
    end

    it "handles partial section failures" do
      mock_verify("User", "ar")
      allow(client).to receive(:send_command)
        .with("p User.table_name")
        .and_return('=> "users"')

      call_count = 0
      allow(client).to receive(:send_command).with(/Base64/, timeout: 15) do
        call_count += 1
        case call_count
        when 1
          '=> "Columns:\n  id  integer  NOT NULL  PK"'
        else
          raise GirbMcp::TimeoutError, "timeout"
        end
      end

      response = described_class.call(model_name: "User", server_context: server_context)
      text = response_text(response)

      expect(text).to include("Columns:")
      expect(text).to include("=== User (table: users) ===")
    end
  end
end
