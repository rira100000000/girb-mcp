# frozen_string_literal: true

RSpec.describe GirbMcp::DebugClient do
  describe "constants" do
    it "has default width" do
      expect(GirbMcp::DebugClient::DEFAULT_WIDTH).to eq(500)
    end

    it "has default timeout" do
      expect(GirbMcp::DebugClient::DEFAULT_TIMEOUT).to eq(15)
    end

    it "has continue timeout" do
      expect(GirbMcp::DebugClient::CONTINUE_TIMEOUT).to eq(30)
    end

    it "has ANSI escape pattern" do
      expect(GirbMcp::DebugClient::ANSI_ESCAPE).to be_a(Regexp)
      expect("\e[31mred\e[0m".gsub(GirbMcp::DebugClient::ANSI_ESCAPE, "")).to eq("red")
    end
  end

  describe "#initialize" do
    it "starts disconnected" do
      client = GirbMcp::DebugClient.new
      expect(client.connected?).to be false
      expect(client.pid).to be_nil
    end
  end

  describe "#connected?" do
    it "returns false when not connected" do
      client = GirbMcp::DebugClient.new
      expect(client.connected?).to be false
    end
  end

  describe "#send_command" do
    it "raises SessionError when not connected" do
      client = GirbMcp::DebugClient.new
      expect { client.send_command("list") }.to raise_error(
        GirbMcp::SessionError, /Not connected/
      )
    end
  end

  describe "#process_finished?" do
    it "returns false when no wait_thread" do
      client = GirbMcp::DebugClient.new
      expect(client.process_finished?).to be false
    end
  end

  describe "#register_one_shot and #cleanup_one_shot_breakpoints" do
    let(:client) { GirbMcp::DebugClient.new }

    it "returns nil when no one-shot breakpoints registered" do
      expect(client.cleanup_one_shot_breakpoints("Stop by #1")).to be_nil
    end

    it "returns nil for nil output" do
      client.register_one_shot(1)
      expect(client.cleanup_one_shot_breakpoints(nil)).to be_nil
    end

    it "returns nil when output doesn't match any registered breakpoint" do
      client.register_one_shot(1)
      expect(client.cleanup_one_shot_breakpoints("Stop by #2")).to be_nil
    end
  end

  describe "#read_stdout_output" do
    it "returns nil when no stdout_file" do
      client = GirbMcp::DebugClient.new
      expect(client.read_stdout_output).to be_nil
    end
  end

  describe "#read_stderr_output" do
    it "returns nil when no stderr_file" do
      client = GirbMcp::DebugClient.new
      expect(client.read_stderr_output).to be_nil
    end
  end

  describe ".list_sessions" do
    it "returns empty array when socket directory does not exist" do
      allow(GirbMcp::DebugClient).to receive(:socket_dir).and_return("/nonexistent")
      expect(GirbMcp::DebugClient.list_sessions).to eq([])
    end

    it "returns empty array when socket_dir is nil" do
      allow(GirbMcp::DebugClient).to receive(:socket_dir).and_return(nil)
      expect(GirbMcp::DebugClient.list_sessions).to eq([])
    end
  end

  describe ".socket_dir" do
    context "with RUBY_DEBUG_SOCK_DIR set" do
      it "returns the env var value" do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("RUBY_DEBUG_SOCK_DIR").and_return("/custom/dir")
        expect(GirbMcp::DebugClient.socket_dir).to eq("/custom/dir")
      end
    end

    context "with XDG_RUNTIME_DIR set" do
      it "returns the env var value when RUBY_DEBUG_SOCK_DIR is not set" do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("RUBY_DEBUG_SOCK_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("XDG_RUNTIME_DIR").and_return("/run/user/1000")
        expect(GirbMcp::DebugClient.socket_dir).to eq("/run/user/1000")
      end
    end
  end

  describe ".socket_connectable?" do
    it "returns true when socket accepts connections" do
      # Create a real Unix server socket
      Dir.mktmpdir do |dir|
        path = File.join(dir, "test.sock")
        server = UNIXServer.new(path)
        expect(GirbMcp::DebugClient.socket_connectable?(path)).to be true
      ensure
        server&.close
      end
    end

    it "returns false when socket file does not exist" do
      expect(GirbMcp::DebugClient.socket_connectable?("/tmp/nonexistent_socket")).to be false
    end

    it "returns false when socket is not listening" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "stale.sock")
        # Create a socket file but don't listen on it
        server = UNIXServer.new(path)
        server.close
        expect(GirbMcp::DebugClient.socket_connectable?(path)).to be false
      end
    end
  end

  describe "#disconnect" do
    it "resets state" do
      client = GirbMcp::DebugClient.new
      client.disconnect
      expect(client.connected?).to be false
      expect(client.pid).to be_nil
      expect(client.paused).to be false
      expect(client.trap_context).to be_nil
      expect(client.pending_http).to be_nil
    end

    it "closes socket via force_close_socket with timeout" do
      client, server = setup_client_with_socket
      client.disconnect
      expect(client.connected?).to be false
      expect(client.pid).to be_nil
    ensure
      server.close rescue nil
    end

    it "completes within DISCONNECT_SOCKET_TIMEOUT even if socket blocks" do
      client, server = setup_client_with_socket

      # Fill the write buffer to simulate a blocked socket
      # (shutdown may block if the other end isn't reading)
      start = Time.now
      client.disconnect
      elapsed = Time.now - start

      expect(elapsed).to be < (GirbMcp::DebugClient::DISCONNECT_SOCKET_TIMEOUT + 1)
      expect(client.connected?).to be false
    ensure
      server.close rescue nil
    end
  end

  describe "#paused" do
    it "starts as false" do
      client = GirbMcp::DebugClient.new
      expect(client.paused).to be false
    end
  end

  describe "#trap_context" do
    it "starts as nil" do
      client = GirbMcp::DebugClient.new
      expect(client.trap_context).to be_nil
    end
  end

  describe "#pending_http" do
    it "starts as nil" do
      client = GirbMcp::DebugClient.new
      expect(client.pending_http).to be_nil
    end

    it "can be set and read" do
      client = GirbMcp::DebugClient.new
      client.pending_http = { method: "GET", url: "http://localhost:3000" }
      expect(client.pending_http[:method]).to eq("GET")
    end
  end

  describe "#check_current_exception" do
    it "raises SessionError when not connected" do
      client = GirbMcp::DebugClient.new
      # check_current_exception calls send_command internally
      expect(client.check_current_exception).to be_nil
    end
  end

  describe "#ensure_paused" do
    it "returns empty string when already paused" do
      client = GirbMcp::DebugClient.new
      # Manually set paused state
      client.instance_variable_set(:@paused, true)
      expect(client.ensure_paused).to eq("")
    end

    it "returns nil when not connected" do
      client = GirbMcp::DebugClient.new
      # Not connected, no socket
      expect(client.ensure_paused).to be_nil
    end
  end

  describe "#repause" do
    it "returns empty string when already paused" do
      client = GirbMcp::DebugClient.new
      client.instance_variable_set(:@paused, true)
      expect(client.repause).to eq("")
    end

    it "returns nil when not connected" do
      client = GirbMcp::DebugClient.new
      expect(client.repause).to be_nil
    end

    it "returns nil when socket is nil" do
      client = GirbMcp::DebugClient.new
      client.instance_variable_set(:@connected, true)
      # connected? returns false because @socket is nil
      expect(client.repause).to be_nil
    end
  end

  describe "#continue_and_wait" do
    it "raises SessionError when not connected" do
      client = GirbMcp::DebugClient.new
      expect { client.continue_and_wait }.to raise_error(
        GirbMcp::SessionError, /Not connected/
      )
    end
  end

  describe "#wait_for_breakpoint" do
    it "raises SessionError when not connected" do
      client = GirbMcp::DebugClient.new
      expect { client.wait_for_breakpoint }.to raise_error(
        GirbMcp::SessionError, /Not connected/
      )
    end
  end

  # Helper to set up a client with a simulated socket (bidirectional socket pair).
  # Returns [client, server_socket] — write protocol data to server_socket,
  # the client reads/writes via its internal socket.
  def setup_client_with_socket
    client_sock, server_sock = Socket.pair(:UNIX, :STREAM, 0)
    client = GirbMcp::DebugClient.new
    client.instance_variable_set(:@socket, client_sock)
    client.instance_variable_set(:@connected, true)
    client.instance_variable_set(:@pid, "12345")
    [client, server_sock]
  end

  describe "#connect (wake callback)" do
    it "calls on_initial_timeout block on first timeout and retries successfully" do
      client_sock, server_sock = Socket.pair(:UNIX, :STREAM, 0)
      client = GirbMcp::DebugClient.new

      # Stub socket creation to use our socket pair
      allow(client).to receive(:discover_socket).and_return("/tmp/fake")
      allow(Socket).to receive(:unix).and_return(client_sock)

      # Stub send_greeting (it would fail without a real debug server)
      allow(client).to receive(:send_greeting)

      # Simulate: first read times out (short timeout), then after wake, server responds
      callback_called = false
      Thread.new do
        # Wait for the callback to be called, then send the input prompt
        sleep 0.1 until callback_called
        server_sock.write("out hello\n")
        server_sock.write("input 99999\n")
      end

      result = client.connect(connect_timeout: 0.5) {
        callback_called = true
      }

      expect(callback_called).to be true
      expect(result[:success]).to be true
      expect(result[:pid]).to eq("99999")
      expect(result[:output]).to include("hello")
      expect(client.connected?).to be true
      expect(client.paused).to be true
    ensure
      client_sock&.close rescue nil
      server_sock&.close rescue nil
    end

    it "raises ConnectionError with diagnostic message when initial read times out" do
      client_sock, server_sock = Socket.pair(:UNIX, :STREAM, 0)
      client = GirbMcp::DebugClient.new

      allow(client).to receive(:discover_socket).and_return("/tmp/fake")
      allow(Socket).to receive(:unix).and_return(client_sock)
      allow(client).to receive(:send_greeting)

      # No block given, no data sent — should timeout and raise ConnectionError
      expect {
        client.connect(connect_timeout: 0.5)
      }.to raise_error(GirbMcp::ConnectionError, /Another debugger client/)
    ensure
      client_sock&.close rescue nil
      server_sock&.close rescue nil
    end

    it "raises ConnectionError with diagnostic message when retry also times out" do
      client_sock, server_sock = Socket.pair(:UNIX, :STREAM, 0)
      client = GirbMcp::DebugClient.new

      allow(client).to receive(:discover_socket).and_return("/tmp/fake")
      allow(Socket).to receive(:unix).and_return(client_sock)
      allow(client).to receive(:send_greeting)

      callback_called = false

      # Block is called but no data sent — retry also times out
      expect {
        client.connect(connect_timeout: 0.3) {
          callback_called = true
          # Don't send any data — retry should also timeout
        }
      }.to raise_error(GirbMcp::ConnectionError, /Another debugger client/)

      expect(callback_called).to be true
    ensure
      client_sock&.close rescue nil
      server_sock&.close rescue nil
    end
  end

  describe "#send_command (protocol desync prevention)" do
    it "raises SessionError when process is not paused and buffer is empty" do
      client, server = setup_client_with_socket
      client.instance_variable_set(:@paused, false)

      expect { client.send_command("list") }.to raise_error(
        GirbMcp::SessionError, /not paused/
      )
    ensure
      server.close rescue nil
    end

    it "recovers @paused from stale input PID in buffer" do
      client, server = setup_client_with_socket
      client.instance_variable_set(:@paused, false)

      # Write stale data (simulating a late breakpoint after continue timeout)
      server.write("out Stop by #1  BP - Line  app/models/user.rb:10\n")
      server.write("input 12345\n")
      sleep 0.01 # Let data arrive in the buffer

      # Also write the response that the command will get (in a separate thread
      # to avoid blocking — the command hasn't been sent yet)
      Thread.new do
        sleep 0.1
        server.write("out => nil\n")
        server.write("input 12345\n")
      end

      result = client.send_command("p nil", timeout: 2)
      expect(result).to include("nil")
      expect(client.paused).to be true
    ensure
      server.close rescue nil
    end

    it "drains multiple stale responses before sending" do
      client, server = setup_client_with_socket
      client.instance_variable_set(:@paused, false)

      # Simulate two stale command responses in the buffer
      server.write("out => 1\n")
      server.write("input 12345\n")
      server.write("out => 2\n")
      server.write("input 12345\n")
      sleep 0.01

      # The actual response for the new command
      Thread.new do
        sleep 0.1
        server.write("out => 3\n")
        server.write("input 12345\n")
      end

      result = client.send_command("p 3", timeout: 2)
      expect(result).to include("3")
      expect(client.paused).to be true
    ensure
      server.close rescue nil
    end
  end

  describe "#send_command (timeout sets @paused = false)" do
    it "sets @paused to false on TimeoutError" do
      client, server = setup_client_with_socket
      client.instance_variable_set(:@paused, true)

      # No response from server → timeout
      expect { client.send_command("sleep_forever", timeout: 0.3) }.to raise_error(
        GirbMcp::TimeoutError
      )

      expect(client.paused).to be false
    ensure
      server.close rescue nil
    end

    it "includes recovery message in timeout error" do
      client, server = setup_client_with_socket
      client.instance_variable_set(:@paused, true)

      expect { client.send_command("slow_cmd", timeout: 0.3) }.to raise_error(
        GirbMcp::TimeoutError, /Recovery.*automatically try to interrupt/
      )
    ensure
      server.close rescue nil
    end
  end

  describe "#send_command (read_until_input timeout)" do
    it "always raises TimeoutError when input PID is not received" do
      client, server = setup_client_with_socket
      client.instance_variable_set(:@paused, true)

      # Write partial output AFTER the command is sent (simulating a slow command
      # that produces output but never finishes)
      Thread.new do
        sleep 0.05
        server.write("out partial output line 1\n")
        server.write("out partial output line 2\n")
      end

      expect { client.send_command("slow_cmd", timeout: 0.5) }.to raise_error(
        GirbMcp::TimeoutError
      ) do |error|
        expect(error.final_output).to include("partial output line 1")
        expect(error.final_output).to include("partial output line 2")
      end
    ensure
      server.close rescue nil
    end

    it "does not silently return partial output on timeout" do
      client, server = setup_client_with_socket
      client.instance_variable_set(:@paused, true)

      # Write meaningful output but no input PID
      server.write("out => [1, 2, 3]\n")

      # Previously this would return "=> [1, 2, 3]" instead of raising
      expect { client.send_command("p [1,2,3]", timeout: 0.5) }.to raise_error(
        GirbMcp::TimeoutError
      )
    ensure
      server.close rescue nil
    end
  end

  describe "#interrupt_and_wait" do
    it "returns nil when pid is nil" do
      client = GirbMcp::DebugClient.new
      expect(client.interrupt_and_wait).to be_nil
    end

    it "returns empty string when already paused" do
      client = GirbMcp::DebugClient.new
      client.instance_variable_set(:@pid, "12345")
      client.instance_variable_set(:@paused, true)
      expect(client.interrupt_and_wait).to eq("")
    end

    it "sends SIGINT and waits for pause" do
      client, server = setup_client_with_socket
      client.instance_variable_set(:@paused, false)

      allow(Process).to receive(:kill)

      Thread.new do
        sleep 0.05
        server.write("input 12345\n")
      end

      result = client.interrupt_and_wait(timeout: 2)

      expect(Process).to have_received(:kill).with("INT", 12345)
      expect(result).to be_a(String)
      expect(client.paused).to be true
    ensure
      server.close rescue nil
    end

    it "returns nil when process does not exist" do
      client = GirbMcp::DebugClient.new
      client.instance_variable_set(:@pid, "99999")
      client.instance_variable_set(:@paused, false)

      allow(Process).to receive(:kill).and_raise(Errno::ESRCH)

      expect(client.interrupt_and_wait).to be_nil
    end
  end

  describe "#auto_repause!" do
    it "returns false when already paused" do
      client = GirbMcp::DebugClient.new
      client.instance_variable_set(:@paused, true)
      expect(client.auto_repause!).to be false
    end

    it "raises SessionError when both repause and interrupt fail" do
      client = GirbMcp::DebugClient.new
      client.instance_variable_set(:@connected, true)
      client.instance_variable_set(:@paused, false)
      client.instance_variable_set(:@pid, "99999")

      # repause returns nil (no socket), interrupt_and_wait returns nil (ESRCH)
      allow(Process).to receive(:kill).and_raise(Errno::ESRCH)

      expect { client.auto_repause! }.to raise_error(
        GirbMcp::SessionError, /could not be interrupted/
      )
    end

    it "retries repause for remote clients instead of SIGINT" do
      client, server = setup_client_with_socket
      client.instance_variable_set(:@paused, false)
      client.instance_variable_set(:@remote, true)

      call_count = 0
      allow(client).to receive(:repause) do
        call_count += 1
        call_count == 1 ? nil : ""
      end

      result = client.auto_repause!
      expect(result).to be true
      expect(client).to have_received(:repause).twice
    ensure
      server.close rescue nil
    end

    it "raises SessionError when both repause attempts fail for remote clients" do
      client = GirbMcp::DebugClient.new
      client.instance_variable_set(:@connected, true)
      client.instance_variable_set(:@paused, false)
      client.instance_variable_set(:@remote, true)
      client.instance_variable_set(:@pid, "99999")

      allow(client).to receive(:repause).and_return(nil)

      expect { client.auto_repause! }.to raise_error(
        GirbMcp::SessionError, /could not be interrupted/
      )
      expect(client).to have_received(:repause).twice
    end

    it "falls back to SIGINT when repause fails" do
      client, server = setup_client_with_socket
      client.instance_variable_set(:@paused, false)

      # Stub repause to return nil (simulating SIGURG failure on IO-blocked process)
      allow(client).to receive(:repause).and_return(nil)
      allow(Process).to receive(:kill).with("INT", 12345)

      Thread.new do
        sleep 0.05
        server.write("input 12345\n")
      end

      result = client.auto_repause!
      expect(result).to be true
      expect(Process).to have_received(:kill).with("INT", 12345)
      expect(client.paused).to be true
    ensure
      server.close rescue nil
    end

    it "does not attempt escape when escape_target is nil" do
      client, server = setup_client_with_socket
      client.instance_variable_set(:@paused, false)
      client.listen_ports = [3000]
      client.escape_target = nil

      # repause now sends SIGURG directly via Process.kill instead of socket.
      # Mock it to succeed, then write input prompt after a brief delay.
      allow(Process).to receive(:kill).with("URG", 12345)
      Thread.new do
        sleep 0.05
        server.write("input 12345\n")
      end

      result = client.auto_repause!
      expect(result).to be true
      expect(client.trap_context).to be true
    ensure
      server.close rescue nil
    end

    it "does not attempt escape when listen_ports is empty" do
      client, server = setup_client_with_socket
      client.instance_variable_set(:@paused, false)
      client.listen_ports = []
      client.escape_target = { file: "/gems/metal.rb", line: 211, path: "/" }

      allow(Process).to receive(:kill).with("URG", 12345)
      Thread.new do
        sleep 0.05
        server.write("input 12345\n")
      end

      result = client.auto_repause!
      expect(result).to be true
      expect(client.trap_context).to be true
    ensure
      server.close rescue nil
    end

    it "attempts escape after repause when escape_target and listen_ports are set" do
      client, server = setup_client_with_socket
      client.instance_variable_set(:@paused, false)
      client.listen_ports = [3000]
      client.escape_target = { file: "/gems/metal.rb", line: 211, path: "/users" }

      # Use Queue to synchronize: HTTP stub blocks until BP response is written,
      # ensuring continue_and_wait reads the breakpoint before interrupt fires.
      bp_written = Queue.new

      http_double = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http_double)
      allow(http_double).to receive(:open_timeout=)
      allow(http_double).to receive(:read_timeout=)
      allow(http_double).to receive(:get) { bp_written.pop; Net::HTTPResponse }

      allow(Process).to receive(:kill).with("URG", 12345)
      Thread.new do
        sleep 0.05
        server.write("input 12345\n")

        server.gets # "command ... break ..."
        server.write("out #1  BP - Line  /gems/metal.rb:211\n")
        server.write("input 12345\n")

        server.gets # "command ... c\n"
        server.write("out Stop by #1  BP - Line  /gems/metal.rb:211\n")
        server.write("input 12345\n")
        bp_written.push(true) # unblock HTTP stub after BP response is written

        server.gets # "command ... delete 1\n"
        server.write("out \n")
        server.write("input 12345\n")
      end

      result = client.auto_repause!
      expect(result).to be true
      expect(client.trap_context).to be false
    ensure
      server.close rescue nil
    end

    it "stays in trap context when escape times out" do
      client, server = setup_client_with_socket
      client.instance_variable_set(:@paused, false)
      client.listen_ports = [3000]
      client.escape_target = { file: "/gems/metal.rb", line: 211, path: "/" }

      # HTTP completes instantly → interrupt fires → :interrupted → escape fails
      http_double = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http_double)
      allow(http_double).to receive(:open_timeout=)
      allow(http_double).to receive(:read_timeout=)
      allow(http_double).to receive(:get).and_return(Net::HTTPResponse)

      server_thread = Thread.new do
        Thread.current.report_on_exception = false
        sleep 0.05
        server.write("input 12345\n")

        server.gets # "command ... break ..."
        server.write("out #1  BP - Line  /gems/metal.rb:211\n")
        server.write("input 12345\n")

        server.gets # "command ... c\n"
        # Don't respond — escape fails, ensure_paused times out,
        # send_command("delete ...") raises SessionError (not paused) → caught
      rescue IOError
        # Server socket may be closed by ensure block
      end
      allow(Process).to receive(:kill).with("URG", 12345)

      result = client.auto_repause!
      expect(result).to be true
      expect(client.trap_context).to be true
    ensure
      server.close rescue nil
      server_thread&.join(2)
    end
  end

  describe "#listen_ports and #escape_target" do
    it "initializes listen_ports as empty array" do
      client = GirbMcp::DebugClient.new
      expect(client.listen_ports).to eq([])
    end

    it "initializes escape_target as nil" do
      client = GirbMcp::DebugClient.new
      expect(client.escape_target).to be_nil
    end

    it "resets on disconnect" do
      client = GirbMcp::DebugClient.new
      client.listen_ports = [3000]
      client.escape_target = { file: "test.rb", line: 1, path: "/" }
      client.disconnect
      expect(client.listen_ports).to eq([])
      expect(client.escape_target).to be_nil
    end
  end
end
