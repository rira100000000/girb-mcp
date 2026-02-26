# frozen_string_literal: true

RSpec.describe GirbMcp::Tools::EvaluateCode do
  let(:client) { build_mock_client }
  let(:manager) { build_mock_manager(client: client) }
  let(:server_context) { { session_manager: manager } }

  describe ".call" do
    before do
      # Default: stdout redirect succeeds, no error, empty captured stdout
      allow(client).to receive(:send_command).and_return("")
    end

    it "evaluates code and returns result" do
      allow(client).to receive(:send_command).with(/\$__girb_err=nil; pp/).and_return("=> 42")
      allow(client).to receive(:send_command).with("p $__girb_err").and_return("=> nil")
      allow(client).to receive(:send_command).with("$stdout = $__girb_old; p $__girb_cap.string").and_return('=> ""')

      response = described_class.call(code: "1 + 1", server_context: server_context)
      text = response_text(response)
      expect(text).to include("42")
    end

    it "handles evaluation error" do
      allow(client).to receive(:send_command).with(/\$__girb_err=nil; pp/).and_return("=> nil")
      allow(client).to receive(:send_command).with("p $__girb_err").and_return(
        '=> "NameError: undefined local variable \'x\'"'
      )
      allow(client).to receive(:send_command).with("$stdout = $__girb_old; p $__girb_cap.string").and_return('=> ""')

      response = described_class.call(code: "x", server_context: server_context)
      text = response_text(response)
      expect(text).to include("Error:")
      expect(text).to include("NameError")
    end

    it "captures stdout output" do
      allow(client).to receive(:send_command).with(/\$__girb_err=nil; pp/).and_return("=> nil")
      allow(client).to receive(:send_command).with("p $__girb_err").and_return('=> nil')
      allow(client).to receive(:send_command).with("$stdout = $__girb_old; p $__girb_cap.string").and_return(
        '=> "hello world\n"'
      )

      response = described_class.call(code: 'puts "hello world"', server_context: server_context)
      text = response_text(response)
      expect(text).to include("Captured stdout:")
      expect(text).to include("hello world")
    end

    it "suppresses captured stdout when it duplicates the return value (pp output)" do
      # pp(5) writes "5\n" to $stdout AND returns => 5 — same content, show only once
      allow(client).to receive(:send_command).with(/\$__girb_err=nil; pp/).and_return("=> 5")
      allow(client).to receive(:send_command).with("p $__girb_err").and_return('=> nil')
      allow(client).to receive(:send_command).with("$stdout = $__girb_old; p $__girb_cap.string").and_return(
        '=> "5\n"'
      )

      response = described_class.call(code: "Order.completed.count", server_context: server_context)
      text = response_text(response)
      expect(text).to include("5")
      expect(text).not_to include("Captured stdout")
      expect(text).not_to include("Return value")
    end

    it "shows both sections when captured stdout has additional content" do
      # puts "debug info"; 42 → captured has "debug info\n42\n", return value is "=> 42"
      allow(client).to receive(:send_command).with(/\$__girb_err=nil; pp/).and_return("=> 42")
      allow(client).to receive(:send_command).with("p $__girb_err").and_return('=> nil')
      allow(client).to receive(:send_command).with("$stdout = $__girb_old; p $__girb_cap.string").and_return(
        '=> "debug info\n42\n"'
      )

      response = described_class.call(code: 'puts "debug info"; 42', server_context: server_context)
      text = response_text(response)
      expect(text).to include("Return value:")
      expect(text).to include("Captured stdout:")
      expect(text).to include("debug info")
    end

    it "propagates session error from client lookup" do
      allow(manager).to receive(:client).and_raise(
        GirbMcp::SessionError, "No active session"
      )

      # EvaluateCode's client lookup is outside the begin/rescue block,
      # so the SessionError propagates to the MCP framework.
      expect {
        described_class.call(code: "1", server_context: server_context)
      }.to raise_error(GirbMcp::SessionError, /No active session/)
    end

    it "handles timeout error" do
      allow(client).to receive(:send_command).with(/\$__girb_err=nil; pp/).and_raise(
        GirbMcp::TimeoutError, "Timeout after 15s"
      )

      response = described_class.call(code: "sleep(100)", server_context: server_context)
      text = response_text(response)
      expect(text).to include("Timeout")
    end

    it "restores stdout on error" do
      allow(client).to receive(:send_command).with(/\$__girb_err=nil; pp/).and_raise(
        GirbMcp::ConnectionError, "lost"
      )

      response = described_class.call(code: "x", server_context: server_context)
      text = response_text(response)
      expect(text).to include("Error:")
    end

    it "suspends and restores catch breakpoints" do
      bp_info = "#1  BP - Catch  \"NoMethodError\"\n#2  BP - Line  file.rb:10"
      allow(client).to receive(:send_command).with("info break").and_return(bp_info)
      allow(client).to receive(:send_command).with("delete 1").and_return("")
      allow(client).to receive(:send_command).with("catch NoMethodError").and_return("")
      allow(client).to receive(:send_command).with(/\$__girb_err=nil; pp/).and_return("=> 42")
      allow(client).to receive(:send_command).with("p $__girb_err").and_return('=> nil')
      allow(client).to receive(:send_command).with("$stdout = $__girb_old; p $__girb_cap.string").and_return('=> ""')

      described_class.call(code: "1 + 1", server_context: server_context)

      expect(client).to have_received(:send_command).with("delete 1")
      expect(client).to have_received(:send_command).with("catch NoMethodError")
    end

    it "uses Base64 encoding for multi-line code" do
      allow(client).to receive(:send_command).with(/Base64/).and_return("=> 3")
      allow(client).to receive(:send_command).with("p $__girb_err").and_return('=> nil')
      allow(client).to receive(:send_command).with("$stdout = $__girb_old; p $__girb_cap.string").and_return('=> ""')

      described_class.call(code: "a = 1\na + 2", server_context: server_context)
      expect(client).to have_received(:send_command).with(/Base64/)
    end

    it "uses Base64 encoding for non-ASCII code" do
      allow(client).to receive(:send_command).with(/Base64/).and_return('=> "hello"')
      allow(client).to receive(:send_command).with("p $__girb_err").and_return('=> nil')
      allow(client).to receive(:send_command).with("$stdout = $__girb_old; p $__girb_cap.string").and_return('=> ""')

      described_class.call(code: 'puts "日本語"', server_context: server_context)
      expect(client).to have_received(:send_command).with(/Base64/)
    end

    context "trap context annotation" do
      it "appends [trap context] when in trap context" do
        client_in_trap = build_mock_client(trap_context: true)
        manager_in_trap = build_mock_manager(client: client_in_trap)

        allow(client_in_trap).to receive(:send_command).and_return("")
        allow(client_in_trap).to receive(:send_command).with(/\$__girb_err=nil; pp/).and_return("=> 42")
        allow(client_in_trap).to receive(:send_command).with("p $__girb_err").and_return("=> nil")
        allow(client_in_trap).to receive(:send_command).with("$stdout = $__girb_old; p $__girb_cap.string").and_return('=> ""')
        allow(client_in_trap).to receive(:send_command).with("frame").and_return("#0 main at file.rb:1")

        response = described_class.call(
          code: "1 + 1",
          server_context: { session_manager: manager_in_trap },
        )
        text = response_text(response)
        expect(text).to include("[trap context]")
      end

      it "does not append [trap context] when not in trap context" do
        allow(client).to receive(:send_command).with(/\$__girb_err=nil; pp/).and_return("=> 42")
        allow(client).to receive(:send_command).with("p $__girb_err").and_return("=> nil")
        allow(client).to receive(:send_command).with("$stdout = $__girb_old; p $__girb_cap.string").and_return('=> ""')
        allow(client).to receive(:send_command).with("frame").and_return("#0 main at file.rb:1")

        response = described_class.call(code: "1 + 1", server_context: server_context)
        text = response_text(response)
        expect(text).not_to include("[trap context]")
      end
    end

    context "frame info display" do
      it "prepends frame info when not at frame 0" do
        allow(client).to receive(:send_command).with(/\$__girb_err=nil; pp/).and_return("=> 42")
        allow(client).to receive(:send_command).with("p $__girb_err").and_return("=> nil")
        allow(client).to receive(:send_command).with("$stdout = $__girb_old; p $__girb_cap.string").and_return('=> ""')
        allow(client).to receive(:send_command).with("frame").and_return(
          "#2  Object#method_a at /app/models/user.rb:25"
        )

        response = described_class.call(code: "1 + 1", server_context: server_context)
        text = response_text(response)
        expect(text).to start_with("Frame #2:")
        expect(text).to include("Object#method_a")
      end

      it "does not prepend frame info at frame 0" do
        allow(client).to receive(:send_command).with(/\$__girb_err=nil; pp/).and_return("=> 42")
        allow(client).to receive(:send_command).with("p $__girb_err").and_return("=> nil")
        allow(client).to receive(:send_command).with("$stdout = $__girb_old; p $__girb_cap.string").and_return('=> ""')
        allow(client).to receive(:send_command).with("frame").and_return(
          "#0  UsersController#show at app/controllers/users_controller.rb:10"
        )

        response = described_class.call(code: "1 + 1", server_context: server_context)
        text = response_text(response)
        expect(text).not_to include("Frame #0")
      end

      it "ignores frame errors gracefully" do
        allow(client).to receive(:send_command).with(/\$__girb_err=nil; pp/).and_return("=> 42")
        allow(client).to receive(:send_command).with("p $__girb_err").and_return("=> nil")
        allow(client).to receive(:send_command).with("$stdout = $__girb_old; p $__girb_cap.string").and_return('=> ""')
        allow(client).to receive(:send_command).with("frame").and_raise(
          GirbMcp::TimeoutError, "timeout"
        )

        response = described_class.call(code: "1 + 1", server_context: server_context)
        text = response_text(response)
        expect(text).to include("42")
        expect(text).not_to include("Frame")
      end
    end

    context "safety warnings" do
      it "prepends warning for dangerous code" do
        allow(client).to receive(:send_command).with(/\$__girb_err=nil; pp/).and_return("=> :ok")
        allow(client).to receive(:send_command).with("p $__girb_err").and_return("=> nil")
        allow(client).to receive(:send_command).with("$stdout = $__girb_old; p $__girb_cap.string").and_return('=> ""')
        allow(client).to receive(:send_command).with("frame").and_return("#0 main at file.rb:1")

        response = described_class.call(code: 'File.write("/tmp/x", "data")', server_context: server_context)
        text = response_text(response)

        expect(text).to include("WARNING:")
        expect(text).to include("File system operations:")
        expect(text).to include("The code was executed. Result follows:")
        expect(text).to include(":ok")
      end

      it "does not prepend warning for safe code" do
        allow(client).to receive(:send_command).with(/\$__girb_err=nil; pp/).and_return("=> 42")
        allow(client).to receive(:send_command).with("p $__girb_err").and_return("=> nil")
        allow(client).to receive(:send_command).with("$stdout = $__girb_old; p $__girb_cap.string").and_return('=> ""')
        allow(client).to receive(:send_command).with("frame").and_return("#0 main at file.rb:1")

        response = described_class.call(code: "user.name", server_context: server_context)
        text = response_text(response)

        expect(text).not_to include("WARNING:")
        expect(text).not_to include("Result follows:")
      end

      it "prepends warning in trap context" do
        client_in_trap = build_mock_client(trap_context: true)
        manager_in_trap = build_mock_manager(client: client_in_trap)

        allow(client_in_trap).to receive(:send_command).and_return("")
        allow(client_in_trap).to receive(:send_command).with(/p\(begin/).and_return('=> :ok')

        response = described_class.call(
          code: 'system("ls")',
          server_context: { session_manager: manager_in_trap },
        )
        text = response_text(response)

        expect(text).to include("WARNING:")
        expect(text).to include("System command execution:")
        expect(text).to include("[trap context]")
      end

      it "includes execution result even when warning is present" do
        allow(client).to receive(:send_command).with(/\$__girb_err=nil; pp/).and_return("=> true")
        allow(client).to receive(:send_command).with("p $__girb_err").and_return("=> nil")
        allow(client).to receive(:send_command).with("$stdout = $__girb_old; p $__girb_cap.string").and_return('=> ""')
        allow(client).to receive(:send_command).with("frame").and_return("#0 main at file.rb:1")

        response = described_class.call(code: "User.destroy_all", server_context: server_context)
        text = response_text(response)

        expect(text).to include("WARNING:")
        expect(text).to include("Destructive data operations:")
        expect(text).to include("true")
      end

      it "detects multiple dangerous categories" do
        allow(client).to receive(:send_command).with(/\$__girb_err=nil; pp/).and_return("=> nil")
        allow(client).to receive(:send_command).with("p $__girb_err").and_return("=> nil")
        allow(client).to receive(:send_command).with("$stdout = $__girb_old; p $__girb_cap.string").and_return('=> ""')
        allow(client).to receive(:send_command).with("frame").and_return("#0 main at file.rb:1")

        response = described_class.call(
          code: 'system("curl http://example.com"); File.write("/tmp/x", result)',
          server_context: server_context,
        )
        text = response_text(response)

        expect(text).to include("File system operations:")
        expect(text).to include("System command execution:")
      end
    end

    context "ThreadError detection" do
      it "shows trap context guidance when ThreadError occurs in evaluation" do
        allow(client).to receive(:send_command).with(/\$__girb_err=nil; pp/).and_return("=> nil")
        allow(client).to receive(:send_command).with("p $__girb_err").and_return(
          '=> "ThreadError: can\'t be called from trap context"'
        )
        allow(client).to receive(:send_command).with("$stdout = $__girb_old; p $__girb_cap.string").and_return('=> ""')

        response = described_class.call(code: "User.first", server_context: server_context)
        text = response_text(response)

        expect(text).to include("ThreadError")
        expect(text).to include("signal trap context")
        expect(text).to include("set_breakpoint")
        expect(text).to include("trigger_request")
      end

      it "does not show trap context guidance for non-ThreadError errors" do
        allow(client).to receive(:send_command).with(/\$__girb_err=nil; pp/).and_return("=> nil")
        allow(client).to receive(:send_command).with("p $__girb_err").and_return(
          '=> "NameError: undefined local variable \'x\'"'
        )
        allow(client).to receive(:send_command).with("$stdout = $__girb_old; p $__girb_cap.string").and_return('=> ""')

        response = described_class.call(code: "x", server_context: server_context)
        text = response_text(response)

        expect(text).to include("NameError")
        expect(text).not_to include("trap context")
      end
    end
  end
end
