# frozen_string_literal: true

RSpec.describe GirbMcp::Tools::GetSource do
  let(:client) { build_mock_client }
  let(:manager) { build_mock_manager(client: client) }
  let(:server_context) { { session_manager: manager } }

  describe ".call" do
    context "with method target (instance method)" do
      it "returns method source info" do
        allow(client).to receive(:send_command)
          .with("p [User.instance_method(:save).source_location, User.instance_method(:save).parameters]")
          .and_return('=> [["/app/models/user.rb", 10], []]')
        allow(client).to receive(:send_command)
          .with("p User.instance_method(:save).source_location[0]")
          .and_return('=> "/app/models/user.rb"')
        allow(client).to receive(:send_command)
          .with("p User.instance_method(:save).source_location[1]")
          .and_return("=> 10")
        allow(client).to receive(:send_command)
          .with("p User.instance_method(:save).parameters")
          .and_return("=> []")
        allow(File).to receive(:exist?).and_return(false)

        response = described_class.call(target: "User#save", server_context: server_context)
        text = response_text(response)
        expect(text).to include("User#save")
        expect(text).to include("File: /app/models/user.rb:10")
      end
    end

    context "with class method target" do
      it "returns method source info" do
        allow(client).to receive(:send_command)
          .with("p [User.method(:find).source_location, User.method(:find).parameters]")
          .and_return('=> [["/app/models/user.rb", 5], [[:req, :id]]]')
        allow(client).to receive(:send_command)
          .with("p User.method(:find).source_location[0]")
          .and_return('=> "/app/models/user.rb"')
        allow(client).to receive(:send_command)
          .with("p User.method(:find).source_location[1]")
          .and_return("=> 5")
        allow(client).to receive(:send_command)
          .with("p User.method(:find).parameters")
          .and_return("=> [[:req, :id]]")
        allow(File).to receive(:exist?).and_return(false)

        response = described_class.call(target: "User.find", server_context: server_context)
        text = response_text(response)
        expect(text).to include("User.find")
        expect(text).to include("File: /app/models/user.rb:5")
        expect(text).to include("Parameters: [[:req, :id]]")
      end
    end

    context "with remote client when local file does not exist" do
      let(:client) { build_mock_client(remote: true) }

      it "fetches method source via remote file reading" do
        allow(client).to receive(:send_command)
          .with("p [User.instance_method(:save).source_location, User.instance_method(:save).parameters]")
          .and_return('=> [["/app/models/user.rb", 10], []]')
        allow(client).to receive(:send_command)
          .with("p User.instance_method(:save).source_location[0]")
          .and_return('=> "/app/models/user.rb"')
        allow(client).to receive(:send_command)
          .with("p User.instance_method(:save).source_location[1]")
          .and_return("=> 10")
        allow(client).to receive(:send_command)
          .with("p User.instance_method(:save).parameters")
          .and_return("=> []")
        allow(File).to receive(:exist?).with("/app/models/user.rb").and_return(false)

        # Remote file reading
        allow(client).to receive(:send_command)
          .with('p File.readlines("/app/models/user.rb").size')
          .and_return("=> 20")
        allow(client).to receive(:send_command)
          .with('p File.readlines("/app/models/user.rb")[9..19].join')
          .and_return(%{=> "  def save\\n    validate!\\n    persist\\n  end\\n"})

        response = described_class.call(target: "User#save", server_context: server_context)
        text = response_text(response)
        expect(text).to include("User#save")
        expect(text).to include("File: /app/models/user.rb:10")
        expect(text).to include("def save")
        expect(text).to include("end")
      end

      it "returns nil source when remote file does not exist" do
        allow(client).to receive(:send_command)
          .with("p [User.instance_method(:save).source_location, User.instance_method(:save).parameters]")
          .and_return('=> [["/app/models/user.rb", 10], []]')
        allow(client).to receive(:send_command)
          .with("p User.instance_method(:save).source_location[0]")
          .and_return('=> "/app/models/user.rb"')
        allow(client).to receive(:send_command)
          .with("p User.instance_method(:save).source_location[1]")
          .and_return("=> 10")
        allow(client).to receive(:send_command)
          .with("p User.instance_method(:save).parameters")
          .and_return("=> []")
        allow(File).to receive(:exist?).with("/app/models/user.rb").and_return(false)

        # Remote file reading fails (file not found)
        allow(client).to receive(:send_command)
          .with('p File.readlines("/app/models/user.rb").size')
          .and_return("=> nil")

        response = described_class.call(target: "User#save", server_context: server_context)
        text = response_text(response)
        expect(text).to include("User#save")
        expect(text).to include("File: /app/models/user.rb:10")
        expect(text).not_to include("def save")
      end
    end

    context "with non-remote client when local file does not exist" do
      it "returns no source" do
        allow(client).to receive(:send_command)
          .with("p [User.instance_method(:save).source_location, User.instance_method(:save).parameters]")
          .and_return('=> [["/app/models/user.rb", 10], []]')
        allow(client).to receive(:send_command)
          .with("p User.instance_method(:save).source_location[0]")
          .and_return('=> "/app/models/user.rb"')
        allow(client).to receive(:send_command)
          .with("p User.instance_method(:save).source_location[1]")
          .and_return("=> 10")
        allow(client).to receive(:send_command)
          .with("p User.instance_method(:save).parameters")
          .and_return("=> []")
        allow(File).to receive(:exist?).with("/app/models/user.rb").and_return(false)

        response = described_class.call(target: "User#save", server_context: server_context)
        text = response_text(response)
        expect(text).to include("User#save")
        expect(text).to include("File: /app/models/user.rb:10")
        expect(text).not_to include("def save")
      end
    end

    context "with native method" do
      it "returns source not available message" do
        allow(client).to receive(:send_command)
          .with("p [String.instance_method(:length).source_location, String.instance_method(:length).parameters]")
          .and_return("=> [nil, []]")

        response = described_class.call(target: "String#length", server_context: server_context)
        text = response_text(response)
        expect(text).to include("source not available")
      end
    end

    context "with class target" do
      it "returns class info" do
        allow(client).to receive(:send_command).with("p User.name").and_return('=> "User"')
        allow(client).to receive(:send_command)
          .with("p User.ancestors.first(10).map(&:to_s)")
          .and_return('=> ["User", "ApplicationRecord", "Object"]')
        allow(client).to receive(:send_command)
          .with("p User.instance_methods(false).sort.first(30)")
          .and_return("=> [:save, :destroy, :update]")
        allow(client).to receive(:send_command)
          .with("p (User.methods - Class.methods).sort.first(30)")
          .and_return("=> [:find, :where, :all]")

        response = described_class.call(target: "User", server_context: server_context)
        text = response_text(response)
        expect(text).to include('Class: "User"')
        expect(text).to include("Ancestors:")
        expect(text).to include("Instance methods:")
        expect(text).to include("Class methods:")
      end
    end

    it "handles session error" do
      allow(manager).to receive(:client).and_raise(GirbMcp::SessionError, "No session")

      response = described_class.call(target: "User", server_context: server_context)
      text = response_text(response)
      expect(text).to include("Error: No session")
    end
  end

  describe "MAX_SOURCE_LINES" do
    it "is 50" do
      expect(GirbMcp::Tools::GetSource::MAX_SOURCE_LINES).to eq(50)
    end
  end
end
