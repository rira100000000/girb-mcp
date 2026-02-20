# frozen_string_literal: true

RSpec.describe GirbMcp::Tools::ContinueExecution do
  let(:client) { build_mock_client }
  let(:manager) { build_mock_manager(client: client) }
  let(:server_context) { { session_manager: manager } }

  describe ".call" do
    it "resumes execution and returns output" do
      allow(client).to receive(:send_continue).and_return(
        "Stop by #1  BP - Line  file.rb:10 (line)\n=> 10| x = 1"
      )

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Execution resumed")
      expect(text).to include("file.rb:10")
    end

    it "detects program exit on empty output" do
      allow(client).to receive(:send_continue).and_return("")
      allow(client).to receive(:process_finished?).and_return(true)

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Program finished")
    end

    it "cleans up one-shot breakpoints" do
      allow(client).to receive(:send_continue).and_return("Stop by #3  BP - Line  f.rb:5 (line)")
      expect(client).to receive(:cleanup_one_shot_breakpoints)

      described_class.call(server_context: server_context)
    end

    it "annotates breakpoint hit events" do
      allow(client).to receive(:send_continue).and_return(
        "Stop by #1  BP - Line  f.rb:10 (return)"
      )

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Stop event (return)")
    end

    it "handles SessionError for ended sessions" do
      allow(client).to receive(:send_continue).and_raise(
        GirbMcp::SessionError.new("session ended", final_output: "last output")
      )

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Program finished")
    end

    it "handles SessionError for other errors" do
      allow(client).to receive(:send_continue).and_raise(
        GirbMcp::SessionError.new("Some other error")
      )

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Error: Some other error")
    end

    context "when TimeoutError occurs" do
      before do
        allow(client).to receive(:send_continue).and_raise(
          GirbMcp::TimeoutError, "timeout"
        )
      end

      it "shows 'no breakpoint hit' when breakpoints exist" do
        allow(client).to receive(:send_command)
          .with("info breakpoints")
          .and_return("#1  BP - Line  file.rb:10 (line)")

        response = described_class.call(server_context: server_context)
        text = response_text(response)
        expect(text).to include("no breakpoint was hit")
        expect(text).to include("still running")
      end

      it "shows 'resumed successfully' when no breakpoints" do
        allow(client).to receive(:send_command)
          .with("info breakpoints")
          .and_return("No breakpoints")

        response = described_class.call(server_context: server_context)
        text = response_text(response)
        expect(text).to include("resumed successfully")
        expect(text).to include("no breakpoints set")
      end

      it "includes session lifetime note" do
        allow(client).to receive(:send_command)
          .with("info breakpoints")
          .and_return("No breakpoints")

        response = described_class.call(server_context: server_context)
        text = response_text(response)
        expect(text).to include("30 minutes of inactivity")
        expect(text).to include("Any tool call resets the timer")
      end
    end

    it "handles ConnectionError for lost connection" do
      allow(client).to receive(:send_continue).and_raise(
        GirbMcp::ConnectionError.new("Connection lost", final_output: "output")
      )

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Program finished")
    end

    it "handles ConnectionError for other errors" do
      allow(client).to receive(:send_continue).and_raise(
        GirbMcp::ConnectionError.new("Connection refused")
      )

      response = described_class.call(server_context: server_context)
      text = response_text(response)
      expect(text).to include("Error: Connection refused")
    end

    context "pending HTTP response" do
      it "appends HTTP response when pending_http is present" do
        http_holder = { response: { status: "200 OK", headers: {}, body: '{"ok": true}' }, error: nil, done: true }
        http_thread = Thread.new {} # already finished
        http_thread.join

        allow(client).to receive(:pending_http).and_return({
          thread: http_thread, holder: http_holder, method: "GET", url: "http://localhost:3000/users",
        })

        allow(client).to receive(:send_continue).and_return(
          "Stop by #1  BP - Line  file.rb:20 (line)\n=> 20| render json: @users"
        )

        response = described_class.call(server_context: server_context)
        text = response_text(response)
        expect(text).to include("Execution resumed")
        expect(text).to include("--- HTTP Response ---")
        expect(text).to include("HTTP GET http://localhost:3000/users")
        expect(text).to include("200 OK")
      end

      it "appends HTTP error when request failed" do
        http_holder = { response: nil, error: StandardError.new("connection refused"), done: true }
        http_thread = Thread.new {} # already finished
        http_thread.join

        allow(client).to receive(:pending_http).and_return({
          thread: http_thread, holder: http_holder, method: "POST", url: "http://localhost:3000/users",
        })

        allow(client).to receive(:send_continue).and_return(
          "Stop by #1  BP - Line  file.rb:20 (line)"
        )

        response = described_class.call(server_context: server_context)
        text = response_text(response)
        expect(text).to include("--- HTTP Response ---")
        expect(text).to include("Request error: connection refused")
      end

      it "does not append HTTP section when no pending_http" do
        allow(client).to receive(:pending_http).and_return(nil)
        allow(client).to receive(:send_continue).and_return(
          "Stop by #1  BP - Line  file.rb:20 (line)"
        )

        response = described_class.call(server_context: server_context)
        text = response_text(response)
        expect(text).not_to include("--- HTTP Response ---")
      end

      it "appends HTTP response on SessionError" do
        http_holder = { response: { status: "200 OK", headers: {}, body: "ok" }, error: nil, done: true }
        http_thread = Thread.new {}
        http_thread.join

        allow(client).to receive(:pending_http).and_return({
          thread: http_thread, holder: http_holder, method: "GET", url: "http://localhost:3000/",
        })

        allow(client).to receive(:send_continue).and_raise(
          GirbMcp::SessionError.new("session ended", final_output: "done")
        )

        response = described_class.call(server_context: server_context)
        text = response_text(response)
        expect(text).to include("--- HTTP Response ---")
        expect(text).to include("200 OK")
      end

      it "appends HTTP response on TimeoutError" do
        http_holder = { response: { status: "200 OK", headers: {}, body: "ok" }, error: nil, done: true }
        http_thread = Thread.new {}
        http_thread.join

        allow(client).to receive(:pending_http).and_return({
          thread: http_thread, holder: http_holder, method: "GET", url: "http://localhost:3000/",
        })

        allow(client).to receive(:send_continue).and_raise(GirbMcp::TimeoutError, "timeout")

        response = described_class.call(server_context: server_context)
        text = response_text(response)
        expect(text).to include("--- HTTP Response ---")
        expect(text).to include("200 OK")
      end
    end
  end
end
