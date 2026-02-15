# frozen_string_literal: true

RSpec.describe GirbMcp::Tools::ListDebugSessions do
  let(:server_context) { { session_manager: build_mock_manager } }

  describe ".call" do
    it "shows message when no sessions found" do
      allow(GirbMcp::DebugClient).to receive(:list_sessions).and_return([])

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("No debug sessions found")
      expect(text).to include("rdbg --open")
    end

    it "lists found sessions" do
      sessions = [
        { pid: 1234, name: "test_script", path: "/tmp/rdbg-1000/rdbg-1234" },
        { pid: 5678, name: nil, path: "/tmp/rdbg-1000/rdbg-5678" },
      ]
      allow(GirbMcp::DebugClient).to receive(:list_sessions).and_return(sessions)

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Found 2 debug session(s)")
      expect(text).to include("PID 1234")
      expect(text).to include("(test_script)")
      expect(text).to include("PID 5678")
    end

    it "omits name when nil" do
      sessions = [{ pid: 1234, name: nil, path: "/tmp/rdbg-1000/rdbg-1234" }]
      allow(GirbMcp::DebugClient).to receive(:list_sessions).and_return(sessions)

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("PID 1234")
      expect(text).not_to include("()")
    end
  end
end
