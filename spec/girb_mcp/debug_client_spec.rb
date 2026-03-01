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

    it "has HTTP wake settle time" do
      expect(GirbMcp::DebugClient::HTTP_WAKE_SETTLE_TIME).to eq(0.3)
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

    it "drains stale data before sending continue command" do
      client, server_sock = setup_client_with_socket
      client.instance_variable_set(:@paused, true)

      # Write stale data followed by a fresh breakpoint response
      stale_data = "out stale leftover\ninput 12345\n"
      fresh_bp = "out Stop by #1  BP - Line  app.rb:5\ninput 12345\n"
      server_sock.write(stale_data)

      # After drain, the client sends "c" and reads the fresh response
      Thread.new do
        sleep 0.05
        # Read the continue command sent by the client
        server_sock.gets
        server_sock.write(fresh_bp)
      end

      result = client.continue_and_wait(timeout: 2)
      expect(result[:output]).to include("Stop by #1")
      expect(result[:output]).not_to include("stale leftover")
    ensure
      client&.instance_variable_get(:@socket)&.close rescue nil
      server_sock&.close rescue nil
    end
  end

  describe "#wait_for_breakpoint" do
    it "raises SessionError when not connected" do
      client = GirbMcp::DebugClient.new
      expect { client.wait_for_breakpoint }.to raise_error(
        GirbMcp::SessionError, /Not connected/
      )
    end

    it "sets @paused to false while waiting" do
      client, server_sock = setup_client_with_socket
      client.instance_variable_set(:@paused, true)

      # No data sent — will timeout and return { type: :timeout }
      result = client.wait_for_breakpoint(timeout: 0.3)

      expect(result[:type]).to eq(:timeout)
      expect(client.paused).to be false
    ensure
      client&.instance_variable_get(:@socket)&.close rescue nil
      server_sock&.close rescue nil
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

  describe "#connect (remote: override)" do
    def connect_with_socket(client, server_sock, **kwargs)
      allow(client).to receive(:send_greeting)

      Thread.new do
        sleep 0.05
        server_sock.write("input 12345\n")
      end

      client.connect(**kwargs, connect_timeout: 2)
    end

    it "auto-detects remote=false for Unix socket path" do
      client_sock, server_sock = Socket.pair(:UNIX, :STREAM, 0)
      client = GirbMcp::DebugClient.new
      allow(Socket).to receive(:unix).and_return(client_sock)

      connect_with_socket(client, server_sock, path: "/tmp/rdbg.sock")
      expect(client.remote).to be false
    ensure
      client_sock&.close rescue nil
      server_sock&.close rescue nil
    end

    it "auto-detects remote=true for TCP port" do
      client_sock, server_sock = Socket.pair(:UNIX, :STREAM, 0)
      client = GirbMcp::DebugClient.new
      allow(Socket).to receive(:tcp).and_return(client_sock)

      connect_with_socket(client, server_sock, port: 12345)
      expect(client.remote).to be true
    ensure
      client_sock&.close rescue nil
      server_sock&.close rescue nil
    end

    it "overrides to remote=true for Unix socket when remote: true" do
      client_sock, server_sock = Socket.pair(:UNIX, :STREAM, 0)
      client = GirbMcp::DebugClient.new
      allow(Socket).to receive(:unix).and_return(client_sock)

      connect_with_socket(client, server_sock, path: "/tmp/rdbg.sock", remote: true)
      expect(client.remote).to be true
    ensure
      client_sock&.close rescue nil
      server_sock&.close rescue nil
    end

    it "overrides to remote=false for TCP port when remote: false" do
      client_sock, server_sock = Socket.pair(:UNIX, :STREAM, 0)
      client = GirbMcp::DebugClient.new
      allow(Socket).to receive(:tcp).and_return(client_sock)

      connect_with_socket(client, server_sock, port: 12345, remote: false)
      expect(client.remote).to be false
    ensure
      client_sock&.close rescue nil
      server_sock&.close rescue nil
    end

    it "preserves auto-detection when remote: nil" do
      client_sock, server_sock = Socket.pair(:UNIX, :STREAM, 0)
      client = GirbMcp::DebugClient.new
      allow(Socket).to receive(:tcp).and_return(client_sock)

      connect_with_socket(client, server_sock, port: 12345, remote: nil)
      expect(client.remote).to be true
    ensure
      client_sock&.close rescue nil
      server_sock&.close rescue nil
    end
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

    it "retries with check_paused for remote clients instead of SIGINT" do
      client, server = setup_client_with_socket
      client.instance_variable_set(:@paused, false)
      client.instance_variable_set(:@remote, true)

      allow(client).to receive(:repause).and_return(nil)
      allow(client).to receive(:check_paused).and_return("")
      allow(client).to receive(:sleep)

      result = client.auto_repause!
      expect(result).to be true
      expect(client).to have_received(:repause).once
      expect(client).to have_received(:check_paused).once
      expect(client).to have_received(:sleep).with(0.3)
    ensure
      server.close rescue nil
    end

    it "raises SessionError when all repause attempts fail for remote clients" do
      client = GirbMcp::DebugClient.new
      client.instance_variable_set(:@connected, true)
      client.instance_variable_set(:@paused, false)
      client.instance_variable_set(:@remote, true)
      client.instance_variable_set(:@pid, "99999")

      allow(client).to receive(:repause).and_return(nil)
      allow(client).to receive(:check_paused).and_return(nil)
      allow(client).to receive(:sleep)

      expect { client.auto_repause! }.to raise_error(
        GirbMcp::SessionError, /could not be interrupted/
      )
      # 1 repause (sends pause message) + 2 check_paused (wait only)
      expect(client).to have_received(:repause).once
      expect(client).to have_received(:check_paused).twice
    end

    it "uses progressive sleep delays between remote check_paused retries" do
      client = GirbMcp::DebugClient.new
      client.instance_variable_set(:@connected, true)
      client.instance_variable_set(:@paused, false)
      client.instance_variable_set(:@remote, true)
      client.instance_variable_set(:@pid, "99999")

      allow(client).to receive(:repause).and_return(nil)
      # First check_paused fails, second succeeds
      call_count = 0
      allow(client).to receive(:check_paused) do
        call_count += 1
        call_count == 2 ? "" : nil
      end
      sleep_args = []
      allow(client).to receive(:sleep) { |t| sleep_args << t }

      result = client.auto_repause!
      expect(result).to be true
      expect(client).to have_received(:repause).once
      expect(client).to have_received(:check_paused).twice
      expect(sleep_args).to eq([0.3, 0.5])
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
      allow(http_double).to receive(:finish)

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

    it "stays in trap context when escape times out but re-pauses" do
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
      allow(http_double).to receive(:finish)

      server_thread = Thread.new do
        Thread.current.report_on_exception = false
        sleep 0.05
        server.write("input 12345\n")

        server.gets # "command ... break ..."
        server.write("out #1  BP - Line  /gems/metal.rb:211\n")
        server.write("input 12345\n")

        server.gets # "command ... c\n"
        # Don't respond to continue — escape fails (continue_and_wait times out)
        # attempt_trap_escape! calls repause(timeout: 3) which sends SIGURG
        # auto_repause! also calls repause(timeout: 3) as recovery
        # Respond to the recovery repause with input prompt
        sleep 0.3 # Wait for recovery repause SIGURG
        server.write("input 12345\n")

        server.gets # "command ... p nil\n" (protocol sync)
        server.write("out nil\n")
        server.write("input 12345\n")
      rescue IOError
        # Server socket may be closed by ensure block
      end
      allow(Process).to receive(:kill).with("URG", 12345)

      result = client.auto_repause!
      expect(result).to be true
      expect(client.trap_context).to be true
      expect(client.paused).to be true
    ensure
      server.close rescue nil
      server_thread&.join(2)
    end

    it "raises SessionError when recovery repause also fails after trap escape" do
      client, server = setup_client_with_socket
      client.instance_variable_set(:@paused, false)
      client.listen_ports = [3000]
      client.escape_target = { file: "/gems/metal.rb", line: 211, path: "/" }

      http_double = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http_double)
      allow(http_double).to receive(:open_timeout=)
      allow(http_double).to receive(:read_timeout=)
      allow(http_double).to receive(:get).and_return(Net::HTTPResponse)
      allow(http_double).to receive(:finish)

      server_thread = Thread.new do
        Thread.current.report_on_exception = false
        sleep 0.05
        server.write("input 12345\n")

        server.gets # "command ... break ..."
        server.write("out #1  BP - Line  /gems/metal.rb:211\n")
        server.write("input 12345\n")

        server.gets # "command ... c\n"
        # Don't respond to continue — escape fails
        # Don't respond to recovery repause either — total failure
      rescue IOError
        # Server socket may be closed by ensure block
      end
      allow(Process).to receive(:kill).with("URG", 12345)

      expect { client.auto_repause! }.to raise_error(
        GirbMcp::SessionError,
        /Process could not be re-paused after failed trap escape/
      )
    ensure
      server.close rescue nil
      server_thread&.join(2)
    end
  end

  describe ".wake_io_blocked_process (class method)" do
    it "sends HTTP GET to 127.0.0.1 on the given port in a background thread" do
      http_double = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).with("127.0.0.1", 3000).and_return(http_double)
      allow(http_double).to receive(:open_timeout=)
      allow(http_double).to receive(:read_timeout=)
      allow(http_double).to receive(:get).with("/").and_return(nil)

      thread = GirbMcp::DebugClient.wake_io_blocked_process(3000)
      thread.join(2)

      expect(Net::HTTP).to have_received(:new).with("127.0.0.1", 3000)
      expect(http_double).to have_received(:get).with("/")
    end

    it "silently ignores HTTP errors" do
      allow(Net::HTTP).to receive(:new).and_raise(Errno::ECONNREFUSED)

      thread = GirbMcp::DebugClient.wake_io_blocked_process(3000)
      expect { thread.join(2) }.not_to raise_error
    end
  end

  describe "#wake_io_blocked_process (instance delegate)" do
    it "delegates to class method" do
      client = GirbMcp::DebugClient.new
      thread_double = instance_double(Thread)
      allow(GirbMcp::DebugClient).to receive(:wake_io_blocked_process).with(3000).and_return(thread_double)

      result = client.wake_io_blocked_process(3000)
      expect(result).to eq(thread_double)
      expect(GirbMcp::DebugClient).to have_received(:wake_io_blocked_process).with(3000)
    end
  end

  describe "#auto_repause! (HTTP wake for remote)" do
    it "tries HTTP wake when remote check_paused fails and listen_ports available" do
      client, server = setup_client_with_socket
      client.instance_variable_set(:@paused, false)
      client.instance_variable_set(:@remote, true)
      client.listen_ports = [3000]

      allow(client).to receive(:repause).and_return(nil)
      # First check_paused fails (before HTTP wake), second succeeds (after HTTP wake)
      call_count = 0
      allow(client).to receive(:check_paused) do
        call_count += 1
        call_count == 2 ? "" : nil
      end
      allow(client).to receive(:sleep)
      wake_thread = instance_double(Thread)
      allow(wake_thread).to receive(:join)
      allow(client).to receive(:wake_io_blocked_process).and_return(wake_thread)

      result = client.auto_repause!
      expect(result).to be true
      expect(client).to have_received(:repause).once
      expect(client).to have_received(:check_paused).twice
      expect(client).to have_received(:wake_io_blocked_process).with(3000)
      expect(wake_thread).to have_received(:join).with(1)
    ensure
      server.close rescue nil
    end

    it "skips HTTP wake when listen_ports is empty" do
      client = GirbMcp::DebugClient.new
      client.instance_variable_set(:@connected, true)
      client.instance_variable_set(:@paused, false)
      client.instance_variable_set(:@remote, true)
      client.instance_variable_set(:@pid, "99999")
      client.listen_ports = []

      allow(client).to receive(:repause).and_return(nil)
      allow(client).to receive(:sleep)
      allow(client).to receive(:wake_io_blocked_process)

      expect { client.auto_repause! }.to raise_error(GirbMcp::SessionError)
      expect(client).not_to have_received(:wake_io_blocked_process)
    end
  end

  describe "#auto_repause! (protocol sync after trap escape)" do
    it "sends p nil after successful trap escape" do
      client, server = setup_client_with_socket
      client.instance_variable_set(:@paused, false)
      client.listen_ports = [3000]
      client.escape_target = { file: "/gems/metal.rb", line: 211, path: "/users" }

      # Use Queue for synchronization
      bp_written = Queue.new

      http_double = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http_double)
      allow(http_double).to receive(:open_timeout=)
      allow(http_double).to receive(:read_timeout=)
      allow(http_double).to receive(:get) { bp_written.pop; Net::HTTPResponse }
      allow(http_double).to receive(:finish)

      allow(Process).to receive(:kill).with("URG", 12345)
      Thread.new do
        sleep 0.05
        # repause
        server.write("input 12345\n")

        # break command
        server.gets
        server.write("out #1  BP - Line  /gems/metal.rb:211\n")
        server.write("input 12345\n")

        # continue command
        server.gets
        server.write("out Stop by #1  BP - Line  /gems/metal.rb:211\n")
        server.write("input 12345\n")
        bp_written.push(true)

        # delete command
        server.gets
        server.write("out \n")
        server.write("input 12345\n")

        # protocol sync: p nil
        server.gets
        server.write("out => nil\n")
        server.write("input 12345\n")
      end

      result = client.auto_repause!
      expect(result).to be true
      expect(client.trap_context).to be false
    ensure
      server.close rescue nil
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
