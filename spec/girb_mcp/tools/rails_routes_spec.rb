# frozen_string_literal: true

RSpec.describe GirbMcp::Tools::RailsRoutes do
  let(:client) { build_mock_client }
  let(:manager) { build_mock_manager(client: client) }
  let(:server_context) { { session_manager: manager } }

  describe ".call" do
    before do
      allow(client).to receive(:send_command).with("p defined?(Rails)").and_return('=> "constant"')
      # Default: Base64 script returns nil (falls through to lightweight)
      allow(client).to receive(:send_command).with(kind_of(String), timeout: 30).and_return("=> nil")
    end

    it "displays routes via Base64 script" do
      allow(client).to receive(:send_command)
        .with(/Base64/, timeout: 30)
        .and_return('=> "Routes:\n  GET  /users  users#index  (users)\n\nTotal: 1 routes"')

      response = described_class.call(server_context: server_context)
      text = response_text(response)

      expect(text).to include("Routes:")
      expect(text).to include("GET")
      expect(text).to include("/users")
      expect(text).to include("users#index")
      expect(text).to include("Total: 1 routes")
    end

    it "falls back to lightweight routes when Base64 fails" do
      # Base64 returns nil
      allow(client).to receive(:send_command)
        .with(/Base64/, timeout: 30)
        .and_return("=> nil")

      # Lightweight route count succeeds
      allow(client).to receive(:send_command)
        .with(/routes\.count/)
        .and_return('=> 3')
      # Lightweight route lines
      allow(client).to receive(:send_command)
        .with(/routes\.select.*join/)
        .and_return('=> "GET     /users users#index\nPOST    /users users#create\nGET     /users/:id users#show"')

      response = described_class.call(server_context: server_context)
      text = response_text(response)

      expect(text).to include("Routes:")
      expect(text).to include("users#index")
      expect(text).to include("Total: 3 routes")
    end

    it "shows 'no routes found' when routes are genuinely empty" do
      # Base64 returns nil
      allow(client).to receive(:send_command)
        .with(/Base64/, timeout: 30)
        .and_return("=> nil")

      # Lightweight: count succeeds with 0
      allow(client).to receive(:send_command)
        .with(/routes\.count/)
        .and_return('=> 0')
      # Lightweight: no route lines
      allow(client).to receive(:send_command)
        .with(/routes\.select.*join/)
        .and_return('=> ""')

      response = described_class.call(server_context: server_context)
      text = response_text(response)

      expect(text).to include("No routes found")
    end

    it "shows 'unavailable' when both approaches fail" do
      # Base64 fails
      allow(client).to receive(:send_command)
        .with(/Base64/, timeout: 30)
        .and_return("=> nil")

      # Lightweight also fails (eval returns nil)
      allow(client).to receive(:send_command)
        .with(/routes\.count/)
        .and_return("")

      response = described_class.call(server_context: server_context)
      text = response_text(response)

      expect(text).to include("Routes: unavailable")
    end

    it "shows trap context hint when unavailable in trap context" do
      allow(client).to receive(:send_command)
        .with(/Base64/, timeout: 30)
        .and_return("=> nil")
      allow(client).to receive(:send_command)
        .with(/routes\.count/)
        .and_return("")
      allow(client).to receive(:in_trap_context?).and_return(true)

      response = described_class.call(server_context: server_context)
      text = response_text(response)

      expect(text).to include("Routes: unavailable")
      expect(text).to include("trap context")
      expect(text).to include("trigger_request")
    end

    it "does not show trap context hint when not in trap context" do
      allow(client).to receive(:send_command)
        .with(/Base64/, timeout: 30)
        .and_return("=> nil")
      allow(client).to receive(:send_command)
        .with(/routes\.count/)
        .and_return("")
      allow(client).to receive(:in_trap_context?).and_return(false)

      response = described_class.call(server_context: server_context)
      text = response_text(response)

      expect(text).to include("Routes: unavailable")
      expect(text).not_to include("trap context")
    end

    it "does not apply filter when controller and path are nil" do
      # Verify the generated Base64 script has controller_filter = nil (not "nil" string)
      script = described_class.send(:build_routes_script, nil, nil)
      expect(script).to include("controller_filter = nil")
      expect(script).to include("path_filter = nil")
      expect(script).not_to match(/controller_filter = "nil"/)
      expect(script).not_to match(/path_filter = "nil"/)
    end

    it "filters by controller" do
      allow(client).to receive(:send_command)
        .with(/Base64/, timeout: 30)
        .and_return('=> "Routes (filtered by controller: \\"users\\"):\n  GET  /users  users#index\n\nTotal: 1 routes"')

      response = described_class.call(controller: "users", server_context: server_context)
      text = response_text(response)

      expect(text).to include("users")
    end

    it "filters by path" do
      allow(client).to receive(:send_command)
        .with(/Base64/, timeout: 30)
        .and_return('=> "Routes (filtered by path: \\"/api\\"):\n  GET  /api/status  api#status\n\nTotal: 1 routes"')

      response = described_class.call(path: "/api", server_context: server_context)
      text = response_text(response)

      expect(text).to include("/api")
    end

    it "handles non-Rails process" do
      allow(client).to receive(:send_command).with("p defined?(Rails)").and_return("=> nil")

      response = described_class.call(server_context: server_context)
      text = response_text(response)

      expect(text).to include("Error: Not a Rails application")
    end

    it "handles session error" do
      allow(manager).to receive(:client).and_raise(GirbMcp::SessionError, "No session")

      response = described_class.call(server_context: server_context)
      text = response_text(response)

      expect(text).to include("Error: No session")
    end
  end
end
