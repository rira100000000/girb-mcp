# frozen_string_literal: true

RSpec.describe GirbMcp::Tools::Disconnect do
  let(:client) { build_mock_client }
  let(:manager) { build_mock_manager(client: client) }
  let(:server_context) { { session_manager: manager } }

  describe ".call" do
    it "disconnects and returns confirmation" do
      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Disconnected from session")
    end

    it "returns message when no active session" do
      allow(manager).to receive(:client).and_raise(
        GirbMcp::SessionError, "No active session"
      )

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("No active session to disconnect")
    end

    it "kills process for run_script sessions" do
      wait_thread = instance_double(Thread, alive?: true)
      allow(client).to receive(:wait_thread).and_return(wait_thread)
      allow(client).to receive(:pid).and_return("999")
      allow(Process).to receive(:kill)

      response = described_class.call(server_context: server_context)
      text = response_text(response)

      expect(Process).to have_received(:kill).with("TERM", 999)
      expect(text).to include("Process 999 terminated")
    end

    it "handles already-exited process gracefully" do
      wait_thread = instance_double(Thread, alive?: true)
      allow(client).to receive(:wait_thread).and_return(wait_thread)
      allow(client).to receive(:pid).and_return("999")
      allow(Process).to receive(:kill).and_raise(Errno::ESRCH)

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Disconnected from session")
      expect(text).not_to include("terminated")
    end

    it "suggests next steps" do
      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("run_script")
      expect(text).to include("connect")
    end
  end
end
