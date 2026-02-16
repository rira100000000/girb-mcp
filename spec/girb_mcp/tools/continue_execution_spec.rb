# frozen_string_literal: true

RSpec.describe GirbMcp::Tools::ContinueExecution do
  let(:client) { build_mock_client }
  let(:manager) { build_mock_manager(client: client) }
  let(:server_context) { { session_manager: manager } }

  describe ".call" do
    it "resumes execution and returns output" do
      allow(client).to receive(:send_continue).and_return(
        "Stop by #1  BP - Line  file.rb:10 (line)\n=> 10| x = 1"
      )

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Execution resumed")
      expect(text).to include("file.rb:10")
    end

    it "detects program exit on empty output" do
      allow(client).to receive(:send_continue).and_return("")
      allow(client).to receive(:process_finished?).and_return(true)

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Program finished")
    end

    it "cleans up one-shot breakpoints" do
      allow(client).to receive(:send_continue).and_return("Stop by #3  BP - Line  f.rb:5 (line)")
      expect(client).to receive(:cleanup_one_shot_breakpoints)

      described_class.call(server_context: server_context)
    end

    it "annotates breakpoint hit events" do
      allow(client).to receive(:send_continue).and_return(
        "Stop by #1  BP - Line  f.rb:10 (return)"
      )

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Stop event (return)")
    end

    it "handles SessionError for ended sessions" do
      allow(client).to receive(:send_continue).and_raise(
        GirbMcp::SessionError.new("session ended", final_output: "last output")
      )

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Program finished")
    end

    it "handles SessionError for other errors" do
      allow(client).to receive(:send_continue).and_raise(
        GirbMcp::SessionError.new("Some other error")
      )

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Error: Some other error")
    end

    context "when TimeoutError occurs" do
      before do
        allow(client).to receive(:send_continue).and_raise(
          GirbMcp::TimeoutError, "timeout"
        )
      end

      it "shows 'no breakpoint hit' when breakpoints exist" do
        allow(client).to receive(:send_command)
          .with("info breakpoints")
          .and_return("#1  BP - Line  file.rb:10 (line)")

        response = described_class.call(server_context: server_context)
        text = response_text(response)
        expect(text).to include("no breakpoint was hit")
        expect(text).to include("still running")
      end

      it "shows 'resumed successfully' when no breakpoints" do
        allow(client).to receive(:send_command)
          .with("info breakpoints")
          .and_return("No breakpoints")

        response = described_class.call(server_context: server_context)
        text = response_text(response)
        expect(text).to include("resumed successfully")
        expect(text).to include("no breakpoints set")
      end
    end

    it "handles ConnectionError for lost connection" do
      allow(client).to receive(:send_continue).and_raise(
        GirbMcp::ConnectionError.new("Connection lost", final_output: "output")
      )

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Program finished")
    end

    it "handles ConnectionError for other errors" do
      allow(client).to receive(:send_continue).and_raise(
        GirbMcp::ConnectionError.new("Connection refused")
      )

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Error: Connection refused")
    end
  end
end
