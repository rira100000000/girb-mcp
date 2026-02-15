# frozen_string_literal: true

RSpec.describe GirbMcp::Tools::Next do
  let(:client) { build_mock_client }
  let(:manager) { build_mock_manager(client: client) }
  let(:server_context) { { session_manager: manager } }

  describe ".call" do
    it "steps over and returns output" do
      allow(client).to receive(:send_command).with("next").and_return(
        "Stop by #1  BP - Line  file.rb:11 (line)\n=> 11| z = 3"
      )

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("file.rb:11")
    end

    it "detects program exit" do
      allow(client).to receive(:send_command).with("next").and_return("")
      allow(client).to receive(:process_finished?).and_return(true)

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Program exited during step")
    end

    it "handles SessionError for ended sessions" do
      allow(client).to receive(:send_command).with("next").and_raise(
        GirbMcp::SessionError.new("session ended", final_output: "last")
      )

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Program exited during step")
    end

    it "handles ConnectionError for lost connections" do
      allow(client).to receive(:send_command).with("next").and_raise(
        GirbMcp::ConnectionError.new("connection closed", final_output: "output")
      )

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Program exited during step")
    end

    it "handles generic error" do
      allow(manager).to receive(:client).and_raise(GirbMcp::SessionError, "No session")

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Error: No session")
    end
  end
end
