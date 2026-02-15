# frozen_string_literal: true

RSpec.describe GirbMcp::Tools::InspectObject do
  let(:client) { build_mock_client }
  let(:manager) { build_mock_manager(client: client) }
  let(:server_context) { { session_manager: manager } }

  describe ".call" do
    it "returns value, class, and instance variables" do
      allow(client).to receive(:send_command).with("pp user").and_return('#<User id: 1, name: "Alice">')
      allow(client).to receive(:send_command).with("p user.class").and_return("=> User")
      allow(client).to receive(:send_command).with("p user.instance_variables").and_return("=> [:@id, :@name]")

      response = described_class.call(expression: "user", server_context: server_context)
      text = response_text(response)
      expect(text).to include("Value:")
      expect(text).to include("User")
      expect(text).to include("Class:")
      expect(text).to include("Instance variables:")
      expect(text).to include(":@id")
    end

    it "handles timeout on class query gracefully" do
      allow(client).to receive(:send_command).with("pp x").and_return("42")
      allow(client).to receive(:send_command).with("p x.class").and_raise(GirbMcp::TimeoutError, "timeout")
      allow(client).to receive(:send_command).with("p x.instance_variables").and_return("=> []")

      response = described_class.call(expression: "x", server_context: server_context)
      text = response_text(response)
      expect(text).to include("Value:")
      expect(text).to include("42")
      expect(text).to include("Class: (timed out)")
    end

    it "handles session error" do
      allow(manager).to receive(:client).and_raise(GirbMcp::SessionError, "No session")

      response = described_class.call(expression: "x", server_context: server_context)
      text = response_text(response)
      expect(text).to include("Error: No session")
    end
  end
end
