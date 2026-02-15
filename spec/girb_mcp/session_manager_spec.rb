# frozen_string_literal: true

RSpec.describe GirbMcp::SessionManager do
  let(:manager) { GirbMcp::SessionManager.new(timeout: 3600) }

  after do
    manager.disconnect_all
  end

  describe "constants" do
    it "has a default timeout of 30 minutes" do
      expect(GirbMcp::SessionManager::DEFAULT_TIMEOUT).to eq(30 * 60)
    end

    it "has a reaper interval of 60 seconds" do
      expect(GirbMcp::SessionManager::REAPER_INTERVAL).to eq(60)
    end
  end

  describe "#client" do
    it "raises SessionError when no sessions" do
      expect { manager.client }.to raise_error(
        GirbMcp::SessionError, /No active debug session/
      )
    end

    it "raises SessionError for unknown session_id" do
      expect { manager.client("nonexistent") }.to raise_error(
        GirbMcp::SessionError, /not found/
      )
    end
  end

  describe "#disconnect" do
    it "does nothing when no sessions" do
      expect { manager.disconnect }.not_to raise_error
    end
  end

  describe "#disconnect_all" do
    it "clears all sessions" do
      manager.disconnect_all
      expect(manager.active_sessions).to be_empty
    end
  end

  describe "#active_sessions" do
    it "returns empty array when no sessions" do
      expect(manager.active_sessions).to eq([])
    end
  end

  describe "#record_breakpoint" do
    it "records a breakpoint spec" do
      manager.record_breakpoint("break file.rb:10")
      # Verify by restoring to a mock client
      client = build_mock_client
      allow(client).to receive(:send_command).and_return("#1  BP - Line  file.rb:10")
      results = manager.restore_breakpoints(client)
      expect(results.size).to eq(1)
      expect(results.first[:spec]).to eq("break file.rb:10")
    end

    it "does not record duplicates" do
      manager.record_breakpoint("break file.rb:10")
      manager.record_breakpoint("break file.rb:10")
      client = build_mock_client
      allow(client).to receive(:send_command).and_return("#1  BP - Line")
      results = manager.restore_breakpoints(client)
      expect(results.size).to eq(1)
    end
  end

  describe "#clear_breakpoint_specs" do
    it "clears all recorded breakpoints" do
      manager.record_breakpoint("break file.rb:10")
      manager.clear_breakpoint_specs
      client = build_mock_client
      results = manager.restore_breakpoints(client)
      expect(results).to be_empty
    end
  end

  describe "#remove_breakpoint_specs_matching" do
    it "removes specs matching pattern" do
      manager.record_breakpoint("break file.rb:10")
      manager.record_breakpoint("break other.rb:20")
      manager.remove_breakpoint_specs_matching("file.rb:10")

      client = build_mock_client
      allow(client).to receive(:send_command).and_return("#1  BP")
      results = manager.restore_breakpoints(client)
      expect(results.size).to eq(1)
      expect(results.first[:spec]).to eq("break other.rb:20")
    end
  end

  describe "#restore_breakpoints" do
    it "returns empty array when no specs recorded" do
      client = build_mock_client
      expect(manager.restore_breakpoints(client)).to eq([])
    end

    it "handles errors from send_command" do
      manager.record_breakpoint("break file.rb:10")
      client = build_mock_client
      allow(client).to receive(:send_command).and_raise(GirbMcp::ConnectionError, "lost")

      results = manager.restore_breakpoints(client)
      expect(results.size).to eq(1)
      expect(results.first[:error]).to include("lost")
    end
  end

  describe "#cleanup_dead_sessions" do
    it "returns empty array when no sessions" do
      expect(manager.cleanup_dead_sessions).to eq([])
    end
  end
end
