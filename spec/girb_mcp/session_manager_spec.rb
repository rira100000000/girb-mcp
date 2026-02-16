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

    it "sends BP deletion and flush for connect sessions" do
      socket = instance_double(IO)
      allow(socket).to receive(:closed?).and_return(false)
      allow(socket).to receive(:write)
      allow(socket).to receive(:flush)

      client = instance_double(GirbMcp::DebugClient,
        wait_thread: nil,
        pid: "999",
        connected?: true,
      )
      allow(client).to receive(:instance_variable_get).with(:@socket).and_return(socket)
      allow(client).to receive(:disconnect)

      # Inject session directly
      sessions = manager.instance_variable_get(:@sessions)
      sessions["test"] = GirbMcp::SessionManager::SessionInfo.new(
        client: client, connected_at: Time.now, last_activity_at: Time.now,
      )
      manager.instance_variable_set(:@default_session_id, "test")

      manager.disconnect_all

      # Verify BP deletion commands (#9 down to #0) + continue + flush
      (0..9).each do |n|
        expect(socket).to have_received(:write).with("command 999 500 delete #{n}\n".b)
      end
      expect(socket).to have_received(:write).with("command 999 500 c\n".b)
      expect(socket).to have_received(:flush)
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

  describe "#resume_before_disconnect (private)" do
    it "deletes breakpoints then continues for connect sessions" do
      client = build_mock_client
      bp_output = "#0  BP - Line  app/models/user.rb:10\n" \
                  "#2  BP - Line  app/models/user.rb:30\n"
      allow(client).to receive(:send_command).with("info breakpoints", timeout: 3).and_return(bp_output)
      allow(client).to receive(:send_command).with("delete 0", timeout: 3).and_return("")
      allow(client).to receive(:send_command).with("delete 2", timeout: 3).and_return("")

      info = GirbMcp::SessionManager::SessionInfo.new(
        client: client, connected_at: Time.now, last_activity_at: Time.now,
      )

      manager.send(:resume_before_disconnect, info)

      expect(client).to have_received(:send_command).with("info breakpoints", timeout: 3)
      expect(client).to have_received(:send_command).with("delete 0", timeout: 3)
      expect(client).to have_received(:send_command).with("delete 2", timeout: 3)
      expect(client).to have_received(:send_command_no_wait).with("c")
    end

    it "skips when client has wait_thread (run_script session)" do
      client = build_mock_client
      wait_thread = instance_double(Thread)
      allow(client).to receive(:wait_thread).and_return(wait_thread)

      info = GirbMcp::SessionManager::SessionInfo.new(
        client: client, connected_at: Time.now, last_activity_at: Time.now,
      )

      manager.send(:resume_before_disconnect, info)

      expect(client).not_to have_received(:send_command)
      expect(client).not_to have_received(:send_command_no_wait)
    end

    it "continues even when BP info fails" do
      client = build_mock_client
      allow(client).to receive(:send_command).with("info breakpoints", timeout: 3).and_raise(
        GirbMcp::TimeoutError, "timeout"
      )

      info = GirbMcp::SessionManager::SessionInfo.new(
        client: client, connected_at: Time.now, last_activity_at: Time.now,
      )

      manager.send(:resume_before_disconnect, info)

      expect(client).to have_received(:send_command_no_wait).with("c")
    end
  end
end
