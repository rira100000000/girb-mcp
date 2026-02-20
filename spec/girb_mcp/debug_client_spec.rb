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
end
