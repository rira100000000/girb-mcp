# frozen_string_literal: true

RSpec.describe GirbMcp::Server do
  describe "constants" do
    it "has a TOOLS array with all 18 tools" do
      expect(GirbMcp::Server::TOOLS).to be_a(Array)
      expect(GirbMcp::Server::TOOLS.size).to eq(18)
    end

    it "has default HTTP port" do
      expect(GirbMcp::Server::DEFAULT_HTTP_PORT).to eq(6029)
    end

    it "has default HTTP host" do
      expect(GirbMcp::Server::DEFAULT_HTTP_HOST).to eq("127.0.0.1")
    end

    it "has instructions text" do
      expect(GirbMcp::Server::INSTRUCTIONS).to include("girb-mcp")
      expect(GirbMcp::Server::INSTRUCTIONS).to include("Ruby runtime debugger")
    end
  end

  describe "#initialize" do
    it "accepts default parameters" do
      server = GirbMcp::Server.new
      expect(server).to be_a(GirbMcp::Server)
    end

    it "accepts transport parameter" do
      server = GirbMcp::Server.new(transport: "stdio")
      expect(server).to be_a(GirbMcp::Server)
    end

    it "accepts http transport parameters" do
      server = GirbMcp::Server.new(transport: "http", port: 8080, host: "0.0.0.0")
      expect(server).to be_a(GirbMcp::Server)
    end

    it "accepts session_timeout parameter" do
      server = GirbMcp::Server.new(session_timeout: 600)
      expect(server).to be_a(GirbMcp::Server)
    end
  end

  describe GirbMcp::Server::RackRequestAdapter do
    it "wraps env and exposes body" do
      input = StringIO.new('{"key": "value"}')
      env = { "rack.input" => input, "REQUEST_METHOD" => "POST" }
      adapter = GirbMcp::Server::RackRequestAdapter.new(env)

      expect(adapter.env).to eq(env)
      expect(adapter.body).to eq(input)
    end
  end
end
