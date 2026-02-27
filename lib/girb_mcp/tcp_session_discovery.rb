# frozen_string_literal: true

require "socket"
require "json"

module GirbMcp
  module TcpSessionDiscovery
    module_function

    # Discover TCP debug sessions from Docker containers and local processes.
    # Returns array of { host:, port:, name:, source: } hashes.
    def discover
      (docker_sessions + local_tcp_sessions).uniq { |s| [s[:host], s[:port]] }
    rescue StandardError
      []
    end

    # Discover debug sessions from Docker containers with RUBY_DEBUG_PORT.
    def docker_sessions
      return [] unless docker_available?

      container_ids = `docker ps -q 2>/dev/null`.strip.split("\n")
      return [] if container_ids.empty?

      sessions = []
      container_ids.each do |id|
        session = inspect_container(id)
        sessions << session if session
      end
      sessions
    rescue StandardError
      []
    end

    # Discover debug sessions from local processes with RUBY_DEBUG_PORT in /proc/*/environ.
    def local_tcp_sessions
      return [] unless File.directory?("/proc")

      sessions = []
      Dir.glob("/proc/[0-9]*/environ").each do |environ_path|
        session = inspect_local_process(environ_path)
        sessions << session if session
      rescue Errno::EACCES, Errno::ENOENT
        next
      end
      sessions
    rescue StandardError
      []
    end

    # Check if a TCP host:port is connectable.
    def tcp_connectable?(host, port, timeout: 2)
      addr = Socket.getaddrinfo(host, nil, nil, :STREAM)
      sockaddr = Socket.sockaddr_in(port, addr[0][3])
      socket = Socket.new(Socket.const_get(addr[0][0]), Socket::SOCK_STREAM, 0)

      begin
        socket.connect_nonblock(sockaddr)
      rescue IO::WaitWritable
        IO.select(nil, [socket], nil, timeout) ? socket.connect_nonblock(sockaddr) : (return false)
      rescue Errno::EISCONN
        # Already connected — success
      end

      true
    rescue StandardError
      false
    ensure
      socket&.close
    end

    # Find web server host ports for a Docker container identified by its debug port.
    # Reverse-looks up which container has RUBY_DEBUG_PORT matching debug_port,
    # then returns all other host-mapped ports that are TCP-connectable.
    # Returns an array of port numbers (e.g., [3000]) or [] if not found.
    def container_web_ports(debug_port, host: "localhost")
      return [] unless docker_available?

      container_ids = `docker ps -q 2>/dev/null`.strip.split("\n")
      container_ids.each do |id|
        json_str = `docker inspect #{id} 2>/dev/null`
        data = JSON.parse(json_str)
        container = data[0]
        next unless container

        # Check if this container has the matching debug port
        env_list = container.dig("Config", "Env") || []
        container_debug_port = env_list
          .find { |e| e.start_with?("RUBY_DEBUG_PORT=") }
          &.split("=", 2)&.last&.to_i
        next unless container_debug_port == debug_port

        # Extract all host-mapped ports except the debug port itself
        port_bindings = container.dig("HostConfig", "PortBindings") || {}
        web_ports = []
        port_bindings.each do |key, bindings|
          container_port = key.split("/").first.to_i
          next if container_port == debug_port
          next unless bindings.is_a?(Array) && !bindings.empty?

          host_port = bindings[0]["HostPort"]&.to_i
          next unless host_port&.positive?
          next unless tcp_connectable?(host, host_port, timeout: 1)

          web_ports << host_port
        end

        return web_ports.sort
      end

      []
    rescue StandardError
      []
    end

    # --- Private helpers ---

    def docker_available?
      system("docker", "info", out: File::NULL, err: File::NULL)
    rescue StandardError
      false
    end

    def inspect_container(container_id)
      json_str = `docker inspect #{container_id} 2>/dev/null`
      return nil if json_str.strip.empty?

      data = JSON.parse(json_str)
      container = data[0]
      return nil unless container

      env_list = container.dig("Config", "Env") || []
      debug_port = nil
      debug_host = nil

      env_list.each do |env|
        key, value = env.split("=", 2)
        case key
        when "RUBY_DEBUG_PORT"
          debug_port = value&.to_i
        when "RUBY_DEBUG_HOST"
          debug_host = value
        end
      end
      return nil unless debug_port

      host_port = resolve_host_port(container, debug_port)
      return nil unless host_port

      host, port = host_port
      return nil unless tcp_connectable?(host, port)

      name = container.fetch("Name", "").sub(%r{\A/}, "")
      name = container_id[0, 12] if name.empty?

      { host: host, port: port, name: name, source: :docker }
    rescue StandardError
      nil
    end

    def resolve_host_port(container, container_port)
      port_bindings = container.dig("HostConfig", "PortBindings") || {}

      # Look for a binding matching the debug port (e.g., "12345/tcp")
      binding_key = port_bindings.keys.find { |k| k.start_with?("#{container_port}/") }
      if binding_key
        bindings = port_bindings[binding_key]
        if bindings.is_a?(Array) && !bindings.empty?
          host_port = bindings[0]["HostPort"]&.to_i
          return ["localhost", host_port] if host_port && host_port > 0
        end
      end

      # Fallback: NetworkSettings — use container IP directly
      networks = container.dig("NetworkSettings", "Networks") || {}
      networks.each_value do |net|
        ip = net["IPAddress"]
        return [ip, container_port] if ip && !ip.empty?
      end

      nil
    end

    def inspect_local_process(environ_path)
      environ = File.read(environ_path)
      envs = environ.split("\0")

      debug_port = nil
      envs.each do |env|
        key, value = env.split("=", 2)
        if key == "RUBY_DEBUG_PORT"
          debug_port = value&.to_i
          break
        end
      end
      return nil unless debug_port

      pid = environ_path[%r{/proc/(\d+)/}, 1]
      return nil unless pid

      # Skip if this process is ourselves
      return nil if pid.to_i == Process.pid

      host = "localhost"
      return nil unless tcp_connectable?(host, debug_port)

      name = process_name(pid)
      { host: host, port: debug_port, name: name, source: :local }
    rescue StandardError
      nil
    end

    def process_name(pid)
      cmdline = File.read("/proc/#{pid}/cmdline").split("\0")
      # Find the Ruby script name from the command line
      ruby_idx = cmdline.index { |arg| arg.match?(/ruby|rails|rdbg|bundle/) }
      if ruby_idx && cmdline[ruby_idx + 1]
        File.basename(cmdline[ruby_idx + 1])
      else
        "pid-#{pid}"
      end
    rescue StandardError
      "pid-#{pid}"
    end
  end
end
