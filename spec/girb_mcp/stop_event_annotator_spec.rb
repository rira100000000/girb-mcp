# frozen_string_literal: true

RSpec.describe GirbMcp::StopEventAnnotator do
  describe ".detect_stop_event" do
    it "returns nil for nil output" do
      expect(described_class.detect_stop_event(nil)).to be_nil
    end

    it "returns nil for output without stop event" do
      expect(described_class.detect_stop_event("some random output")).to be_nil
    end

    it "detects line event" do
      output = "Stop by #1  BP - Line  /path/file.rb:10 (line)"
      expect(described_class.detect_stop_event(output)).to eq("line")
    end

    it "detects call event" do
      output = "Stop by #2  BP - Method  Foo#bar (call)"
      expect(described_class.detect_stop_event(output)).to eq("call")
    end

    it "detects return event" do
      output = "Stop by #3  BP - Line  /path/file.rb:5 (return)"
      expect(described_class.detect_stop_event(output)).to eq("return")
    end

    it "detects b_return event" do
      output = "Stop by #4  BP - Line  /path/file.rb:8 (b_return)"
      expect(described_class.detect_stop_event(output)).to eq("b_return")
    end

    it "detects b_call event" do
      output = "Stop by #5  BP - Line  /path/file.rb:3 (b_call)"
      expect(described_class.detect_stop_event(output)).to eq("b_call")
    end

    it "detects c_return event" do
      output = "Stop by #6  BP - Line  /path/file.rb:3 (c_return)"
      expect(described_class.detect_stop_event(output)).to eq("c_return")
    end
  end

  describe ".annotate_breakpoint_set" do
    it "returns output unchanged for line event" do
      output = "Stop by #1  BP - Line  /path:10 (line)"
      expect(described_class.annotate_breakpoint_set(output)).to eq(output)
    end

    it "adds warning for return event" do
      output = "#1  BP - Line  /path:10 (return)"
      result = described_class.annotate_breakpoint_set(output)
      expect(result).to include("WARNING - Stop event (return)")
      expect(result).to include("fires AFTER the method finishes")
    end

    it "adds warning for b_return event" do
      output = "#1  BP - Line  /path:10 (b_return)"
      result = described_class.annotate_breakpoint_set(output)
      expect(result).to include("WARNING - Stop event (b_return)")
      expect(result).to include("fires AFTER each block iteration returns")
    end

    it "returns nil for nil output" do
      expect(described_class.annotate_breakpoint_set(nil)).to be_nil
    end
  end

  describe ".annotate_breakpoint_hit" do
    it "returns output unchanged for line event" do
      output = "Stop by #1  BP - Line  /path:10 (line)"
      expect(described_class.annotate_breakpoint_hit(output)).to eq(output)
    end

    it "adds note for return event" do
      output = "Stop by #1  BP - Line  /path:10 (return)"
      result = described_class.annotate_breakpoint_hit(output)
      expect(result).to include("Stop event (return)")
      expect(result).to include("method definition")
      expect(result).to include("ALREADY finished executing")
    end

    it "adds note for b_return event" do
      output = "Stop by #1  BP - Line  /path:10 (b_return)"
      result = described_class.annotate_breakpoint_hit(output)
      expect(result).to include("Stop event (b_return)")
      expect(result).to include("ALREADY been executed")
    end
  end

  describe ".enrich_stop_context" do
    let(:client) { build_mock_client }

    it "returns output unchanged when no stop event" do
      result = described_class.enrich_stop_context("no event here", client)
      expect(result).to eq("no event here")
    end

    it "adds return value at return event" do
      output = "Stop by #1  BP - Line  /path:10 (return)"
      allow(client).to receive(:send_command).with("p __return_value__").and_return("=> 42")
      result = described_class.enrich_stop_context(output, client)
      expect(result).to include("Return value: 42")
    end

    it "adds exception info when present" do
      output = "Stop by #1  BP - Line  /path:10 (line)"
      allow(client).to receive(:check_current_exception).and_return("RuntimeError: boom")
      result = described_class.enrich_stop_context(output, client)
      expect(result).to include("Exception in scope: RuntimeError: boom")
    end

    it "shows exception context at return events" do
      output = "Stop by #1  BP - Line  /path:10 (return)"
      allow(client).to receive(:send_command).with("p __return_value__").and_return("=> nil")
      allow(client).to receive(:check_current_exception).and_return("RuntimeError: boom")
      result = described_class.enrich_stop_context(output, client)
      expect(result).to include("Exception in scope: RuntimeError: boom")
      expect(result).to include("returning due to an exception")
    end

    it "shows caught exception at catch breakpoints" do
      output = 'Stop by #1  BP - Catch  "NoMethodError"  (line)'
      allow(client).to receive(:check_current_exception).and_return("NoMethodError: undefined")
      result = described_class.enrich_stop_context(output, client)
      expect(result).to include("Caught exception: NoMethodError: undefined")
    end

    it "falls back to ObjectSpace when $! is nil at catch breakpoints" do
      output = 'Stop by #1  BP - Catch  "NoMethodError"  (line)'
      allow(client).to receive(:check_current_exception).and_return(nil)
      allow(client).to receive(:find_raised_exception).with("NoMethodError")
        .and_return("NoMethodError: undefined method 'foo' for nil")
      result = described_class.enrich_stop_context(output, client)
      expect(result).to include("Caught exception: NoMethodError: undefined method 'foo' for nil")
    end

    it "shows nothing when both $! and ObjectSpace fail at catch breakpoints" do
      output = 'Stop by #1  BP - Catch  "NoMethodError"  (line)'
      allow(client).to receive(:check_current_exception).and_return(nil)
      allow(client).to receive(:find_raised_exception).with("NoMethodError").and_return(nil)
      result = described_class.enrich_stop_context(output, client)
      expect(result).not_to include("Caught exception:")
    end

    it "skips return value when NameError" do
      output = "Stop by #1  BP - Line  /path:10 (return)"
      allow(client).to receive(:send_command).with("p __return_value__").and_return("=> NameError: undefined")
      result = described_class.enrich_stop_context(output, client)
      expect(result).not_to include("Return value:")
    end
  end

  describe "RETURN_EVENTS" do
    it "contains return, b_return, c_return" do
      expect(GirbMcp::StopEventAnnotator::RETURN_EVENTS).to eq(%w[return b_return c_return])
    end
  end
end
