# frozen_string_literal: true

RSpec.describe GirbMcp::Tools::TriggerRequest do
  let(:client) { build_mock_client }
  let(:manager) { build_mock_manager(client: client) }
  let(:server_context) { { session_manager: manager } }

  describe ".call" do
    it "sends HTTP request and returns response" do
      allow(manager).to receive(:client).and_raise(GirbMcp::SessionError, "No session")

      stub_request = instance_double(Net::HTTP::Get)
      allow(stub_request).to receive(:[]=)
      allow(stub_request).to receive(:body=)
      allow(Net::HTTP::Get).to receive(:new).and_return(stub_request)

      body_str = '{"status": "ok"}'.dup.force_encoding("UTF-8")
      mock_response = instance_double(Net::HTTPResponse,
        code: "200",
        message: "OK",
        to_hash: { "content-type" => ["application/json"] })
      allow(mock_response).to receive(:body).and_return(body_str)

      mock_http = instance_double(Net::HTTP)
      allow(mock_http).to receive(:open_timeout=)
      allow(mock_http).to receive(:read_timeout=)
      allow(mock_http).to receive(:use_ssl=)
      allow(mock_http).to receive(:request).and_return(mock_response)
      allow(Net::HTTP).to receive(:new).and_return(mock_http)

      response = described_class.call(
        method: "GET",
        url: "http://localhost:3000/api/status",
        server_context: server_context,
      )
      text = response_text(response)
      expect(text).to include("200")
    end
  end

  describe "DEFAULT_TIMEOUT" do
    it "is 30" do
      expect(GirbMcp::Tools::TriggerRequest::DEFAULT_TIMEOUT).to eq(30)
    end
  end
end
