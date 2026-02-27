# frozen_string_literal: true

RSpec.describe GirbMcp::Tools::ListDebugSessions do
  let(:server_context) { { session_manager: build_mock_manager } }

  before do
    allow(GirbMcp::TcpSessionDiscovery).to receive(:discover).and_return([])
  end

  describe ".call" do
    it "shows message when no sessions found" do
      allow(GirbMcp::DebugClient).to receive(:list_sessions).and_return([])

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("No debug sessions found")
      expect(text).to include("rdbg --open")
    end

    it "includes Docker instructions when no sessions found" do
      allow(GirbMcp::DebugClient).to receive(:list_sessions).and_return([])

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("For Docker containers:")
      expect(text).to include("RUBY_DEBUG_PORT")
    end

    it "lists found unix sessions" do
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

    it "lists TCP sessions from Docker" do
      allow(GirbMcp::DebugClient).to receive(:list_sessions).and_return([])
      allow(GirbMcp::TcpSessionDiscovery).to receive(:discover).and_return([
        { host: "localhost", port: 12345, name: "myapp", source: :docker },
      ])

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Found 1 debug session(s)")
      expect(text).to include('Docker "myapp": localhost:12345')
      expect(text).to include("connect with port: 12345")
    end

    it "lists TCP sessions from local processes" do
      allow(GirbMcp::DebugClient).to receive(:list_sessions).and_return([])
      allow(GirbMcp::TcpSessionDiscovery).to receive(:discover).and_return([
        { host: "localhost", port: 54321, name: "rails", source: :local },
      ])

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Found 1 debug session(s)")
      expect(text).to include('TCP "rails": localhost:54321')
      expect(text).to include("connect with port: 54321")
    end

    it "shows combined unix and TCP sessions" do
      unix_sessions = [
        { pid: 1234, name: "script", path: "/tmp/rdbg-1000/rdbg-1234" },
      ]
      tcp_sessions = [
        { host: "localhost", port: 12345, name: "myapp", source: :docker },
      ]
      allow(GirbMcp::DebugClient).to receive(:list_sessions).and_return(unix_sessions)
      allow(GirbMcp::TcpSessionDiscovery).to receive(:discover).and_return(tcp_sessions)

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Found 2 debug session(s)")
      expect(text).to include("PID 1234")
      expect(text).to include('Docker "myapp"')
    end
  end
end
