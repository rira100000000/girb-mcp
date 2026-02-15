# frozen_string_literal: true

RSpec.describe GirbMcp::Tools::RunDebugCommand do
  let(:client) { build_mock_client }
  let(:manager) { build_mock_manager(client: client) }
  let(:server_context) { { session_manager: manager } }

  describe ".call" do
    it "executes raw debugger command" do
      allow(client).to receive(:send_command).with("info threads").and_return("Thread #1")

      response = described_class.call(command: "info threads", server_context: server_context)
      text = response_text(response)
      expect(text).to include("Thread #1")
    end

    it "tracks catch breakpoints for preservation" do
      allow(client).to receive(:send_command).with("catch RuntimeError").and_return('#1  BP - Catch  "RuntimeError"')
      expect(manager).to receive(:record_breakpoint).with("catch RuntimeError")

      described_class.call(command: "catch RuntimeError", server_context: server_context)
    end

    it "does not record non-catch commands" do
      allow(client).to receive(:send_command).with("up").and_return("frame moved")
      expect(manager).not_to receive(:record_breakpoint)

      described_class.call(command: "up", server_context: server_context)
    end

    it "handles session error" do
      allow(manager).to receive(:client).and_raise(GirbMcp::SessionError, "No session")

      response = described_class.call(command: "info", server_context: server_context)
      text = response_text(response)
      expect(text).to include("Error: No session")
    end
  end
end
