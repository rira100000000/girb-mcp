# frozen_string_literal: true

RSpec.describe GirbMcp::Tools::TriggerRequest do
  let(:client) { build_mock_client }
  let(:manager) { build_mock_manager(client: client) }
  let(:server_context) { { session_manager: manager } }

  # Shared HTTP mocking helpers
  let(:mock_http) do
    http = instance_double(Net::HTTP)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:use_ssl=)
    http
  end

  def stub_http_response(code: "200", message: "OK", body: '{"status": "ok"}',
                         headers: { "content-type" => ["application/json"] }, request_class: Net::HTTP::Get)
    stub_request = instance_double(request_class)
    allow(stub_request).to receive(:[]=)
    allow(stub_request).to receive(:body=)
    allow(request_class).to receive(:new).and_return(stub_request)

    body_str = body.dup.force_encoding("UTF-8")
    mock_response = instance_double(Net::HTTPResponse,
      code: code,
      message: message,
      to_hash: headers)
    allow(mock_response).to receive(:body).and_return(body_str)
    allow(mock_http).to receive(:request).and_return(mock_response)
    allow(Net::HTTP).to receive(:new).and_return(mock_http)

    mock_response
  end

  describe ".call" do
    it "sends HTTP request and returns response without debug session" do
      allow(manager).to receive(:client).and_raise(GirbMcp::SessionError, "No session")
      stub_http_response

      response = described_class.call(
        method: "GET",
        url: "http://localhost:3000/api/status",
        server_context: server_context,
      )
      text = response_text(response)
      expect(text).to include("200")
    end

    context "auto-resume behavior" do
      it "resumes paused process and waits for breakpoint" do
        stub_http_response

        allow(client).to receive(:ensure_paused).and_return("")
        allow(client).to receive(:continue_and_wait).and_return({
          type: :breakpoint,
          output: "Stop by #1  BP - Line  app/controllers/users_controller.rb:10 (line)\n=> 10| @user = User.find(params[:id])",
        })

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/users/1",
          server_context: server_context,
        )
        text = response_text(response)

        expect(text).to include("Breakpoint hit")
        expect(text).to include("users_controller.rb:10")
        expect(text).to include("request sent")
        expect(text).to include("continue_execution")
      end

      it "waits for breakpoint when process is already running" do
        stub_http_response

        allow(client).to receive(:ensure_paused).and_return(nil) # process running
        allow(client).to receive(:wait_for_breakpoint).and_return({
          type: :breakpoint,
          output: "Stop by #1  BP - Line  app/controllers/users_controller.rb:10 (line)",
        })

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/users/1",
          server_context: server_context,
        )
        text = response_text(response)

        expect(text).to include("Breakpoint hit")
        expect(client).not_to have_received(:continue_and_wait)
      end

      it "returns HTTP response when interrupted (no breakpoint hit)" do
        stub_http_response

        allow(client).to receive(:ensure_paused).and_return("")
        allow(client).to receive(:continue_and_wait).and_return({
          type: :interrupted,
          output: "",
        })

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/users",
          server_context: server_context,
        )
        text = response_text(response)

        expect(text).to include("No breakpoint hit")
        expect(text).to include("200")
      end

      it "returns HTTP response when continue times out" do
        stub_http_response

        allow(client).to receive(:ensure_paused).and_return("")
        allow(client).to receive(:continue_and_wait).and_return({
          type: :timeout,
          output: "",
        })

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/users",
          server_context: server_context,
        )
        text = response_text(response)

        # HTTP completed, so we show the response even though continue timed out
        expect(text).to include("No breakpoint hit")
        expect(text).to include("200")
      end

      it "shows diagnostic message when HTTP also fails" do
        allow(Net::HTTP).to receive(:new).and_raise(StandardError, "connection refused")

        allow(client).to receive(:ensure_paused).and_return("")
        allow(client).to receive(:continue_and_wait).and_return({
          type: :timeout,
          output: "",
        })

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/users",
          server_context: server_context,
        )
        text = response_text(response)

        expect(text).to include("Request error")
        expect(text).to include("connection refused")
      end

      it "handles pending breakpoint output from ensure_paused" do
        stub_http_response

        allow(client).to receive(:ensure_paused).and_return(
          "Stop by #2  BP - Line  app/models/user.rb:5 (line)\n=> 5| validates :email",
        )

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/users",
          server_context: server_context,
        )
        text = response_text(response)

        expect(text).to include("Breakpoint hit")
        expect(text).to include("user.rb:5")
        # Should NOT call continue_and_wait since breakpoint was already in pending output
        expect(client).not_to have_received(:continue_and_wait)
      end

      it "annotates breakpoint stop events" do
        stub_http_response

        allow(client).to receive(:ensure_paused).and_return("")
        allow(client).to receive(:continue_and_wait).and_return({
          type: :breakpoint,
          output: "Stop by #1  BP - Line  f.rb:10 (return)",
        })

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/users",
          server_context: server_context,
        )
        text = response_text(response)

        expect(text).to include("Stop event (return)")
      end

      it "cleans up one-shot breakpoints on hit" do
        stub_http_response

        allow(client).to receive(:ensure_paused).and_return("")
        allow(client).to receive(:continue_and_wait).and_return({
          type: :breakpoint,
          output: "Stop by #3  BP - Line  f.rb:5 (line)",
        })

        described_class.call(
          method: "GET",
          url: "http://localhost:3000/users",
          server_context: server_context,
        )

        expect(client).to have_received(:cleanup_one_shot_breakpoints)
      end

      it "handles debug session error gracefully" do
        stub_http_response

        allow(client).to receive(:ensure_paused).and_raise(
          GirbMcp::ConnectionError, "Connection lost",
        )

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/users",
          server_context: server_context,
        )
        text = response_text(response)

        expect(text).to include("Debug session lost")
      end
    end

    context "Content-Type auto-detection" do
      before do
        allow(manager).to receive(:client).and_raise(GirbMcp::SessionError, "No session")
      end

      it "auto-detects JSON body" do
        stub_request = instance_double(Net::HTTP::Post)
        allow(stub_request).to receive(:[]=)
        allow(stub_request).to receive(:body=)
        allow(Net::HTTP::Post).to receive(:new).and_return(stub_request)

        body_str = '{"ok": true}'.dup.force_encoding("UTF-8")
        mock_response = instance_double(Net::HTTPResponse,
          code: "201", message: "Created",
          to_hash: { "content-type" => ["application/json"] })
        allow(mock_response).to receive(:body).and_return(body_str)
        allow(mock_http).to receive(:request).and_return(mock_response)
        allow(Net::HTTP).to receive(:new).and_return(mock_http)

        described_class.call(
          method: "POST",
          url: "http://localhost:3000/users",
          body: '{"name": "Alice"}',
          server_context: server_context,
        )

        expect(stub_request).to have_received(:[]=).with("Content-Type", "application/json")
      end

      it "auto-detects form-urlencoded body" do
        stub_request = instance_double(Net::HTTP::Post)
        allow(stub_request).to receive(:[]=)
        allow(stub_request).to receive(:body=)
        allow(Net::HTTP::Post).to receive(:new).and_return(stub_request)

        body_str = "ok".dup.force_encoding("UTF-8")
        mock_response = instance_double(Net::HTTPResponse,
          code: "200", message: "OK",
          to_hash: { "content-type" => ["text/html"] })
        allow(mock_response).to receive(:body).and_return(body_str)
        allow(mock_http).to receive(:request).and_return(mock_response)
        allow(Net::HTTP).to receive(:new).and_return(mock_http)

        described_class.call(
          method: "POST",
          url: "http://localhost:3000/users",
          body: "name=Alice&email=alice@example.com",
          server_context: server_context,
        )

        expect(stub_request).to have_received(:[]=).with("Content-Type", "application/x-www-form-urlencoded")
      end

      it "does not override explicit Content-Type" do
        stub_request = instance_double(Net::HTTP::Post)
        allow(stub_request).to receive(:[]=)
        allow(stub_request).to receive(:body=)
        allow(Net::HTTP::Post).to receive(:new).and_return(stub_request)

        body_str = "ok".dup.force_encoding("UTF-8")
        mock_response = instance_double(Net::HTTPResponse,
          code: "200", message: "OK",
          to_hash: {})
        allow(mock_response).to receive(:body).and_return(body_str)
        allow(mock_http).to receive(:request).and_return(mock_response)
        allow(Net::HTTP).to receive(:new).and_return(mock_http)

        described_class.call(
          method: "POST",
          url: "http://localhost:3000/upload",
          headers: { "Content-Type" => "multipart/form-data" },
          body: '{"data": true}',
          server_context: server_context,
        )

        # Should NOT set Content-Type to application/json since explicit header provided
        expect(stub_request).to have_received(:[]=).with("Content-Type", "multipart/form-data")
      end
    end

    context "cookie management" do
      it "sends cookies as Cookie header" do
        allow(manager).to receive(:client).and_raise(GirbMcp::SessionError, "No session")

        stub_request = instance_double(Net::HTTP::Get)
        allow(stub_request).to receive(:[]=)
        allow(stub_request).to receive(:body=)
        allow(Net::HTTP::Get).to receive(:new).and_return(stub_request)

        body_str = "ok".dup.force_encoding("UTF-8")
        mock_response = instance_double(Net::HTTPResponse,
          code: "200", message: "OK",
          to_hash: {})
        allow(mock_response).to receive(:body).and_return(body_str)
        allow(mock_http).to receive(:request).and_return(mock_response)
        allow(Net::HTTP).to receive(:new).and_return(mock_http)

        described_class.call(
          method: "GET",
          url: "http://localhost:3000/dashboard",
          cookies: { "_session_id" => "abc123", "user_id" => "42" },
          server_context: server_context,
        )

        expect(stub_request).to have_received(:[]=).with("Cookie", "_session_id=abc123; user_id=42")
      end

      it "displays Set-Cookie from response" do
        allow(manager).to receive(:client).and_raise(GirbMcp::SessionError, "No session")
        stub_http_response(
          headers: {
            "content-type" => ["text/html"],
            "set-cookie" => ["_session_id=xyz789; path=/"],
          },
          body: "<html></html>",
        )

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/login",
          server_context: server_context,
        )
        text = response_text(response)

        expect(text).to include("Set-Cookie:")
        expect(text).to include("_session_id=xyz789")
      end
    end

    context "CSRF handling" do
      it "disables and restores CSRF when breakpoint is hit (process paused)" do
        allow(client).to receive(:send_command)
          .with("p defined?(Rails)")
          .and_return('=> "constant"')
        allow(client).to receive(:send_command)
          .with("p defined?(ActionController::Base) && ActionController::Base.allow_forgery_protection")
          .and_return("=> true")
        allow(client).to receive(:send_command)
          .with("ActionController::Base.allow_forgery_protection = false")
          .and_return("=> false")
        allow(client).to receive(:send_command)
          .with("ActionController::Base.allow_forgery_protection = true")
          .and_return("=> true")

        stub_http_response(request_class: Net::HTTP::Post)

        allow(client).to receive(:ensure_paused).and_return("")
        allow(client).to receive(:continue_and_wait).and_return({
          type: :breakpoint,
          output: "Stop by #1  BP - Line  app/controllers/users_controller.rb:10 (line)",
        })

        described_class.call(
          method: "POST",
          url: "http://localhost:3000/users",
          body: '{"name": "Alice"}',
          server_context: server_context,
        )

        expect(client).to have_received(:send_command)
          .with("ActionController::Base.allow_forgery_protection = false")
        expect(client).to have_received(:send_command)
          .with("ActionController::Base.allow_forgery_protection = true")
      end

      it "does not restore CSRF when process is not paused (interrupted)" do
        allow(client).to receive(:send_command)
          .with("p defined?(Rails)")
          .and_return('=> "constant"')
        allow(client).to receive(:send_command)
          .with("p defined?(ActionController::Base) && ActionController::Base.allow_forgery_protection")
          .and_return("=> true")
        allow(client).to receive(:send_command)
          .with("ActionController::Base.allow_forgery_protection = false")
          .and_return("=> false")

        stub_http_response(request_class: Net::HTTP::Post)

        # After continue_and_wait returns :interrupted, process is running (not paused)
        not_paused_client = build_mock_client(paused: false)
        allow(manager).to receive(:client).and_return(not_paused_client)
        allow(not_paused_client).to receive(:send_command)
          .with("p defined?(Rails)")
          .and_return('=> "constant"')
        allow(not_paused_client).to receive(:send_command)
          .with("p defined?(ActionController::Base) && ActionController::Base.allow_forgery_protection")
          .and_return("=> true")
        allow(not_paused_client).to receive(:send_command)
          .with("ActionController::Base.allow_forgery_protection = false")
          .and_return("=> false")
        allow(not_paused_client).to receive(:ensure_paused).and_return("")
        allow(not_paused_client).to receive(:continue_and_wait).and_return({
          type: :interrupted, output: "",
        })

        described_class.call(
          method: "POST",
          url: "http://localhost:3000/users",
          body: '{"name": "Alice"}',
          server_context: server_context,
        )

        # CSRF should NOT be restored because process is running
        expect(not_paused_client).not_to have_received(:send_command)
          .with("ActionController::Base.allow_forgery_protection = true")
      end

      it "does not disable CSRF for GET requests" do
        allow(client).to receive(:send_command)
          .with("p defined?(Rails)")
          .and_return('=> "constant"')

        stub_http_response

        allow(client).to receive(:ensure_paused).and_return("")
        allow(client).to receive(:continue_and_wait).and_return({
          type: :interrupted, output: "",
        })

        described_class.call(
          method: "GET",
          url: "http://localhost:3000/users",
          server_context: server_context,
        )

        expect(client).not_to have_received(:send_command)
          .with("ActionController::Base.allow_forgery_protection = false")
      end

      it "skips CSRF when skip_csrf is false" do
        stub_http_response(request_class: Net::HTTP::Post)

        allow(client).to receive(:ensure_paused).and_return("")
        allow(client).to receive(:continue_and_wait).and_return({
          type: :interrupted, output: "",
        })

        described_class.call(
          method: "POST",
          url: "http://localhost:3000/users",
          body: '{"name": "Alice"}',
          skip_csrf: false,
          server_context: server_context,
        )

        expect(client).not_to have_received(:send_command)
          .with("ActionController::Base.allow_forgery_protection = false")
      end

      it "restores CSRF on error when client is still paused" do
        # Client stays paused (e.g., error before continue was called)
        allow(client).to receive(:send_command)
          .with("p defined?(Rails)")
          .and_return('=> "constant"')
        allow(client).to receive(:send_command)
          .with("p defined?(ActionController::Base) && ActionController::Base.allow_forgery_protection")
          .and_return("=> true")
        allow(client).to receive(:send_command)
          .with("ActionController::Base.allow_forgery_protection = false")
          .and_return("=> false")
        allow(client).to receive(:send_command)
          .with("ActionController::Base.allow_forgery_protection = true")
          .and_return("=> true")

        allow(client).to receive(:ensure_paused).and_raise(
          GirbMcp::ConnectionError, "Connection lost",
        )

        # Make HTTP request fail too
        allow(Net::HTTP).to receive(:new).and_raise(StandardError, "connection refused")

        described_class.call(
          method: "POST",
          url: "http://localhost:3000/users",
          body: "{}",
          server_context: server_context,
        )

        # CSRF restored because client.paused is true (error before continue)
        expect(client).to have_received(:send_command)
          .with("ActionController::Base.allow_forgery_protection = true")
      end
    end

    context "response formatting" do
      before do
        allow(manager).to receive(:client).and_raise(GirbMcp::SessionError, "No session")
      end

      it "pretty-prints JSON responses" do
        stub_http_response(body: '{"name":"Alice","age":30}')

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/users/1",
          server_context: server_context,
        )
        text = response_text(response)

        # JSON.pretty_generate adds indentation
        expect(text).to include("\"name\": \"Alice\"")
        expect(text).to include("\"age\": 30")
      end

      it "truncates HTML responses over 1000 chars" do
        long_html = "<html><body>#{"x" * 1500}</body></html>"
        stub_http_response(
          body: long_html,
          headers: { "content-type" => ["text/html; charset=utf-8"] },
        )

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/",
          server_context: server_context,
        )
        text = response_text(response)

        expect(text).to include("HTML truncated")
        expect(text).to include("bytes total")
      end

      it "shows redirect location" do
        stub_http_response(
          code: "302",
          message: "Found",
          body: "",
          headers: {
            "location" => ["http://localhost:3000/login"],
            "content-type" => ["text/html"],
          },
        )

        response = described_class.call(
          method: "GET",
          url: "http://localhost:3000/dashboard",
          server_context: server_context,
        )
        text = response_text(response)

        expect(text).to include("302")
        expect(text).to include("Location: http://localhost:3000/login")
      end

      it "handles empty body" do
        stub_http_response(
          code: "204",
          message: "No Content",
          body: "",
          headers: {},
        )

        response = described_class.call(
          method: "DELETE",
          url: "http://localhost:3000/users/1",
          server_context: server_context,
        )
        text = response_text(response)

        expect(text).to include("204")
        expect(text).to include("(empty body)")
      end
    end
  end

  describe "DEFAULT_TIMEOUT" do
    it "is 30" do
      expect(GirbMcp::Tools::TriggerRequest::DEFAULT_TIMEOUT).to eq(30)
    end
  end
end
