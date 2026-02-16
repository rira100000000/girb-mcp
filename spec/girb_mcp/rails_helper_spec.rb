# frozen_string_literal: true

RSpec.describe GirbMcp::RailsHelper do
  let(:client) { build_mock_client }

  describe ".require_rails!" do
    it "succeeds when Rails is defined" do
      allow(client).to receive(:send_command).with("p defined?(Rails)").and_return('=> "constant"')

      expect { described_class.require_rails!(client) }.not_to raise_error
    end

    it "raises SessionError when Rails is not defined" do
      allow(client).to receive(:send_command).with("p defined?(Rails)").and_return("=> nil")

      expect { described_class.require_rails!(client) }.to raise_error(
        GirbMcp::SessionError, /Not a Rails application/,
      )
    end
  end

  describe ".rails?" do
    it "returns true when Rails is defined" do
      allow(client).to receive(:send_command).with("p defined?(Rails)").and_return('=> "constant"')

      expect(described_class.rails?(client)).to be true
    end

    it "returns false when Rails is not defined" do
      allow(client).to receive(:send_command).with("p defined?(Rails)").and_return("=> nil")

      expect(described_class.rails?(client)).to be false
    end

    it "returns false on error" do
      allow(client).to receive(:send_command).with("p defined?(Rails)").and_raise(
        GirbMcp::ConnectionError, "lost",
      )

      expect(described_class.rails?(client)).to be false
    end
  end
end
