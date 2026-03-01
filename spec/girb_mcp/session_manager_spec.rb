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

    it "has a recently reaped TTL of 10 minutes" do
      expect(GirbMcp::SessionManager::RECENTLY_REAPED_TTL).to eq(10 * 60)
    end
  end

  describe "#timeout" do
    it "returns the configured timeout" do
      expect(manager.timeout).to eq(3600)
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

    it "raises detailed error for recently reaped session (idle_timeout)" do
      reaped = manager.instance_variable_get(:@recently_reaped)
      reaped["session_42"] = { reason: :idle_timeout, pid: "42", reaped_at: Time.now - 120 }
      manager.instance_variable_set(:@default_session_id, "session_42")

      expect { manager.client("session_42") }.to raise_error(
        GirbMcp::SessionError, /inactivity.*2m ago.*Use 'connect'/
      )
    end

    it "raises detailed error for recently reaped session (process_died)" do
      reaped = manager.instance_variable_get(:@recently_reaped)
      reaped["session_99"] = { reason: :process_died, pid: "99", reaped_at: Time.now - 30 }

      expect { manager.client("session_99") }.to raise_error(
        GirbMcp::SessionError, /PID 99.*exited.*30s ago/
      )
    end

    it "raises detailed error for recently reaped session (socket_closed)" do
      reaped = manager.instance_variable_get(:@recently_reaped)
      reaped["session_77"] = { reason: :socket_closed, pid: "77", reaped_at: Time.now - 5 }

      expect { manager.client("session_77") }.to raise_error(
        GirbMcp::SessionError, /socket connection was lost.*5s ago/
      )
    end
  end

  describe "#connect (remote: passthrough)" do
    it "passes remote: true to DebugClient#connect" do
      new_client = build_mock_client(pid: "500")
      allow(GirbMcp::DebugClient).to receive(:new).and_return(new_client)
      allow(new_client).to receive(:connect).and_return({ success: true, pid: "500", output: "ok" })

      manager.connect(remote: true)

      expect(new_client).to have_received(:connect).with(hash_including(remote: true))
    end

    it "passes remote: false to DebugClient#connect" do
      new_client = build_mock_client(pid: "500")
      allow(GirbMcp::DebugClient).to receive(:new).and_return(new_client)
      allow(new_client).to receive(:connect).and_return({ success: true, pid: "500", output: "ok" })

      manager.connect(remote: false)

      expect(new_client).to have_received(:connect).with(hash_including(remote: false))
    end

    it "passes remote: nil by default" do
      new_client = build_mock_client(pid: "500")
      allow(GirbMcp::DebugClient).to receive(:new).and_return(new_client)
      allow(new_client).to receive(:connect).and_return({ success: true, pid: "500", output: "ok" })

      manager.connect

      expect(new_client).to have_received(:connect).with(hash_including(remote: nil))
    end
  end

  describe "#connect (pre_cleanup)" do
    it "disconnects existing session with the same PID before connecting" do
      old_client = build_mock_client(pid: "100")
      sessions = manager.instance_variable_get(:@sessions)
      sessions["session_100"] = GirbMcp::SessionManager::SessionInfo.new(
        client: old_client, connected_at: Time.now, last_activity_at: Time.now,
      )

      new_client = build_mock_client(pid: "100")
      allow(GirbMcp::DebugClient).to receive(:new).and_return(new_client)
      allow(new_client).to receive(:connect).and_return({ success: true, pid: "100", output: "ok" })

      manager.connect(pre_cleanup_pid: 100)

      expect(old_client).to have_received(:disconnect)
      expect(sessions).to have_key("session_100")
      expect(sessions["session_100"].client).to eq(new_client)
    end

    it "disconnects existing session with the same session_id before connecting" do
      old_client = build_mock_client(pid: "200")
      sessions = manager.instance_variable_get(:@sessions)
      sessions["my_session"] = GirbMcp::SessionManager::SessionInfo.new(
        client: old_client, connected_at: Time.now, last_activity_at: Time.now,
      )

      new_client = build_mock_client(pid: "300")
      allow(GirbMcp::DebugClient).to receive(:new).and_return(new_client)
      allow(new_client).to receive(:connect).and_return({ success: true, pid: "300", output: "ok" })

      manager.connect(session_id: "my_session")

      expect(old_client).to have_received(:disconnect)
      expect(sessions["my_session"].client).to eq(new_client)
    end

    it "does not affect sessions with different PIDs" do
      other_client = build_mock_client(pid: "300")
      sessions = manager.instance_variable_get(:@sessions)
      sessions["session_300"] = GirbMcp::SessionManager::SessionInfo.new(
        client: other_client, connected_at: Time.now, last_activity_at: Time.now,
      )

      new_client = build_mock_client(pid: "400")
      allow(GirbMcp::DebugClient).to receive(:new).and_return(new_client)
      allow(new_client).to receive(:connect).and_return({ success: true, pid: "400", output: "ok" })

      manager.connect(pre_cleanup_pid: 400)

      expect(other_client).not_to have_received(:disconnect)
      expect(sessions).to have_key("session_300")
    end

    it "disconnects existing session with the same port before connecting" do
      old_client = build_mock_client(pid: "100", port: 12345, remote: true)
      sessions = manager.instance_variable_get(:@sessions)
      sessions["session_100"] = GirbMcp::SessionManager::SessionInfo.new(
        client: old_client, connected_at: Time.now, last_activity_at: Time.now,
      )

      new_client = build_mock_client(pid: "200", port: 12345, remote: true)
      allow(GirbMcp::DebugClient).to receive(:new).and_return(new_client)
      allow(new_client).to receive(:connect).and_return({ success: true, pid: "200", output: "ok" })

      manager.connect(pre_cleanup_port: 12345)

      expect(old_client).to have_received(:disconnect)
      expect(sessions).not_to have_key("session_100")
    end

    it "does not affect sessions with different ports" do
      other_client = build_mock_client(pid: "300", port: 54321, remote: true)
      sessions = manager.instance_variable_get(:@sessions)
      sessions["session_300"] = GirbMcp::SessionManager::SessionInfo.new(
        client: other_client, connected_at: Time.now, last_activity_at: Time.now,
      )

      new_client = build_mock_client(pid: "400")
      allow(GirbMcp::DebugClient).to receive(:new).and_return(new_client)
      allow(new_client).to receive(:connect).and_return({ success: true, pid: "400", output: "ok" })

      manager.connect(pre_cleanup_port: 12345)

      expect(other_client).not_to have_received(:disconnect)
      expect(sessions).to have_key("session_300")
    end

    it "does not affect sessions with nil port" do
      other_client = build_mock_client(pid: "300")
      sessions = manager.instance_variable_get(:@sessions)
      sessions["session_300"] = GirbMcp::SessionManager::SessionInfo.new(
        client: other_client, connected_at: Time.now, last_activity_at: Time.now,
      )

      new_client = build_mock_client(pid: "400")
      allow(GirbMcp::DebugClient).to receive(:new).and_return(new_client)
      allow(new_client).to receive(:connect).and_return({ success: true, pid: "400", output: "ok" })

      manager.connect(pre_cleanup_port: 12345)

      expect(other_client).not_to have_received(:disconnect)
    end
  end

  describe "#connect (reconnect cleanup)" do
    it "cleans up old session with the same sid on reconnect" do
      old_client = build_mock_client(pid: "100")
      sessions = manager.instance_variable_get(:@sessions)
      sessions["session_100"] = GirbMcp::SessionManager::SessionInfo.new(
        client: old_client, connected_at: Time.now, last_activity_at: Time.now,
      )

      new_client = build_mock_client(pid: "100")
      allow(GirbMcp::DebugClient).to receive(:new).and_return(new_client)
      allow(new_client).to receive(:connect).and_return({ success: true, pid: "100", output: "ok" })

      manager.connect

      expect(old_client).to have_received(:disconnect)
      expect(sessions).to have_key("session_100")
      expect(sessions["session_100"].client).to eq(new_client)
    end

    it "cleans up old session with same PID but different sid" do
      old_client = build_mock_client(pid: "200")
      sessions = manager.instance_variable_get(:@sessions)
      sessions["custom_sid"] = GirbMcp::SessionManager::SessionInfo.new(
        client: old_client, connected_at: Time.now, last_activity_at: Time.now,
      )

      new_client = build_mock_client(pid: "200")
      allow(GirbMcp::DebugClient).to receive(:new).and_return(new_client)
      allow(new_client).to receive(:connect).and_return({ success: true, pid: "200", output: "ok" })

      manager.connect

      expect(old_client).to have_received(:disconnect)
      expect(sessions).not_to have_key("custom_sid")
      expect(sessions).to have_key("session_200")
    end

    it "does not clean up sessions with different PIDs" do
      other_client = build_mock_client(pid: "300")
      sessions = manager.instance_variable_get(:@sessions)
      sessions["session_300"] = GirbMcp::SessionManager::SessionInfo.new(
        client: other_client, connected_at: Time.now, last_activity_at: Time.now,
      )

      new_client = build_mock_client(pid: "400")
      allow(GirbMcp::DebugClient).to receive(:new).and_return(new_client)
      allow(new_client).to receive(:connect).and_return({ success: true, pid: "400", output: "ok" })

      manager.connect

      expect(other_client).not_to have_received(:disconnect)
      expect(sessions).to have_key("session_300")
      expect(sessions).to have_key("session_400")
    end
  end

  describe "#connect (block passthrough)" do
    it "passes block to DebugClient#connect as on_initial_timeout" do
      new_client = build_mock_client(pid: "500")
      allow(GirbMcp::DebugClient).to receive(:new).and_return(new_client)

      block_received = false
      allow(new_client).to receive(:connect) do |**_kwargs, &block|
        block_received = !block.nil?
        { success: true, pid: "500", output: "ok" }
      end

      manager.connect { "wake!" }

      expect(block_received).to be true
    end

    it "passes connect_timeout to DebugClient#connect" do
      new_client = build_mock_client(pid: "501")
      allow(GirbMcp::DebugClient).to receive(:new).and_return(new_client)

      received_timeout = nil
      allow(new_client).to receive(:connect) do |**kwargs, &_block|
        received_timeout = kwargs[:connect_timeout]
        { success: true, pid: "501", output: "ok" }
      end

      manager.connect(connect_timeout: 5)

      expect(received_timeout).to eq(5)
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

    it "includes timeout_seconds in each entry" do
      client = build_mock_client
      sessions = manager.instance_variable_get(:@sessions)
      sessions["test"] = GirbMcp::SessionManager::SessionInfo.new(
        client: client, connected_at: Time.now, last_activity_at: Time.now,
      )

      result = manager.active_sessions
      expect(result.first[:timeout_seconds]).to eq(3600)
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

  describe "#acknowledge_warning / #acknowledged_warnings" do
    it "records acknowledged warning categories for a session" do
      client = build_mock_client(connected: true, pid: "777")
      sessions = manager.instance_variable_get(:@sessions)
      sessions["sess_777"] = GirbMcp::SessionManager::SessionInfo.new(
        client: client, connected_at: Time.now, last_activity_at: Time.now,
        acknowledged_warnings: Set.new,
      )

      manager.acknowledge_warning("sess_777", :mutation_operations)
      ack = manager.acknowledged_warnings("sess_777")

      expect(ack).to include(:mutation_operations)
    end

    it "returns empty set for unknown session" do
      expect(manager.acknowledged_warnings("nonexistent")).to eq(Set.new)
    end

    it "clears acknowledged warnings on disconnect" do
      client = build_mock_client(connected: true, pid: "778")
      sessions = manager.instance_variable_get(:@sessions)
      sessions["sess_778"] = GirbMcp::SessionManager::SessionInfo.new(
        client: client, connected_at: Time.now, last_activity_at: Time.now,
        acknowledged_warnings: Set.new,
      )

      manager.acknowledge_warning("sess_778", :mutation_operations)
      manager.disconnect("sess_778")

      expect(manager.acknowledged_warnings("sess_778")).to eq(Set.new)
    end
  end

  describe "recently_reaped tracking" do
    it "records reaped sessions in reap_stale_sessions" do
      client = build_mock_client(connected: true, pid: "555")
      allow(client).to receive(:connected?).and_return(true)

      sessions = manager.instance_variable_get(:@sessions)
      sessions["stale_session"] = GirbMcp::SessionManager::SessionInfo.new(
        client: client, connected_at: Time.now, last_activity_at: Time.now - 7200,
      )

      allow(manager).to receive(:process_alive?).and_return(true)

      manager.send(:reap_stale_sessions)

      reaped = manager.instance_variable_get(:@recently_reaped)
      expect(reaped).to have_key("stale_session")
      expect(reaped["stale_session"][:reason]).to eq(:idle_timeout)
      expect(reaped["stale_session"][:pid]).to eq("555")
    end

    it "records process_died reason" do
      client = build_mock_client(connected: true, pid: "666")
      allow(client).to receive(:connected?).and_return(true)

      sessions = manager.instance_variable_get(:@sessions)
      sessions["dead_session"] = GirbMcp::SessionManager::SessionInfo.new(
        client: client, connected_at: Time.now, last_activity_at: Time.now,
      )

      allow(manager).to receive(:process_alive?).and_return(false)

      manager.send(:reap_stale_sessions)

      reaped = manager.instance_variable_get(:@recently_reaped)
      expect(reaped["dead_session"][:reason]).to eq(:process_died)
    end

    it "records socket_closed reason" do
      client = build_mock_client(connected: false, pid: "777")

      sessions = manager.instance_variable_get(:@sessions)
      sessions["closed_session"] = GirbMcp::SessionManager::SessionInfo.new(
        client: client, connected_at: Time.now, last_activity_at: Time.now,
      )

      allow(manager).to receive(:process_alive?).and_return(true)

      manager.send(:reap_stale_sessions)

      reaped = manager.instance_variable_get(:@recently_reaped)
      expect(reaped["closed_session"][:reason]).to eq(:socket_closed)
    end

    it "cleans up expired entries from recently_reaped" do
      reaped = manager.instance_variable_get(:@recently_reaped)
      reaped["old_session"] = { reason: :idle_timeout, pid: "111", reaped_at: Time.now - 700 }
      reaped["recent_session"] = { reason: :process_died, pid: "222", reaped_at: Time.now - 10 }

      manager.send(:cleanup_recently_reaped, Time.now)

      expect(reaped).to have_key("recent_session")
      expect(reaped).not_to have_key("old_session")
    end

    it "records reaped sessions in cleanup_dead_sessions" do
      client = build_mock_client(connected: false, pid: "888")

      sessions = manager.instance_variable_get(:@sessions)
      sessions["dead"] = GirbMcp::SessionManager::SessionInfo.new(
        client: client, connected_at: Time.now, last_activity_at: Time.now,
      )

      allow(manager).to receive(:process_alive?).and_return(true)

      manager.cleanup_dead_sessions

      reaped = manager.instance_variable_get(:@recently_reaped)
      expect(reaped).to have_key("dead")
      expect(reaped["dead"][:reason]).to eq(:socket_closed)
    end
  end

  describe "#resume_before_disconnect (private)" do
    it "deletes breakpoints then continues for connect sessions" do
      client = build_mock_client
      bp_output = "#0  BP - Line  app/models/user.rb:10\n" \
                  "#2  BP - Line  app/models/user.rb:30\n"
      allow(client).to receive(:send_command).with("info breakpoints", timeout: anything).and_return(bp_output)
      allow(client).to receive(:send_command).with("delete 0", timeout: anything).and_return("")
      allow(client).to receive(:send_command).with("delete 2", timeout: anything).and_return("")

      info = GirbMcp::SessionManager::SessionInfo.new(
        client: client, connected_at: Time.now, last_activity_at: Time.now,
      )

      manager.send(:resume_before_disconnect, info)

      expect(client).to have_received(:send_command).with("info breakpoints", timeout: anything)
      expect(client).to have_received(:send_command).with("delete 0", timeout: anything)
      expect(client).to have_received(:send_command).with("delete 2", timeout: anything)
      expect(client).to have_received(:send_command_no_wait).with("c", force: true)
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

    it "tries repause when client is not paused" do
      client = build_mock_client(paused: false)
      allow(client).to receive(:repause).with(timeout: 3).and_return("")
      # After repause, still not paused (repause failed to change state)
      allow(client).to receive(:paused).and_return(false)

      info = GirbMcp::SessionManager::SessionInfo.new(
        client: client, connected_at: Time.now, last_activity_at: Time.now,
      )

      manager.send(:resume_before_disconnect, info)

      expect(client).to have_received(:repause).with(timeout: 3)
      expect(client).not_to have_received(:send_command)
      expect(client).not_to have_received(:send_command_no_wait)
    end

    it "proceeds with cleanup when repause succeeds for not-paused client" do
      client = build_mock_client(paused: false)
      allow(client).to receive(:repause).with(timeout: 3).and_return("")
      # After repause, client is paused
      allow(client).to receive(:paused).and_return(false, true)

      info = GirbMcp::SessionManager::SessionInfo.new(
        client: client, connected_at: Time.now, last_activity_at: Time.now,
      )

      manager.send(:resume_before_disconnect, info)

      expect(client).to have_received(:repause).with(timeout: 3)
      expect(client).to have_received(:send_command_no_wait).with("c", force: true)
    end

    it "continues even when BP info fails" do
      client = build_mock_client
      allow(client).to receive(:send_command).with("info breakpoints", timeout: anything).and_raise(
        GirbMcp::TimeoutError, "timeout"
      )

      info = GirbMcp::SessionManager::SessionInfo.new(
        client: client, connected_at: Time.now, last_activity_at: Time.now,
      )

      manager.send(:resume_before_disconnect, info)

      expect(client).to have_received(:send_command_no_wait).with("c", force: true)
    end
  end
end
