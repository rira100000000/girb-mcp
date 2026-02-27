# frozen_string_literal: true

RSpec.describe GirbMcp::Tools::Connect do
  let(:client) { build_mock_client }
  let(:manager) { build_mock_manager(client: client) }
  let(:server_context) { { session_manager: manager } }

  describe ".call" do
    before do
      # Prevent pre-connect PID detection from finding real debug sessions
      allow(GirbMcp::DebugClient).to receive(:list_sessions).and_return([])
    end

    it "connects and returns session info" do
      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Connected to debug session")
      expect(text).to include("Session ID:")
      expect(text).to include("PID:")
    end

    it "clears breakpoint specs by default" do
      expect(manager).to receive(:clear_breakpoint_specs)
      described_class.call(server_context: server_context)
    end

    it "does not clear breakpoint specs when restore_breakpoints is true" do
      expect(manager).not_to receive(:clear_breakpoint_specs)
      described_class.call(restore_breakpoints: true, server_context: server_context)
    end

    it "passes connection parameters" do
      expect(manager).to receive(:connect) do |**kwargs, &_block|
        expect(kwargs).to include(
          session_id: "my_session",
          path: "/tmp/sock",
          host: nil,
          port: nil,
        )
        { success: true, pid: "111", output: "ok", session_id: "my_session" }
      end

      described_class.call(
        path: "/tmp/sock",
        session_id: "my_session",
        server_context: server_context,
      )
    end

    it "passes pre_cleanup_pid from resolved target PID" do
      allow(GirbMcp::DebugClient).to receive(:extract_pid)
        .with("/tmp/rdbg-1000/rdbg-99999")
        .and_return(99999)

      # No listen ports
      allow(Dir).to receive(:exist?).and_call_original
      allow(Dir).to receive(:exist?).with("/proc/99999/fd").and_return(false)

      received_pid = nil
      allow(manager).to receive(:connect) do |**kwargs, &_block|
        received_pid = kwargs[:pre_cleanup_pid]
        { success: true, pid: "99999", output: "ok", session_id: "session_99999" }
      end
      allow(manager).to receive(:client).and_return(client)

      described_class.call(path: "/tmp/rdbg-1000/rdbg-99999", server_context: server_context)

      expect(received_pid).to eq(99999)
    end

    it "passes nil pre_cleanup_pid for TCP port connections" do
      received_pid = nil
      allow(manager).to receive(:connect) do |**kwargs, &_block|
        received_pid = kwargs[:pre_cleanup_pid]
        { success: true, pid: "12345", output: "ok", session_id: "session_12345" }
      end
      allow(manager).to receive(:client).and_return(client)

      described_class.call(port: 12345, server_context: server_context)

      expect(received_pid).to be_nil
    end

    it "shows restored breakpoints" do
      allow(manager).to receive(:restore_breakpoints).and_return([
        { spec: "break file.rb:10", output: "#1 BP - Line file.rb:10" },
      ])

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Restored 1 breakpoint(s)")
      expect(text).to include("break file.rb:10")
    end

    it "shows restore errors" do
      allow(manager).to receive(:restore_breakpoints).and_return([
        { spec: "break missing.rb:10", error: "File not found" },
      ])

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Error: File not found")
    end

    it "handles connection errors" do
      allow(manager).to receive(:connect).and_raise(
        GirbMcp::ConnectionError, "Connection refused"
      )

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Error: Connection refused")
    end

    it "includes stdout/stderr capture note" do
      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("stdout/stderr are not captured")
    end

    context "IO-blocked process wake" do
      it "resolves PID from socket path and detects listen ports pre-connect" do
        # Simulate a socket path with PID 54321
        allow(GirbMcp::DebugClient).to receive(:extract_pid)
          .with("/tmp/rdbg-1000/rdbg-54321")
          .and_return(54321)

        # Set up port detection for PID 54321 (port 3000)
        allow(Dir).to receive(:exist?).and_call_original
        allow(Dir).to receive(:exist?).with("/proc/54321/fd").and_return(true)
        allow(Dir).to receive(:foreach).and_call_original
        allow(Dir).to receive(:foreach).with("/proc/54321/fd").and_yield("5")
        allow(File).to receive(:readlink).and_call_original
        allow(File).to receive(:readlink).with("/proc/54321/fd/5").and_return("socket:[88888]")
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with("/proc/54321/net/tcp").and_return(true)
        allow(File).to receive(:exist?).with("/proc/54321/net/tcp6").and_return(false)
        tcp_content = <<~TCP
          sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 00000000:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 88888
        TCP
        allow(File).to receive(:readlines).with("/proc/54321/net/tcp").and_return(tcp_content.lines)

        # manager.connect should receive connect_timeout: 5 and a block
        received_timeout = nil
        received_block = false
        allow(manager).to receive(:connect) do |**kwargs, &block|
          received_timeout = kwargs[:connect_timeout]
          received_block = !block.nil?
          { success: true, pid: "54321", output: "ok", session_id: "session_54321" }
        end
        allow(manager).to receive(:client).and_return(client)

        # Also stub detect_listen_ports for post-connect (uses PID "54321" as string)
        allow(Dir).to receive(:exist?).with("/proc/54321/fd").and_return(true)
        allow(Dir).to receive(:foreach).with("/proc/54321/fd").and_yield("5")
        allow(File).to receive(:readlink).with("/proc/54321/fd/5").and_return("socket:[88888]")
        allow(File).to receive(:exist?).with("/proc/54321/net/tcp").and_return(true)
        allow(File).to receive(:exist?).with("/proc/54321/net/tcp6").and_return(false)
        allow(File).to receive(:readlines).with("/proc/54321/net/tcp").and_return(tcp_content.lines)

        described_class.call(path: "/tmp/rdbg-1000/rdbg-54321", server_context: server_context)

        expect(received_timeout).to eq(5)
        expect(received_block).to be true
      end

      it "resolves PID from auto-discovered single session" do
        allow(GirbMcp::DebugClient).to receive(:list_sessions).and_return([
          { path: "/tmp/rdbg-1000/rdbg-77777", pid: 77777, name: "test" },
        ])

        # No listen ports for this PID (no /proc available)
        allow(Dir).to receive(:exist?).and_call_original
        allow(Dir).to receive(:exist?).with("/proc/77777/fd").and_return(false)

        # connect_timeout should be nil (no listen ports detected)
        received_timeout = nil
        allow(manager).to receive(:connect) do |**kwargs, &_block|
          received_timeout = kwargs[:connect_timeout]
          { success: true, pid: "77777", output: "ok", session_id: "session_77777" }
        end
        allow(manager).to receive(:client).and_return(client)

        described_class.call(server_context: server_context)

        expect(received_timeout).to be_nil
      end

      it "returns nil PID for TCP port connections" do
        # TCP port connection — can't resolve PID pre-connect
        received_timeout = nil
        allow(manager).to receive(:connect) do |**kwargs, &_block|
          received_timeout = kwargs[:connect_timeout]
          { success: true, pid: "12345", output: "ok", session_id: "session_12345" }
        end
        allow(manager).to receive(:client).and_return(client)

        described_class.call(port: 12345, server_context: server_context)

        expect(received_timeout).to be_nil
      end

      it "shows woke status when wake callback was triggered" do
        allow(GirbMcp::DebugClient).to receive(:extract_pid)
          .with("/tmp/rdbg-1000/rdbg-54321")
          .and_return(54321)

        # Set up port detection (port 3000)
        allow(Dir).to receive(:exist?).and_call_original
        allow(Dir).to receive(:exist?).with("/proc/54321/fd").and_return(true)
        allow(Dir).to receive(:foreach).and_call_original
        allow(Dir).to receive(:foreach).with("/proc/54321/fd").and_yield("5")
        allow(File).to receive(:readlink).and_call_original
        allow(File).to receive(:readlink).with("/proc/54321/fd/5").and_return("socket:[88888]")
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with("/proc/54321/net/tcp").and_return(true)
        allow(File).to receive(:exist?).with("/proc/54321/net/tcp6").and_return(false)
        tcp_content = <<~TCP
          sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 00000000:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 88888
        TCP
        allow(File).to receive(:readlines).with("/proc/54321/net/tcp").and_return(tcp_content.lines)

        # Simulate: manager.connect calls the block (simulating timeout+wake)
        allow(manager).to receive(:connect) do |**_kwargs, &block|
          block&.call
          { success: true, pid: "54321", output: "ok", session_id: "session_54321" }
        end
        allow(manager).to receive(:client).and_return(client)

        response = described_class.call(path: "/tmp/rdbg-1000/rdbg-54321", server_context: server_context)
        text = response_text(response)

        expect(text).to include("Woke IO-blocked process via HTTP (port 3000)")
      end

      it "does not show woke status when callback was not triggered" do
        # No listen ports pre-connect → block not triggered
        response = described_class.call(server_context: server_context)
        text = response_text(response)

        expect(text).not_to include("Woke IO-blocked")
      end
    end

    context "when in signal trap context" do
      it "auto-escapes trap context via step on connect" do
        allow(client).to receive(:in_trap_context?).and_return(true)
        allow(client).to receive(:escape_trap_context!).and_return("[1, 5] in some_file.rb")

        response = described_class.call(server_context: server_context)
        text = response_text(response)

        expect(client).to have_received(:in_trap_context?)
        expect(client).to have_received(:escape_trap_context!)
        expect(text).to include("Escaped signal trap context")
        expect(text).to include("thread operations now available")
      end

      it "warns when trap context escape fails and no ports available" do
        allow(client).to receive(:in_trap_context?).and_return(true)
        allow(client).to receive(:escape_trap_context!).and_return(nil)

        response = described_class.call(server_context: server_context)
        text = response_text(response)

        expect(text).to include("WARNING: Running in signal trap context")
        expect(text).to include("ThreadError")
        expect(text).to include("trigger_request")
        expect(text).to include("set_breakpoint")
      end

      it "skips auto-escape when auto_escape is false" do
        allow(client).to receive(:in_trap_context?).and_return(true)
        allow(client).to receive(:escape_trap_context!).and_return(nil)

        response = described_class.call(auto_escape: false, server_context: server_context)
        text = response_text(response)

        expect(text).to include("WARNING: Running in signal trap context")
        # Should not attempt auto-escape even if ports were available
        expect(client).not_to have_received(:continue_and_wait)
      end

      it "does not try step escape when listen ports are available (prevents protocol desync)" do
        allow(client).to receive(:in_trap_context?).and_return(true)

        # Set up port detection (port 3000)
        allow(Dir).to receive(:exist?).and_call_original
        allow(Dir).to receive(:exist?).with("/proc/12345/fd").and_return(true)
        allow(Dir).to receive(:foreach).and_call_original
        allow(Dir).to receive(:foreach).with("/proc/12345/fd").and_yield("5")
        allow(File).to receive(:readlink).and_call_original
        allow(File).to receive(:readlink).with("/proc/12345/fd/5").and_return("socket:[99999]")
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with("/proc/12345/net/tcp").and_return(true)
        allow(File).to receive(:exist?).with("/proc/12345/net/tcp6").and_return(false)
        tcp_content = <<~TCP
          sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 00000000:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 99999
        TCP
        allow(File).to receive(:readlines).with("/proc/12345/net/tcp").and_return(tcp_content.lines)

        described_class.call(server_context: server_context)

        # escape_trap_context! (which sends `next`) should NOT be called
        # when ports are available — it causes protocol desync on IO-blocked processes
        expect(client).not_to have_received(:escape_trap_context!)
      end
    end

    context "auto-escape trap context via breakpoint" do
      let(:tcp_content) do
        <<~TCP
          sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 00000000:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 99999
        TCP
      end

      before do
        # Set up trap context
        allow(client).to receive(:in_trap_context?).and_return(true)
        allow(client).to receive(:escape_trap_context!).and_return(nil)

        # Set up port detection (port 3000)
        allow(Dir).to receive(:exist?).and_call_original
        allow(Dir).to receive(:exist?).with("/proc/12345/fd").and_return(true)
        allow(Dir).to receive(:foreach).and_call_original
        allow(Dir).to receive(:foreach).with("/proc/12345/fd").and_yield("5")
        allow(File).to receive(:readlink).and_call_original
        allow(File).to receive(:readlink).with("/proc/12345/fd/5").and_return("socket:[99999]")
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with("/proc/12345/net/tcp").and_return(true)
        allow(File).to receive(:exist?).with("/proc/12345/net/tcp6").and_return(false)
        allow(File).to receive(:readlines).with("/proc/12345/net/tcp").and_return(tcp_content.lines)

        # Rails detection
        allow(client).to receive(:send_command)
          .with("p defined?(Rails)")
          .and_return('=> "constant"')
      end

      it "auto-escapes via route-based breakpoint and HTTP request" do
        # Route info
        allow(client).to receive(:send_command)
          .with(/routes\.count/)
          .and_return("=> 5")
        allow(client).to receive(:send_command)
          .with(/routes\.select.*first/)
          .and_return('=> "GET     /users users#index"')

        # Rails.root for file path construction
        allow(client).to receive(:send_command)
          .with("p Rails.root.to_s")
          .and_return('=> "/app"')

        # File existence check + action line detection (combined expression)
        allow(client).to receive(:send_command)
          .with(/File\.exist\?.*users_controller.*File\.readlines/)
          .and_return("=> 5")

        # Breakpoint setting
        allow(client).to receive(:send_command)
          .with("break /app/app/controllers/users_controller.rb:5")
          .and_return("#1  BP - Line  /app/app/controllers/users_controller.rb:5")

        # Continue and wait returns breakpoint hit
        allow(client).to receive(:continue_and_wait).and_return({ type: :breakpoint, output: "Stop by #1" })

        # Breakpoint cleanup
        allow(client).to receive(:send_command)
          .with("delete 1")
          .and_return("")

        response = described_class.call(server_context: server_context)
        text = response_text(response)

        expect(text).to include("Auto-escaped signal trap context")
        expect(text).to include("/users")
        expect(text).not_to include("WARNING: Running in signal trap")
      end

      it "falls back to framework method when no routes match" do
        # Routes exist but file detection fails for all
        allow(client).to receive(:send_command)
          .with(/routes\.count/)
          .and_return("=> 5")
        allow(client).to receive(:send_command)
          .with(/routes\.select.*first/)
          .and_return('=> "GET     /users users#index"')

        # Rails.root
        allow(client).to receive(:send_command)
          .with("p Rails.root.to_s")
          .and_return('=> "/app"')

        # File doesn't exist / line detection fails
        allow(client).to receive(:send_command)
          .with(/File\.exist\?.*File\.readlines/)
          .and_return("=> false")

        # Framework fallback: ActionController::Metal#dispatch
        allow(client).to receive(:send_command)
          .with(/ActionController::Metal\.instance_method.*dispatch.*source_location/)
          .and_return('=> ["/gems/actionpack/lib/action_controller/metal.rb", 210]')

        # Breakpoint setting (line + 1 = 211)
        allow(client).to receive(:send_command)
          .with("break /gems/actionpack/lib/action_controller/metal.rb:211")
          .and_return("#1  BP - Line  metal.rb:211")

        # Continue and wait returns breakpoint hit
        allow(client).to receive(:continue_and_wait).and_return({ type: :breakpoint, output: "Stop by #1" })

        # Breakpoint cleanup
        allow(client).to receive(:send_command)
          .with("delete 1")
          .and_return("")

        response = described_class.call(server_context: server_context)
        text = response_text(response)

        expect(text).to include("Auto-escaped signal trap context")
        expect(text).to include("/users") # Uses real GET path, not "/"
      end

      it "framework fallback uses / when no GET routes available" do
        # No routes at all
        allow(client).to receive(:send_command)
          .with(/routes\.count/)
          .and_return("=> 0")
        allow(client).to receive(:send_command)
          .with(/routes\.select.*first/)
          .and_return('=> ""')

        # Framework fallback
        allow(client).to receive(:send_command)
          .with(/ActionController::Metal\.instance_method.*dispatch.*source_location/)
          .and_return('=> ["/gems/actionpack/lib/action_controller/metal.rb", 210]')

        # Breakpoint setting (line + 1 = 211)
        allow(client).to receive(:send_command)
          .with("break /gems/actionpack/lib/action_controller/metal.rb:211")
          .and_return("#1  BP - Line  metal.rb:211")

        allow(client).to receive(:continue_and_wait).and_return({ type: :breakpoint, output: "Stop by #1" })
        allow(client).to receive(:send_command).with("delete 1").and_return("")

        response = described_class.call(server_context: server_context)
        text = response_text(response)

        expect(text).to include("Auto-escaped signal trap context")
      end

      it "falls back to manual escape instructions when auto-escape fails" do
        # Route info available but file not found
        allow(client).to receive(:send_command)
          .with(/routes\.count/)
          .and_return("=> 5")
        allow(client).to receive(:send_command)
          .with(/routes\.select.*first/)
          .and_return('=> "GET     /users users#index"')

        # Rails.root
        allow(client).to receive(:send_command)
          .with("p Rails.root.to_s")
          .and_return('=> "/app"')

        # File detection fails
        allow(client).to receive(:send_command)
          .with(/File\.exist\?.*File\.readlines/)
          .and_return("=> false")

        # Framework fallback also fails
        allow(client).to receive(:send_command)
          .with(/ActionController::Metal\.instance_method.*dispatch.*source_location/)
          .and_return("=> nil")

        response = described_class.call(server_context: server_context)
        text = response_text(response)

        expect(text).to include("WARNING: Running in signal trap context")
      end
    end

    context "when not in trap context" do
      it "does not attempt escape" do
        allow(client).to receive(:in_trap_context?).and_return(false)

        response = described_class.call(server_context: server_context)
        text = response_text(response)

        expect(client).not_to have_received(:escape_trap_context!)
        expect(text).not_to include("trap context")
      end
    end

    context "Rails auto-summary" do
      before do
        allow(client).to receive(:send_command)
          .with("p defined?(Rails)")
          .and_return('=> "constant"')
      end

      it "shows Rails tools with what each provides" do
        response = described_class.call(server_context: server_context)
        text = response_text(response)

        expect(text).to include("Rails tools")
        expect(text).to include("rails_info")
        expect(text).to include("database config")
        expect(text).to include("rails_routes")
        expect(text).to include("full route list")
        expect(text).to include("rails_model")
        expect(text).to include("column schema")
      end

      it "shows app info when available" do
        allow(client).to receive(:send_command)
          .with("p Rails.application.class.module_parent_name")
          .and_return('=> "MyApp"')
        allow(client).to receive(:send_command)
          .with("p Rails::VERSION::STRING")
          .and_return('=> "7.1.3"')
        allow(client).to receive(:send_command)
          .with("p Rails.env")
          .and_return('=> "development"')

        response = described_class.call(server_context: server_context)
        text = response_text(response)

        expect(text).to include("=== Rails: MyApp (development) ===")
        expect(text).to include("Rails 7.1.3")
      end

      it "shows route summary when available" do
        # Route count
        allow(client).to receive(:send_command)
          .with(/routes\.count/)
          .and_return('=> 15')
        # Route samples
        allow(client).to receive(:send_command)
          .with(/routes\.select.*first/)
          .and_return('=> "GET     /users users#index\nPOST    /users users#create"')

        response = described_class.call(server_context: server_context)
        text = response_text(response)

        expect(text).to include("Routes: 15 defined")
        expect(text).to include("users#index")
      end

      it "shows model files when available" do
        allow(client).to receive(:send_command)
          .with(/Dir\.glob.*models/)
          .and_return('=> "user, post, comment"')

        response = described_class.call(server_context: server_context)
        text = response_text(response)

        expect(text).to include("Models: user, post, comment")
      end

      it "shows next steps when stopped in gem code" do
        allow(manager).to receive(:connect).and_return({
          success: true, pid: "12345",
          output: "# No sourcefile available for /gems/puma-6.4.0/lib/puma/single.rb",
          session_id: "session_12345",
        })

        response = described_class.call(server_context: server_context)
        text = response_text(response)

        expect(text).to include("To debug your application code")
        expect(text).to include("set_breakpoint")
        expect(text).to include("trigger_request")
      end

      it "shows app code actions when stopped in app code" do
        allow(client).to receive(:send_command)
          .with("p defined?(Rails)")
          .and_return('=> "constant"')
        allow(manager).to receive(:connect).and_return({
          success: true, pid: "12345",
          output: "[1, 10] in app/controllers/users_controller.rb",
          session_id: "session_12345",
        })

        response = described_class.call(server_context: server_context)
        text = response_text(response)

        expect(text).not_to include("To debug your application code")
        expect(text).to include("You are in application code")
        expect(text).to include("get_context")
        expect(text).to include("evaluate_code")
      end

      it "shows escaped context message when auto-escape succeeded" do
        allow(client).to receive(:in_trap_context?).and_return(true)
        allow(client).to receive(:send_command)
          .with("p defined?(Rails)")
          .and_return('=> "constant"')

        # Set up port detection (port 3000)
        allow(Dir).to receive(:exist?).and_call_original
        allow(Dir).to receive(:exist?).with("/proc/12345/fd").and_return(true)
        allow(Dir).to receive(:foreach).and_call_original
        allow(Dir).to receive(:foreach).with("/proc/12345/fd").and_yield("5")
        allow(File).to receive(:readlink).and_call_original
        allow(File).to receive(:readlink).with("/proc/12345/fd/5").and_return("socket:[99999]")
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with("/proc/12345/net/tcp").and_return(true)
        allow(File).to receive(:exist?).with("/proc/12345/net/tcp6").and_return(false)
        tcp_content = <<~TCP
          sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 00000000:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 99999
        TCP
        allow(File).to receive(:readlines).with("/proc/12345/net/tcp").and_return(tcp_content.lines)

        # Route info
        allow(client).to receive(:send_command)
          .with(/routes\.count/)
          .and_return("=> 5")
        allow(client).to receive(:send_command)
          .with(/routes\.select.*first/)
          .and_return('=> "GET     /users users#index"')
        allow(client).to receive(:send_command)
          .with("p Rails.root.to_s")
          .and_return('=> "/app"')
        allow(client).to receive(:send_command)
          .with(/File\.exist\?.*users_controller.*File\.readlines/)
          .and_return("=> 5")
        allow(client).to receive(:send_command)
          .with("break /app/app/controllers/users_controller.rb:5")
          .and_return("#1  BP - Line  /app/app/controllers/users_controller.rb:5")
        allow(client).to receive(:continue_and_wait).and_return({ type: :breakpoint, output: "Stop by #1" })
        allow(client).to receive(:send_command).with("delete 1").and_return("")

        response = described_class.call(server_context: server_context)
        text = response_text(response)

        expect(text).to include("You are now in application code context")
        expect(text).to include("All tools")
      end

      it "does not show Rails summary for non-Rails processes" do
        allow(client).to receive(:send_command)
          .with("p defined?(Rails)")
          .and_return("=> nil")

        response = described_class.call(server_context: server_context)
        text = response_text(response)

        expect(text).not_to include("Rails tools")
        expect(text).not_to include("=== Rails")
      end
    end

    context "listen port detection" do
      it "shows listening ports owned by the process" do
        # Simulate /proc/PID/fd with a socket inode
        allow(Dir).to receive(:exist?).and_call_original
        allow(Dir).to receive(:exist?).with("/proc/12345/fd").and_return(true)
        allow(Dir).to receive(:foreach).and_call_original
        allow(Dir).to receive(:foreach).with("/proc/12345/fd").and_yield("5")
        allow(File).to receive(:readlink).and_call_original
        allow(File).to receive(:readlink).with("/proc/12345/fd/5").and_return("socket:[99999]")

        # Simulate /proc/PID/net/tcp with a LISTEN socket matching the inode
        tcp_content = <<~TCP
          sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 00000000:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 99999
        TCP
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with("/proc/12345/net/tcp").and_return(true)
        allow(File).to receive(:exist?).with("/proc/12345/net/tcp6").and_return(false)
        allow(File).to receive(:readlines).with("/proc/12345/net/tcp").and_return(tcp_content.lines)

        response = described_class.call(server_context: server_context)
        text = response_text(response)

        expect(text).to include("Listening on:")
        expect(text).to include("http://127.0.0.1:3000")
      end

      it "filters out ports not owned by the process" do
        # Process owns socket with inode 11111
        allow(Dir).to receive(:exist?).and_call_original
        allow(Dir).to receive(:exist?).with("/proc/12345/fd").and_return(true)
        allow(Dir).to receive(:foreach).and_call_original
        allow(Dir).to receive(:foreach).with("/proc/12345/fd").and_yield("5")
        allow(File).to receive(:readlink).and_call_original
        allow(File).to receive(:readlink).with("/proc/12345/fd/5").and_return("socket:[11111]")

        # net/tcp has two LISTEN sockets, only one matches the process inode
        tcp_content = <<~TCP
          sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 00000000:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 11111
           1: 00000000:0D3D 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 22222
        TCP
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with("/proc/12345/net/tcp").and_return(true)
        allow(File).to receive(:exist?).with("/proc/12345/net/tcp6").and_return(false)
        allow(File).to receive(:readlines).with("/proc/12345/net/tcp").and_return(tcp_content.lines)

        response = described_class.call(server_context: server_context)
        text = response_text(response)

        expect(text).to include("http://127.0.0.1:3000")
        expect(text).not_to include("3389") # port 0x0D3D = 3389, not owned by process
      end

      it "does not show listening ports when /proc is unavailable" do
        allow(Dir).to receive(:exist?).and_call_original
        allow(Dir).to receive(:exist?).with("/proc/12345/fd").and_return(false)

        response = described_class.call(server_context: server_context)
        text = response_text(response)

        expect(text).not_to include("Listening on:")
      end
    end

    context "escape info caching for auto_repause" do
      it "caches listen_ports and escape_target for Rails apps with ports" do
        # Set up as Rails app
        allow(client).to receive(:send_command)
          .with("p defined?(Rails)")
          .and_return('=> "constant"')

        # Set up port detection (port 3000)
        allow(Dir).to receive(:exist?).and_call_original
        allow(Dir).to receive(:exist?).with("/proc/12345/fd").and_return(true)
        allow(Dir).to receive(:foreach).and_call_original
        allow(Dir).to receive(:foreach).with("/proc/12345/fd").and_yield("5")
        allow(File).to receive(:readlink).and_call_original
        allow(File).to receive(:readlink).with("/proc/12345/fd/5").and_return("socket:[99999]")
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with("/proc/12345/net/tcp").and_return(true)
        allow(File).to receive(:exist?).with("/proc/12345/net/tcp6").and_return(false)
        tcp_content = <<~TCP
          sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 00000000:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 99999
        TCP
        allow(File).to receive(:readlines).with("/proc/12345/net/tcp").and_return(tcp_content.lines)

        # Framework fallback (Metal#dispatch)
        allow(client).to receive(:send_command)
          .with(/ActionController::Metal\.instance_method.*dispatch.*source_location/)
          .and_return('=> ["/gems/actionpack/lib/action_controller/metal.rb", 210]')

        described_class.call(server_context: server_context)

        expect(client).to have_received(:listen_ports=).with([3000])
        expect(client).to have_received(:escape_target=).with(
          { file: "/gems/actionpack/lib/action_controller/metal.rb", line: 211, path: "/" }
        )
      end

      it "caches escape_target with GET path from routes" do
        # Set up as Rails app
        allow(client).to receive(:send_command)
          .with("p defined?(Rails)")
          .and_return('=> "constant"')

        # Set up port detection
        allow(Dir).to receive(:exist?).and_call_original
        allow(Dir).to receive(:exist?).with("/proc/12345/fd").and_return(true)
        allow(Dir).to receive(:foreach).and_call_original
        allow(Dir).to receive(:foreach).with("/proc/12345/fd").and_yield("5")
        allow(File).to receive(:readlink).and_call_original
        allow(File).to receive(:readlink).with("/proc/12345/fd/5").and_return("socket:[99999]")
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with("/proc/12345/net/tcp").and_return(true)
        allow(File).to receive(:exist?).with("/proc/12345/net/tcp6").and_return(false)
        tcp_content = <<~TCP
          sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 00000000:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 99999
        TCP
        allow(File).to receive(:readlines).with("/proc/12345/net/tcp").and_return(tcp_content.lines)

        # Route info with GET path
        allow(client).to receive(:send_command)
          .with(/routes\.count/)
          .and_return("=> 5")
        allow(client).to receive(:send_command)
          .with(/routes\.select.*first/)
          .and_return('=> "GET     /users users#index"')

        # Framework fallback
        allow(client).to receive(:send_command)
          .with(/ActionController::Metal\.instance_method.*dispatch.*source_location/)
          .and_return('=> ["/gems/actionpack/lib/action_controller/metal.rb", 210]')

        described_class.call(server_context: server_context)

        expect(client).to have_received(:escape_target=).with(
          { file: "/gems/actionpack/lib/action_controller/metal.rb", line: 211, path: "/users" }
        )
      end

      it "does not set escape_target for non-Rails processes" do
        allow(client).to receive(:send_command)
          .with("p defined?(Rails)")
          .and_return("=> nil")

        described_class.call(server_context: server_context)

        expect(client).to have_received(:listen_ports=).with([])
        expect(client).not_to have_received(:escape_target=)
      end

      it "does not set escape_target when no listen ports" do
        # Set up as Rails app but no ports
        allow(client).to receive(:send_command)
          .with("p defined?(Rails)")
          .and_return('=> "constant"')

        described_class.call(server_context: server_context)

        expect(client).to have_received(:listen_ports=).with([])
        expect(client).not_to have_received(:escape_target=)
      end
    end

    context "SIGINT force-quit handler" do
      it "installs SIGINT handler on connect" do
        allow(client).to receive(:send_command)
          .with(/\$_girb_orig_int/)
          .and_return('=> :ok')

        described_class.call(server_context: server_context)

        expect(client).to have_received(:send_command).with(/\$_girb_orig_int/)
      end

      it "does not fail connect when handler installation fails" do
        allow(client).to receive(:send_command)
          .with(/\$_girb_orig_int/)
          .and_raise(GirbMcp::ConnectionError, "lost connection")

        response = described_class.call(server_context: server_context)
        text = response_text(response)

        expect(text).to include("Connected to debug session")
      end
    end

    context "clearing existing breakpoints on connect" do
      it "clears existing breakpoints by default" do
        bp_output = "#0  BP - Line  app/controllers/users_controller.rb:10\n" \
                    "#1  BP - Line  app/models/user.rb:20\n"
        allow(client).to receive(:send_command)
          .with("info breakpoints", timeout: 3)
          .and_return(bp_output)
        allow(client).to receive(:send_command)
          .with("delete 0", timeout: 2)
          .and_return("")
        allow(client).to receive(:send_command)
          .with("delete 1", timeout: 2)
          .and_return("")

        described_class.call(server_context: server_context)

        expect(client).to have_received(:send_command).with("info breakpoints", timeout: 3)
        expect(client).to have_received(:send_command).with("delete 0", timeout: 2)
        expect(client).to have_received(:send_command).with("delete 1", timeout: 2)
      end

      it "does not clear breakpoints when restore_breakpoints is true" do
        described_class.call(restore_breakpoints: true, server_context: server_context)

        expect(client).not_to have_received(:send_command).with("info breakpoints", timeout: 3)
      end

      it "handles empty breakpoint list" do
        allow(client).to receive(:send_command)
          .with("info breakpoints", timeout: 3)
          .and_return("")

        described_class.call(server_context: server_context)

        expect(client).not_to have_received(:send_command).with(/\Adelete \d/, timeout: 2)
      end

      it "continues connect when breakpoint deletion fails" do
        allow(client).to receive(:send_command)
          .with("info breakpoints", timeout: 3)
          .and_raise(GirbMcp::ConnectionError, "lost connection")

        response = described_class.call(server_context: server_context)
        text = response_text(response)

        expect(text).to include("Connected to debug session")
      end
    end

    context "Docker TCP fallback for listen port detection" do
      let(:client) { build_mock_client(remote: true) }
      let(:manager) { build_mock_manager(client: client) }

      before do
        # TCP port connection: PID is nil pre-connect, no /proc-based detection
        allow(Dir).to receive(:exist?).and_call_original
        allow(Dir).to receive(:exist?).with("/proc/12345/fd").and_return(false)
      end

      it "falls back to container_web_ports when detect_listen_ports is empty and remote" do
        allow(GirbMcp::TcpSessionDiscovery).to receive(:container_web_ports)
          .with(12345)
          .and_return([3000])

        response = described_class.call(port: 12345, server_context: server_context)
        text = response_text(response)

        expect(GirbMcp::TcpSessionDiscovery).to have_received(:container_web_ports).with(12345)
        expect(text).to include("Listening on:")
        expect(text).to include("http://127.0.0.1:3000")
      end

      it "triggers auto-escape with Docker-discovered ports" do
        allow(GirbMcp::TcpSessionDiscovery).to receive(:container_web_ports)
          .with(12345)
          .and_return([3000])

        allow(client).to receive(:in_trap_context?).and_return(true)

        # Rails detection
        allow(client).to receive(:send_command)
          .with("p defined?(Rails)")
          .and_return('=> "constant"')

        # Route info
        allow(client).to receive(:send_command)
          .with(/routes\.count/)
          .and_return("=> 0")
        allow(client).to receive(:send_command)
          .with(/routes\.select.*first/)
          .and_return('=> ""')

        # Framework fallback
        allow(client).to receive(:send_command)
          .with(/ActionController::Metal\.instance_method.*dispatch.*source_location/)
          .and_return('=> ["/gems/actionpack/lib/action_controller/metal.rb", 210]')

        # Breakpoint + escape
        allow(client).to receive(:send_command)
          .with("break /gems/actionpack/lib/action_controller/metal.rb:211")
          .and_return("#1  BP - Line  metal.rb:211")
        allow(client).to receive(:continue_and_wait)
          .and_return({ type: :breakpoint, output: "Stop by #1" })
        allow(client).to receive(:send_command)
          .with("delete 1")
          .and_return("")

        response = described_class.call(port: 12345, server_context: server_context)
        text = response_text(response)

        expect(text).to include("Auto-escaped signal trap context")
      end

      it "does not call container_web_ports for non-remote connections" do
        local_client = build_mock_client(remote: false)
        local_manager = build_mock_manager(client: local_client)
        local_context = { session_manager: local_manager }

        allow(GirbMcp::TcpSessionDiscovery).to receive(:container_web_ports)

        described_class.call(port: 12345, server_context: local_context)

        expect(GirbMcp::TcpSessionDiscovery).not_to have_received(:container_web_ports)
      end

      it "does not call container_web_ports when no port specified" do
        allow(GirbMcp::TcpSessionDiscovery).to receive(:container_web_ports)

        described_class.call(server_context: server_context)

        expect(GirbMcp::TcpSessionDiscovery).not_to have_received(:container_web_ports)
      end

      it "does not call container_web_ports when detect_listen_ports finds ports" do
        # Set up /proc-based detection to find port 3000
        allow(Dir).to receive(:exist?).with("/proc/12345/fd").and_return(true)
        allow(Dir).to receive(:foreach).and_call_original
        allow(Dir).to receive(:foreach).with("/proc/12345/fd").and_yield("5")
        allow(File).to receive(:readlink).and_call_original
        allow(File).to receive(:readlink).with("/proc/12345/fd/5").and_return("socket:[99999]")
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with("/proc/12345/net/tcp").and_return(true)
        allow(File).to receive(:exist?).with("/proc/12345/net/tcp6").and_return(false)
        tcp_content = <<~TCP
          sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 00000000:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 99999
        TCP
        allow(File).to receive(:readlines).with("/proc/12345/net/tcp").and_return(tcp_content.lines)

        allow(GirbMcp::TcpSessionDiscovery).to receive(:container_web_ports)

        described_class.call(port: 12345, server_context: server_context)

        expect(GirbMcp::TcpSessionDiscovery).not_to have_received(:container_web_ports)
      end
    end
  end
end
