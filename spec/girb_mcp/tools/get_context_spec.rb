# frozen_string_literal: true

RSpec.describe GirbMcp::Tools::GetContext do
  let(:client) { build_mock_client }
  let(:manager) { build_mock_manager(client: client) }
  let(:server_context) { { session_manager: manager } }

  describe ".call" do
    before do
      allow(client).to receive(:send_command).with("list").and_return("=> 1| x = 1")
      allow(client).to receive(:send_command).with("info locals").and_return("x = 1")
      allow(client).to receive(:send_command).with("info ivars").and_return("@name = \"Alice\"")
      allow(client).to receive(:send_command).with("bt").and_return("#0 main at file.rb:1")
      allow(client).to receive(:send_command).with("info breakpoints").and_return("No breakpoints")
    end

    it "returns all context sections" do
      response = described_class.call(server_context: server_context)
      text = response_text(response)

      expect(text).to include("=== Current Location ===")
      expect(text).to include("=== Local Variables ===")
      expect(text).to include("=== Instance Variables ===")
      expect(text).to include("=== Call Stack ===")
      expect(text).to include("=== Breakpoints ===")
    end

    it "includes tip about inspect tools" do
      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("evaluate_code")
      expect(text).to include("inspect_object")
    end

    it "annotates truncated values" do
      allow(client).to receive(:send_command).with("info locals").and_return(
        "long_var = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, ...]"
      )

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("[truncated]")
      expect(text).to include("1 truncated")
    end

    it "shows return event annotation when at return event" do
      # bt output with #=> indicates a return event
      allow(client).to receive(:send_command).with("bt").and_return(
        "=>#0  Object#foo at file.rb:10 #=> 42\n  #1 main at file.rb:1"
      )

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Stop Event: Return")
      expect(text).to include("ALREADY been executed")
      expect(text).to include("#=>")
      expect(text).to include("%return")
    end

    it "shows exception context at return event" do
      allow(client).to receive(:send_command).with("bt").and_return(
        "=>#0  Object#foo at file.rb:10 #=> nil\n  #1 main at file.rb:1"
      )
      allow(client).to receive(:check_current_exception).and_return("RuntimeError: boom")

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Stop Event: Return")
      expect(text).to include("Exception in scope: RuntimeError: boom")
    end

    it "does not show return event annotation at non-return events" do
      # bt output without #=> — normal line event
      allow(client).to receive(:send_command).with("bt").and_return(
        "=>#0  UsersController#index at app/controllers/users_controller.rb:5\n  #1 main at file.rb:1"
      )

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).not_to include("Stop Event: Return")
    end

    it "handles timeout on individual sections" do
      allow(client).to receive(:send_command).with("bt").and_raise(
        GirbMcp::TimeoutError, "timeout"
      )

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("=== Call Stack ===")
      expect(text).to include("(timed out)")
    end

    it "handles session error" do
      allow(manager).to receive(:client).and_raise(GirbMcp::SessionError, "No session")

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Error: No session")
    end

    context "when in signal trap context" do
      before do
        allow(client).to receive(:trap_context).and_return(true)
        allow(client).to receive(:in_trap_context?).and_return(true)
      end

      it "shows trap context warning as first section" do
        response = described_class.call(server_context: server_context)
        text = response_text(response)

        expect(text).to include("=== Context: Signal Trap ===")
        expect(text).to include("Restricted: DB queries, require, autoloading, method breakpoints")
        expect(text).to include("Available: evaluate_code")
        expect(text).to include("To escape: set_breakpoint(file, line) + trigger_request")
        # Ensure it appears before the Current Location section
        trap_pos = text.index("Context: Signal Trap")
        location_pos = text.index("Current Location")
        expect(trap_pos).to be < location_pos
      end
    end

    context "when not in trap context" do
      it "does not show trap context warning" do
        response = described_class.call(server_context: server_context)
        text = response_text(response)
        expect(text).not_to include("Context: Signal Trap")
      end
    end

    context "trap context caching" do
      it "uses cached trap_context value instead of calling in_trap_context?" do
        allow(client).to receive(:trap_context).and_return(true)

        response = described_class.call(server_context: server_context)
        text = response_text(response)

        expect(text).to include("=== Context: Signal Trap ===")
        # Should NOT call in_trap_context? when cached value is available
        expect(client).not_to have_received(:in_trap_context?)
      end

      it "falls back to in_trap_context? when cache is nil" do
        allow(client).to receive(:trap_context).and_return(nil)
        allow(client).to receive(:in_trap_context?).and_return(false)

        response = described_class.call(server_context: server_context)
        text = response_text(response)

        expect(text).not_to include("Context: Signal Trap")
        expect(client).to have_received(:in_trap_context?)
      end
    end
  end

  describe "call stack summarization" do
    let(:short_stack) do
      (0..5).map { |i| "##{i}  Object#method#{i} at app/models/user.rb:#{i + 1}" }.join("\n")
    end

    let(:long_stack) do
      lines = []
      lines << "#0  UsersController#show at app/controllers/users_controller.rb:10"
      lines << "#1  ActionController::Rendering#process_action at /gems/actionpack-7.0.0/lib/action_controller/metal/rendering.rb:20"
      lines << "#2  AbstractController::Callbacks#process_action at /gems/actionpack-7.0.0/lib/abstract_controller/callbacks.rb:30"
      lines << "#3  ActionController::Rescue#process_action at /gems/actionpack-7.0.0/lib/action_controller/metal/rescue.rb:40"
      lines << "#4  ActiveSupport::Callbacks#run_callbacks at /gems/activesupport-7.0.0/lib/active_support/callbacks.rb:50"
      lines << "#5  ActionController::Metal#dispatch at /gems/actionpack-7.0.0/lib/action_controller/metal.rb:60"
      lines << "#6  ActionDispatch::Routing at /gems/actionpack-7.0.0/lib/action_dispatch/routing.rb:70"
      lines << "#7  Rack::Handler at /gems/rack-2.2.0/lib/rack/handler.rb:80"
      lines << "#8  Puma::Request at /gems/puma-5.6.0/lib/puma/request.rb:90"
      lines << "#9  Puma::Server at /gems/puma-5.6.0/lib/puma/server.rb:100"
      lines << "#10 ApplicationController#authenticate at app/controllers/application_controller.rb:15"
      lines << "#11 Rack::Middleware at /gems/rack-2.2.0/lib/rack/middleware.rb:110"
      lines << "#12 Rack::Session at /gems/rack-2.2.0/lib/rack/session.rb:120"
      lines << "#13 Rack::Runtime at /gems/rack-2.2.0/lib/rack/runtime.rb:130"
      lines << "#14 Puma::ThreadPool at /gems/puma-5.6.0/lib/puma/thread_pool.rb:140"
      lines << "#15 [C] Thread#main at <internal>"
      lines.join("\n") + "\n"
    end

    before do
      allow(client).to receive(:send_command).with("list").and_return("=> 1| x = 1")
      allow(client).to receive(:send_command).with("info locals").and_return("x = 1")
      allow(client).to receive(:send_command).with("info ivars").and_return("")
      allow(client).to receive(:send_command).with("info breakpoints").and_return("No breakpoints")
    end

    it "does not summarize short stacks" do
      allow(client).to receive(:send_command).with("bt").and_return(short_stack)

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).not_to include("framework frames")
      expect(text).to include("Object#method0")
    end

    it "collapses consecutive framework frames in long stacks" do
      allow(client).to receive(:send_command).with("bt").and_return(long_stack)

      response = described_class.call(server_context: server_context)
      text = response_text(response)

      # App frames should be preserved
      expect(text).to include("UsersController#show")
      expect(text).to include("ApplicationController#authenticate")

      # Framework frames should be collapsed
      expect(text).to include("framework frames")
      expect(text).not_to include("Rack::Handler")
    end

    it "shows gem names in collapse summary" do
      allow(client).to receive(:send_command).with("bt").and_return(long_stack)

      response = described_class.call(server_context: server_context)
      text = response_text(response)

      expect(text).to match(/actionpack|rack|puma/)
    end

    it "extracts gem names from rbenv paths (not ruby version numbers)" do
      rbenv_stack = [
        "#0  UsersController#show at app/controllers/users_controller.rb:10",
        *2.upto(12).map { |i|
          "##{i}  SomeClass#method at ~/.rbenv/versions/3.3.4/lib/ruby/gems/3.3.0/gems/actionpack-8.1.2/lib/file.rb:#{i}"
        },
        *13.upto(16).map { |i|
          "##{i}  Puma::Server at ~/.rbenv/versions/3.3.4/lib/ruby/gems/3.3.0/gems/puma-7.2.0/lib/puma/server.rb:#{i}"
        },
      ].join("\n") + "\n"

      allow(client).to receive(:send_command).with("bt").and_return(rbenv_stack)

      response = described_class.call(server_context: server_context)
      text = response_text(response)

      expect(text).to include("actionpack")
      expect(text).to include("puma")
      expect(text).not_to include("(3.3.0)")
    end
  end

  describe "TRUNCATION_PATTERN" do
    it "matches truncated arrays" do
      expect("x = [1, 2, 3, ...]").to match(GirbMcp::Tools::GetContext::TRUNCATION_PATTERN)
    end

    it "matches truncated hashes" do
      expect('x = {"a"=>1, "b"=>2, ...}').to match(GirbMcp::Tools::GetContext::TRUNCATION_PATTERN)
    end

    it "matches truncated strings" do
      expect('x = "very long string..."').to match(GirbMcp::Tools::GetContext::TRUNCATION_PATTERN)
    end

    it "does not match non-truncated values" do
      expect("x = [1, 2, 3]").not_to match(GirbMcp::Tools::GetContext::TRUNCATION_PATTERN)
    end
  end

  describe "pending HTTP notification" do
    before do
      allow(client).to receive(:send_command).with("list").and_return("=> 1: code")
      allow(client).to receive(:send_command).with("info locals").and_return("x = 1")
      allow(client).to receive(:send_command).with("info ivars").and_return("")
      allow(client).to receive(:send_command).with("bt").and_return("#0 main at test.rb:1")
      allow(client).to receive(:send_command).with("info breakpoints").and_return("")
    end

    it "includes note when HTTP response is ready" do
      holder = { response: { status: "201 Created" }, error: nil, done: true }
      allow(client).to receive(:pending_http).and_return(
        { holder: holder, method: "POST", url: "http://localhost:3000/users" },
      )

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("HTTP response received (201 Created)")
    end

    it "does not include note when no pending HTTP" do
      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).not_to include("HTTP response")
    end
  end
end
