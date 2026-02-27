# frozen_string_literal: true

RSpec.describe GirbMcp::TcpSessionDiscovery do
  describe ".docker_sessions" do
    context "when Docker CLI is not available" do
      before do
        allow(described_class).to receive(:docker_available?).and_return(false)
      end

      it "returns empty array" do
        expect(described_class.docker_sessions).to eq([])
      end
    end

    context "when Docker has no running containers" do
      before do
        allow(described_class).to receive(:docker_available?).and_return(true)
        allow(described_class).to receive(:`).with("docker ps -q 2>/dev/null").and_return("")
      end

      it "returns empty array" do
        expect(described_class.docker_sessions).to eq([])
      end
    end

    context "when Docker has a container with RUBY_DEBUG_PORT" do
      let(:container_json) do
        [{
          "Name" => "/myapp",
          "Config" => {
            "Env" => [
              "RUBY_DEBUG_OPEN=true",
              "RUBY_DEBUG_HOST=0.0.0.0",
              "RUBY_DEBUG_PORT=12345",
            ],
          },
          "HostConfig" => {
            "PortBindings" => {
              "12345/tcp" => [{ "HostIp" => "", "HostPort" => "12345" }],
            },
          },
          "NetworkSettings" => {
            "Networks" => {
              "bridge" => { "IPAddress" => "172.17.0.2" },
            },
          },
        }].to_json
      end

      before do
        allow(described_class).to receive(:docker_available?).and_return(true)
        allow(described_class).to receive(:`).with("docker ps -q 2>/dev/null").and_return("abc123\n")
        allow(described_class).to receive(:`).with("docker inspect abc123 2>/dev/null").and_return(container_json)
        allow(described_class).to receive(:tcp_connectable?).and_return(true)
      end

      it "returns session with mapped host port" do
        sessions = described_class.docker_sessions
        expect(sessions.size).to eq(1)
        expect(sessions[0]).to eq(
          host: "localhost",
          port: 12345,
          name: "myapp",
          source: :docker,
        )
      end
    end

    context "when container has RUBY_DEBUG_PORT but port is not connectable" do
      let(:container_json) do
        [{
          "Name" => "/myapp",
          "Config" => {
            "Env" => ["RUBY_DEBUG_PORT=12345"],
          },
          "HostConfig" => {
            "PortBindings" => {
              "12345/tcp" => [{ "HostIp" => "", "HostPort" => "12345" }],
            },
          },
          "NetworkSettings" => { "Networks" => {} },
        }].to_json
      end

      before do
        allow(described_class).to receive(:docker_available?).and_return(true)
        allow(described_class).to receive(:`).with("docker ps -q 2>/dev/null").and_return("abc123\n")
        allow(described_class).to receive(:`).with("docker inspect abc123 2>/dev/null").and_return(container_json)
        allow(described_class).to receive(:tcp_connectable?).and_return(false)
      end

      it "excludes unreachable sessions" do
        expect(described_class.docker_sessions).to eq([])
      end
    end

    context "when container has no port binding but has network IP" do
      let(:container_json) do
        [{
          "Name" => "/myapp",
          "Config" => {
            "Env" => ["RUBY_DEBUG_PORT=12345"],
          },
          "HostConfig" => {
            "PortBindings" => {},
          },
          "NetworkSettings" => {
            "Networks" => {
              "bridge" => { "IPAddress" => "172.17.0.2" },
            },
          },
        }].to_json
      end

      before do
        allow(described_class).to receive(:docker_available?).and_return(true)
        allow(described_class).to receive(:`).with("docker ps -q 2>/dev/null").and_return("abc123\n")
        allow(described_class).to receive(:`).with("docker inspect abc123 2>/dev/null").and_return(container_json)
        allow(described_class).to receive(:tcp_connectable?).and_return(true)
      end

      it "falls back to container IP" do
        sessions = described_class.docker_sessions
        expect(sessions.size).to eq(1)
        expect(sessions[0][:host]).to eq("172.17.0.2")
        expect(sessions[0][:port]).to eq(12345)
      end
    end

    context "when container has no RUBY_DEBUG_PORT" do
      let(:container_json) do
        [{
          "Name" => "/webserver",
          "Config" => { "Env" => ["RAILS_ENV=production"] },
          "HostConfig" => { "PortBindings" => {} },
          "NetworkSettings" => { "Networks" => {} },
        }].to_json
      end

      before do
        allow(described_class).to receive(:docker_available?).and_return(true)
        allow(described_class).to receive(:`).with("docker ps -q 2>/dev/null").and_return("abc123\n")
        allow(described_class).to receive(:`).with("docker inspect abc123 2>/dev/null").and_return(container_json)
      end

      it "skips container without debug port" do
        expect(described_class.docker_sessions).to eq([])
      end
    end
  end

  describe ".local_tcp_sessions" do
    context "when /proc does not exist" do
      before do
        allow(File).to receive(:directory?).with("/proc").and_return(false)
      end

      it "returns empty array" do
        expect(described_class.local_tcp_sessions).to eq([])
      end
    end

    context "when a local process has RUBY_DEBUG_PORT" do
      let(:environ_content) { "HOME=/home/user\0RUBY_DEBUG_PORT=54321\0RAILS_ENV=development\0" }

      before do
        allow(File).to receive(:directory?).with("/proc").and_return(true)
        allow(Dir).to receive(:glob).with("/proc/[0-9]*/environ").and_return(["/proc/9999/environ"])
        allow(File).to receive(:read).with("/proc/9999/environ").and_return(environ_content)
        allow(described_class).to receive(:tcp_connectable?).and_return(true)
        allow(described_class).to receive(:process_name).with("9999").and_return("rails")
        # Ensure we don't skip ourselves
        allow(Process).to receive(:pid).and_return(1)
      end

      it "returns session for the process" do
        sessions = described_class.local_tcp_sessions
        expect(sessions.size).to eq(1)
        expect(sessions[0]).to eq(
          host: "localhost",
          port: 54321,
          name: "rails",
          source: :local,
        )
      end
    end

    context "when process is ourselves" do
      let(:environ_content) { "RUBY_DEBUG_PORT=54321\0" }

      before do
        allow(File).to receive(:directory?).with("/proc").and_return(true)
        allow(Dir).to receive(:glob).with("/proc/[0-9]*/environ").and_return(["/proc/#{Process.pid}/environ"])
        allow(File).to receive(:read).with("/proc/#{Process.pid}/environ").and_return(environ_content)
      end

      it "skips own process" do
        expect(described_class.local_tcp_sessions).to eq([])
      end
    end

    context "when process environ is not readable" do
      before do
        allow(File).to receive(:directory?).with("/proc").and_return(true)
        allow(Dir).to receive(:glob).with("/proc/[0-9]*/environ").and_return(["/proc/1/environ"])
        allow(File).to receive(:read).with("/proc/1/environ").and_raise(Errno::EACCES)
      end

      it "skips inaccessible processes" do
        expect(described_class.local_tcp_sessions).to eq([])
      end
    end
  end

  describe ".tcp_connectable?" do
    it "returns true for a listening port" do
      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]

      expect(described_class.tcp_connectable?("127.0.0.1", port, timeout: 1)).to be true
    ensure
      server&.close
    end

    it "returns false for a non-listening port" do
      # Use a random high port that's unlikely to be in use
      expect(described_class.tcp_connectable?("127.0.0.1", 49999, timeout: 1)).to be false
    end
  end

  describe ".discover" do
    it "combines docker and local sessions" do
      docker = [{ host: "localhost", port: 12345, name: "myapp", source: :docker }]
      local = [{ host: "localhost", port: 54321, name: "rails", source: :local }]
      allow(described_class).to receive(:docker_sessions).and_return(docker)
      allow(described_class).to receive(:local_tcp_sessions).and_return(local)

      sessions = described_class.discover
      expect(sessions.size).to eq(2)
      expect(sessions[0][:source]).to eq(:docker)
      expect(sessions[1][:source]).to eq(:local)
    end

    it "deduplicates by host and port" do
      docker = [{ host: "localhost", port: 12345, name: "myapp", source: :docker }]
      local = [{ host: "localhost", port: 12345, name: "pid-999", source: :local }]
      allow(described_class).to receive(:docker_sessions).and_return(docker)
      allow(described_class).to receive(:local_tcp_sessions).and_return(local)

      sessions = described_class.discover
      expect(sessions.size).to eq(1)
      expect(sessions[0][:name]).to eq("myapp") # Docker takes precedence (first in list)
    end

    it "returns empty array on unexpected errors" do
      allow(described_class).to receive(:docker_sessions).and_raise(RuntimeError, "boom")

      expect(described_class.discover).to eq([])
    end
  end

  describe ".container_web_ports" do
    let(:container_json) do
      [{
        "Name" => "/myapp",
        "Config" => {
          "Env" => [
            "RUBY_DEBUG_OPEN=true",
            "RUBY_DEBUG_HOST=0.0.0.0",
            "RUBY_DEBUG_PORT=12345",
          ],
        },
        "HostConfig" => {
          "PortBindings" => {
            "3000/tcp" => [{ "HostIp" => "", "HostPort" => "8080" }],
            "12345/tcp" => [{ "HostIp" => "", "HostPort" => "12345" }],
          },
        },
      }].to_json
    end

    context "when Docker has a container matching the debug port" do
      before do
        allow(described_class).to receive(:docker_available?).and_return(true)
        allow(described_class).to receive(:`).with("docker ps -q 2>/dev/null").and_return("abc123\n")
        allow(described_class).to receive(:`).with("docker inspect abc123 2>/dev/null").and_return(container_json)
        allow(described_class).to receive(:tcp_connectable?).and_return(true)
      end

      it "returns web server host ports excluding the debug port" do
        ports = described_class.container_web_ports(12345)
        expect(ports).to eq([8080])
      end
    end

    context "when web port is not connectable" do
      before do
        allow(described_class).to receive(:docker_available?).and_return(true)
        allow(described_class).to receive(:`).with("docker ps -q 2>/dev/null").and_return("abc123\n")
        allow(described_class).to receive(:`).with("docker inspect abc123 2>/dev/null").and_return(container_json)
        allow(described_class).to receive(:tcp_connectable?).and_return(false)
      end

      it "returns empty array" do
        expect(described_class.container_web_ports(12345)).to eq([])
      end
    end

    context "when Docker CLI is not available" do
      before do
        allow(described_class).to receive(:docker_available?).and_return(false)
      end

      it "returns empty array" do
        expect(described_class.container_web_ports(12345)).to eq([])
      end
    end

    context "when no container matches the debug port" do
      let(:other_container_json) do
        [{
          "Name" => "/other",
          "Config" => {
            "Env" => ["RUBY_DEBUG_PORT=99999"],
          },
          "HostConfig" => {
            "PortBindings" => {
              "3000/tcp" => [{ "HostIp" => "", "HostPort" => "3000" }],
            },
          },
        }].to_json
      end

      before do
        allow(described_class).to receive(:docker_available?).and_return(true)
        allow(described_class).to receive(:`).with("docker ps -q 2>/dev/null").and_return("abc123\n")
        allow(described_class).to receive(:`).with("docker inspect abc123 2>/dev/null").and_return(other_container_json)
      end

      it "returns empty array" do
        expect(described_class.container_web_ports(12345)).to eq([])
      end
    end

    context "when container has multiple web ports" do
      let(:multi_port_json) do
        [{
          "Name" => "/myapp",
          "Config" => {
            "Env" => ["RUBY_DEBUG_PORT=12345"],
          },
          "HostConfig" => {
            "PortBindings" => {
              "3000/tcp" => [{ "HostIp" => "", "HostPort" => "3000" }],
              "3035/tcp" => [{ "HostIp" => "", "HostPort" => "3035" }],
              "12345/tcp" => [{ "HostIp" => "", "HostPort" => "12345" }],
            },
          },
        }].to_json
      end

      before do
        allow(described_class).to receive(:docker_available?).and_return(true)
        allow(described_class).to receive(:`).with("docker ps -q 2>/dev/null").and_return("abc123\n")
        allow(described_class).to receive(:`).with("docker inspect abc123 2>/dev/null").and_return(multi_port_json)
        allow(described_class).to receive(:tcp_connectable?).and_return(true)
      end

      it "returns all web ports sorted" do
        ports = described_class.container_web_ports(12345)
        expect(ports).to eq([3000, 3035])
      end
    end

    context "when container has no RUBY_DEBUG_PORT env" do
      let(:no_debug_json) do
        [{
          "Name" => "/webonly",
          "Config" => {
            "Env" => ["RAILS_ENV=production"],
          },
          "HostConfig" => {
            "PortBindings" => {
              "3000/tcp" => [{ "HostIp" => "", "HostPort" => "3000" }],
            },
          },
        }].to_json
      end

      before do
        allow(described_class).to receive(:docker_available?).and_return(true)
        allow(described_class).to receive(:`).with("docker ps -q 2>/dev/null").and_return("abc123\n")
        allow(described_class).to receive(:`).with("docker inspect abc123 2>/dev/null").and_return(no_debug_json)
      end

      it "returns empty array" do
        expect(described_class.container_web_ports(12345)).to eq([])
      end
    end
  end
end
