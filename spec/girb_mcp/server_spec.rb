# frozen_string_literal: true

RSpec.describe GirbMcp::Server do
  describe "constants" do
    it "has BASE_TOOLS with 19 tools" do
      expect(GirbMcp::Server::BASE_TOOLS).to be_a(Array)
      expect(GirbMcp::Server::BASE_TOOLS.size).to eq(19)
    end

    it "has RAILS_TOOLS with 3 tools" do
      expect(GirbMcp::Server::RAILS_TOOLS).to be_a(Array)
      expect(GirbMcp::Server::RAILS_TOOLS.size).to eq(3)
    end

    it "has TOOLS combining both sets (22 total)" do
      expect(GirbMcp::Server::TOOLS.size).to eq(22)
      expect(GirbMcp::Server::TOOLS).to eq(
        GirbMcp::Server::BASE_TOOLS + GirbMcp::Server::RAILS_TOOLS
      )
    end

    it "does not include Rails tools in BASE_TOOLS" do
      base_names = GirbMcp::Server::BASE_TOOLS.map(&:name_value)
      expect(base_names).not_to include("rails_info")
      expect(base_names).not_to include("rails_routes")
      expect(base_names).not_to include("rails_model")
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

    it "mentions dynamic Rails tool registration in instructions" do
      expect(GirbMcp::Server::INSTRUCTIONS).to include("Rails-specific tools become available")
    end
  end

  describe ".register_rails_tools" do
    it "registers Rails tools on an MCP server" do
      mcp_server = MCP::Server.new(
        name: "test",
        version: "0.0.1",
        tools: GirbMcp::Server::BASE_TOOLS,
      )

      tools_before = mcp_server.instance_variable_get(:@tools).size
      allow(mcp_server).to receive(:notify_tools_list_changed)

      GirbMcp::Server.register_rails_tools(mcp_server)

      tools_after = mcp_server.instance_variable_get(:@tools).size
      expect(tools_after).to eq(tools_before + 3)
      expect(mcp_server).to have_received(:notify_tools_list_changed)
    end

    it "is idempotent — skips already-registered tools" do
      mcp_server = MCP::Server.new(
        name: "test",
        version: "0.0.1",
        tools: GirbMcp::Server::BASE_TOOLS,
      )
      allow(mcp_server).to receive(:notify_tools_list_changed)

      GirbMcp::Server.register_rails_tools(mcp_server)
      tools_count = mcp_server.instance_variable_get(:@tools).size

      result = GirbMcp::Server.register_rails_tools(mcp_server)
      expect(result).to be false # Nothing new added
      expect(mcp_server.instance_variable_get(:@tools).size).to eq(tools_count)
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
