# frozen_string_literal: true

RSpec.describe GirbMcp::Tools::Connect do
  let(:client) { build_mock_client }
  let(:manager) { build_mock_manager(client: client) }
  let(:server_context) { { session_manager: manager } }

  describe ".call" do
    it "connects and returns session info" do
      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Connected to debug session")
      expect(text).to include("Session ID:")
      expect(text).to include("PID:")
    end

    it "clears breakpoint specs by default" do
      expect(manager).to receive(:clear_breakpoint_specs)
      described_class.call(server_context: server_context)
    end

    it "does not clear breakpoint specs when restore_breakpoints is true" do
      expect(manager).not_to receive(:clear_breakpoint_specs)
      described_class.call(restore_breakpoints: true, server_context: server_context)
    end

    it "passes connection parameters" do
      expect(manager).to receive(:connect).with(
        session_id: "my_session",
        path: "/tmp/sock",
        host: nil,
        port: nil,
      ).and_return({ success: true, pid: "111", output: "ok", session_id: "my_session" })

      described_class.call(
        path: "/tmp/sock",
        session_id: "my_session",
        server_context: server_context,
      )
    end

    it "shows restored breakpoints" do
      allow(manager).to receive(:restore_breakpoints).and_return([
        { spec: "break file.rb:10", output: "#1 BP - Line file.rb:10" },
      ])

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Restored 1 breakpoint(s)")
      expect(text).to include("break file.rb:10")
    end

    it "shows restore errors" do
      allow(manager).to receive(:restore_breakpoints).and_return([
        { spec: "break missing.rb:10", error: "File not found" },
      ])

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Error: File not found")
    end

    it "handles connection errors" do
      allow(manager).to receive(:connect).and_raise(
        GirbMcp::ConnectionError, "Connection refused"
      )

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Error: Connection refused")
    end

    it "includes stdout/stderr capture note" do
      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("stdout/stderr are not captured")
    end
  end
end
