# frozen_string_literal: true

RSpec.describe GirbMcp::Tools::InspectObject do
  let(:client) { build_mock_client }
  let(:manager) { build_mock_manager(client: client) }
  let(:server_context) { { session_manager: manager } }

  describe ".call" do
    it "returns value, class, and instance variables" do
      allow(client).to receive(:send_command).with("pp user").and_return('#<User id: 1, name: "Alice">')
      allow(client).to receive(:send_command)
        .with("p [(user).class.to_s, (user).instance_variables, " \
              "(user).is_a?(Module) ? (user).class_variables : nil]")
        .and_return('=> ["User", [:@id, :@name], nil]')

      response = described_class.call(expression: "user", server_context: server_context)
      text = response_text(response)
      expect(text).to include("Value:")
      expect(text).to include("User")
      expect(text).to include("Class: User")
      expect(text).to include("Instance variables: [:@id, :@name]")
      expect(text).not_to include("Class variables:")
    end

    it "handles timeout on meta query gracefully" do
      allow(client).to receive(:send_command).with("pp x").and_return("42")
      allow(client).to receive(:send_command)
        .with("p [(x).class.to_s, (x).instance_variables, " \
              "(x).is_a?(Module) ? (x).class_variables : nil]")
        .and_raise(GirbMcp::TimeoutError, "timeout")

      response = described_class.call(expression: "x", server_context: server_context)
      text = response_text(response)
      expect(text).to include("Value:")
      expect(text).to include("42")
      expect(text).to include("Class: (timed out)")
      expect(text).to include("Instance variables: (timed out)")
    end

    it "handles unparseable meta output gracefully" do
      allow(client).to receive(:send_command).with("pp x").and_return("42")
      allow(client).to receive(:send_command)
        .with("p [(x).class.to_s, (x).instance_variables, " \
              "(x).is_a?(Module) ? (x).class_variables : nil]")
        .and_return("=> something unexpected")

      response = described_class.call(expression: "x", server_context: server_context)
      text = response_text(response)
      expect(text).to include("Value:")
      expect(text).to include("Class: something unexpected")
    end

    context "class variables" do
      it "displays class variable values when inspecting a Class object" do
        allow(client).to receive(:send_command).with("pp Order").and_return("Order")
        allow(client).to receive(:send_command)
          .with("p [(Order).class.to_s, (Order).instance_variables, " \
                "(Order).is_a?(Module) ? (Order).class_variables : nil]")
          .and_return('=> ["Class", [:@table_name], [:@@count, :@@default_status]]')
        allow(client).to receive(:send_command)
          .with("pp Hash[(Order).class_variables.map{|v|" \
                "[v,(Order).class_variable_get(v) rescue '(error)']}]")
          .and_return('{:@@count=>42, :@@default_status=>:pending}')

        response = described_class.call(expression: "Order", server_context: server_context)
        text = response_text(response)
        expect(text).to include("Class: Class")
        expect(text).to include("Instance variables: [:@table_name]")
        expect(text).to include("Class variables:\n{:@@count=>42, :@@default_status=>:pending}")
      end

      it "falls back to names only when class variable value query times out" do
        allow(client).to receive(:send_command).with("pp Order").and_return("Order")
        allow(client).to receive(:send_command)
          .with("p [(Order).class.to_s, (Order).instance_variables, " \
                "(Order).is_a?(Module) ? (Order).class_variables : nil]")
          .and_return('=> ["Class", [:@table_name], [:@@count]]')
        allow(client).to receive(:send_command)
          .with("pp Hash[(Order).class_variables.map{|v|" \
                "[v,(Order).class_variable_get(v) rescue '(error)']}]")
          .and_raise(GirbMcp::TimeoutError, "timeout")

        response = described_class.call(expression: "Order", server_context: server_context)
        text = response_text(response)
        expect(text).to include("Class variables: [:@@count]")
      end

      it "does not display class variables section for regular instances" do
        allow(client).to receive(:send_command).with("pp obj").and_return('#<Object:0x00007f>')
        allow(client).to receive(:send_command)
          .with("p [(obj).class.to_s, (obj).instance_variables, " \
                "(obj).is_a?(Module) ? (obj).class_variables : nil]")
          .and_return('=> ["Object", [:@x], nil]')

        response = described_class.call(expression: "obj", server_context: server_context)
        text = response_text(response)
        expect(text).to include("Class: Object")
        expect(text).to include("Instance variables: [:@x]")
        expect(text).not_to include("Class variables:")
      end

      it "displays empty class variables for a Class with no class variables" do
        allow(client).to receive(:send_command).with("pp MyClass").and_return("MyClass")
        allow(client).to receive(:send_command)
          .with("p [(MyClass).class.to_s, (MyClass).instance_variables, " \
                "(MyClass).is_a?(Module) ? (MyClass).class_variables : nil]")
          .and_return('=> ["Class", [], []]')

        response = described_class.call(expression: "MyClass", server_context: server_context)
        text = response_text(response)
        expect(text).to include("Class: Class")
        expect(text).to include("Class variables: []")
      end
    end

    it "handles session error" do
      allow(manager).to receive(:client).and_raise(GirbMcp::SessionError, "No session")

      response = described_class.call(expression: "x", server_context: server_context)
      text = response_text(response)
      expect(text).to include("Error: No session")
    end

    context "trap context annotation" do
      it "appends [trap context] when in trap context" do
        client_in_trap = build_mock_client(trap_context: true)
        manager_in_trap = build_mock_manager(client: client_in_trap)

        allow(client_in_trap).to receive(:send_command).with("pp user").and_return("42")
        allow(client_in_trap).to receive(:send_command)
          .with("p [(user).class.to_s, (user).instance_variables, " \
                "(user).is_a?(Module) ? (user).class_variables : nil]")
          .and_return('=> ["Integer", [], nil]')

        response = described_class.call(
          expression: "user",
          server_context: { session_manager: manager_in_trap },
        )
        text = response_text(response)
        expect(text).to include("[trap context]")
      end

      it "does not append [trap context] when not in trap context" do
        allow(client).to receive(:send_command).with("pp x").and_return("42")
        allow(client).to receive(:send_command)
          .with("p [(x).class.to_s, (x).instance_variables, " \
                "(x).is_a?(Module) ? (x).class_variables : nil]")
          .and_return('=> ["Integer", [], nil]')

        response = described_class.call(expression: "x", server_context: server_context)
        text = response_text(response)
        expect(text).not_to include("[trap context]")
      end
    end
  end
end
