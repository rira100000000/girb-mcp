# frozen_string_literal: true

RSpec.describe GirbMcp::Tools::InspectObject do
  let(:client) { build_mock_client }
  let(:manager) { build_mock_manager(client: client) }
  let(:server_context) { { session_manager: manager } }

  describe ".call" do
    it "returns value, class, and instance variables" do
      allow(client).to receive(:send_command).with("pp user").and_return('#<User id: 1, name: "Alice">')
      allow(client).to receive(:send_command)
        .with("p [(user).class.to_s, (user).instance_variables]")
        .and_return('=> ["User", [:@id, :@name]]')

      response = described_class.call(expression: "user", server_context: server_context)
      text = response_text(response)
      expect(text).to include("Value:")
      expect(text).to include("User")
      expect(text).to include("Class: User")
      expect(text).to include("Instance variables: [:@id, :@name]")
    end

    it "handles timeout on meta query gracefully" do
      allow(client).to receive(:send_command).with("pp x").and_return("42")
      allow(client).to receive(:send_command)
        .with("p [(x).class.to_s, (x).instance_variables]")
        .and_raise(GirbMcp::TimeoutError, "timeout")

      response = described_class.call(expression: "x", server_context: server_context)
      text = response_text(response)
      expect(text).to include("Value:")
      expect(text).to include("42")
      expect(text).to include("Class: (timed out)")
      expect(text).to include("Instance variables: (timed out)")
    end

    it "handles unparseable meta output gracefully" do
      allow(client).to receive(:send_command).with("pp x").and_return("42")
      allow(client).to receive(:send_command)
        .with("p [(x).class.to_s, (x).instance_variables]")
        .and_return("=> something unexpected")

      response = described_class.call(expression: "x", server_context: server_context)
      text = response_text(response)
      expect(text).to include("Value:")
      expect(text).to include("Class: something unexpected")
    end

    it "handles session error" do
      allow(manager).to receive(:client).and_raise(GirbMcp::SessionError, "No session")

      response = described_class.call(expression: "x", server_context: server_context)
      text = response_text(response)
      expect(text).to include("Error: No session")
    end

    context "trap context annotation" do
      it "appends [trap context] when in trap context" do
        client_in_trap = build_mock_client(trap_context: true)
        manager_in_trap = build_mock_manager(client: client_in_trap)

        allow(client_in_trap).to receive(:send_command).with("pp user").and_return("42")
        allow(client_in_trap).to receive(:send_command)
          .with("p [(user).class.to_s, (user).instance_variables]")
          .and_return('=> ["Integer", []]')

        response = described_class.call(
          expression: "user",
          server_context: { session_manager: manager_in_trap },
        )
        text = response_text(response)
        expect(text).to include("[trap context]")
      end

      it "does not append [trap context] when not in trap context" do
        allow(client).to receive(:send_command).with("pp x").and_return("42")
        allow(client).to receive(:send_command)
          .with("p [(x).class.to_s, (x).instance_variables]")
          .and_return('=> ["Integer", []]')

        response = described_class.call(expression: "x", server_context: server_context)
        text = response_text(response)
        expect(text).not_to include("[trap context]")
      end
    end
  end
end
