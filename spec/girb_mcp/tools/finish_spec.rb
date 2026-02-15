# frozen_string_literal: true

RSpec.describe GirbMcp::Tools::Finish do
  let(:client) { build_mock_client }
  let(:manager) { build_mock_manager(client: client) }
  let(:server_context) { { session_manager: manager } }

  describe ".call" do
    it "runs until method returns" do
      allow(client).to receive(:send_command)
        .with("finish", timeout: GirbMcp::DebugClient::CONTINUE_TIMEOUT)
        .and_return("Stop at caller frame\n=> 5| result = foo()")

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Method/block returned")
      expect(text).to include("caller's frame")
    end

    it "detects program exit" do
      allow(client).to receive(:send_command)
        .with("finish", timeout: GirbMcp::DebugClient::CONTINUE_TIMEOUT)
        .and_return("")
      allow(client).to receive(:process_finished?).and_return(true)

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Program exited during finish")
    end

    it "handles SessionError for ended sessions" do
      allow(client).to receive(:send_command)
        .with("finish", timeout: GirbMcp::DebugClient::CONTINUE_TIMEOUT)
        .and_raise(GirbMcp::SessionError.new("finished execution", final_output: "last"))

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Program exited during finish")
    end

    it "handles ConnectionError for lost connections" do
      allow(client).to receive(:send_command)
        .with("finish", timeout: GirbMcp::DebugClient::CONTINUE_TIMEOUT)
        .and_raise(GirbMcp::ConnectionError.new("Connection lost", final_output: "output"))

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Program exited during finish")
    end

    it "handles generic error" do
      allow(manager).to receive(:client).and_raise(GirbMcp::SessionError, "No session")

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Error: No session")
    end
  end
end
