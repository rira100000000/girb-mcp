# frozen_string_literal: true

module GirbMcp
  # Annotates debug output with human-readable explanations of stop events.
  #
  # The debug gem uses TracePoint events to determine when a breakpoint fires:
  #   (line)     - about to execute the line
  #   (call)     - entering a method (before body executes)
  #   (return)   - returning from a method (line has ALREADY been executed)
  #   (b_call)   - entering a block (before body executes)
  #   (b_return) - returning from a block (line has ALREADY been executed)
  #   (c_call)   - entering a C method
  #   (c_return) - returning from a C method
  #
  # The (return) and (b_return) events are particularly confusing because the
  # source listing shows the line with "=>" as if it's about to execute, but
  # in reality it has already been executed.
  module StopEventAnnotator
    BREAKPOINT_SET_NOTES = {
      "return" => "WARNING - Stop event (return): The debug gem assigned this breakpoint to the method's " \
                  "return event. This means:\n" \
                  "  - It fires AFTER the method finishes and the line has ALREADY been executed\n" \
                  "  - The current line (=>) shown when hit will be the 'def' line, NOT line you specified\n" \
                  "Tip: To stop BEFORE execution at the exact line, set the breakpoint on a line " \
                  "inside the method body instead (e.g., the first line after 'def').",
      "b_return" => "WARNING - Stop event (b_return): The debug gem assigned this breakpoint to the block's " \
                    "return event. This means:\n" \
                    "  - It fires AFTER each block iteration returns (stops on EVERY iteration)\n" \
                    "  - The line has ALREADY been executed when the breakpoint hits\n" \
                    "  - The current line (=>) shown when hit may differ from the line you specified\n" \
                    "Tip: To stop BEFORE execution, set the breakpoint on the first line inside the block. " \
                    "To stop only once, use one_shot: true, or set the breakpoint on the line where " \
                    "the block method is called (e.g., the .map line).",
      "call" => "WARNING - Stop event (call): The debug gem assigned this breakpoint to a method entry event " \
                "instead of a line event. This typically happens when the breakpoint line is a method " \
                "definition (e.g., 'def foo').\n" \
                "  - It fires when the method is entered, which may not match your expectation\n" \
                "Tip: Set the breakpoint on a line inside the method body instead.",
      "b_call" => "WARNING - Stop event (b_call): The debug gem assigned this breakpoint to a block entry event " \
                  "instead of a line event. This typically happens when the breakpoint line is a block " \
                  "definition (e.g., 'do ... end' or '{ ... }').\n" \
                  "  - It fires when the block is entered (stops on EVERY iteration)\n" \
                  "Tip: Set the breakpoint on the first line inside the block body instead. " \
                  "Use one_shot: true to stop only once.",
      "c_call" => "WARNING - Stop event (c_call): The debug gem assigned this breakpoint to a C method entry event. " \
                  "This means the line maps to a native C method call, not a Ruby line.\n" \
                  "  - Behavior may be unexpected since C methods don't have Ruby source lines\n" \
                  "Tip: Set the breakpoint on a different line that contains Ruby code.",
      "c_return" => "WARNING - Stop event (c_return): The debug gem assigned this breakpoint to a C method return event. " \
                    "This means the line maps to a native C method return.\n" \
                    "  - The C method has ALREADY finished executing when the breakpoint hits\n" \
                    "Tip: Set the breakpoint on a different line that contains Ruby code.",
    }.freeze

    # Hit notes only for return/b_return events where the "already executed" semantics
    # are confusing. call/b_call/c_call/c_return don't need hit annotations because
    # the set-time warning already advises moving the breakpoint to a different line.
    BREAKPOINT_HIT_NOTES = {
      "return" => "Stop event (return): the marked line (=>) is the method definition. " \
                  "The method has ALREADY finished executing and returned.",
      "b_return" => "Stop event (b_return): the marked line (=>) has ALREADY been executed. " \
                    "This is a block return — the block iteration just completed.",
    }.freeze

    RETURN_EVENTS = %w[return b_return c_return].freeze

    STOP_EVENT_PATTERN = /BP - \w+\s+.+\((\w+)\)/
    CATCH_BREAKPOINT_PATTERN = /BP - Catch\s+"([^"]+)"/

    module_function

    # Annotate breakpoint creation output with stop event explanation.
    def annotate_breakpoint_set(output)
      annotate(output, BREAKPOINT_SET_NOTES)
    end

    # Annotate breakpoint hit output with stop event explanation.
    def annotate_breakpoint_hit(output)
      annotate(output, BREAKPOINT_HIT_NOTES)
    end

    # Enrich output with runtime context from the debug client.
    # At catch breakpoints: fetches exception class and message.
    # At return events: fetches __return_value__ and $! to distinguish
    # normal return from exception unwinding.
    # At all events: checks $! for in-scope exceptions.
    def enrich_stop_context(output, client)
      event = detect_stop_event(output)
      at_return = event && RETURN_EVENTS.include?(event)
      at_catch = output&.match?(CATCH_BREAKPOINT_PATTERN)

      parts = [output]

      if at_return
        # Fetch return value (only available at return/b_return/c_return events)
        begin
          ret_val = client.send_command("p __return_value__")
          cleaned = ret_val.strip.sub(/\A=> /, "")
          unless cleaned.include?("NameError") || cleaned.include?("undefined")
            parts << "Return value: #{cleaned}"
          end
        rescue GirbMcp::Error
          # __return_value__ not available
        end
      end

      # Check for exception in scope ($!)
      exception_info = client.check_current_exception

      # At catch breakpoints, $! is not yet set because the :raise TracePoint
      # fires before Ruby assigns $!. Fall back to ObjectSpace to find the
      # most recently created instance of the caught exception class.
      if at_catch && exception_info.nil?
        exception_class = output.match(CATCH_BREAKPOINT_PATTERN)&.captures&.first
        exception_info = client.find_raised_exception(exception_class) if exception_class
      end

      if exception_info
        if at_catch
          parts << "Caught exception: #{exception_info}"
        elsif at_return
          parts << "Exception in scope: #{exception_info}\n" \
                   "This method/block is returning due to an exception, not a normal return. " \
                   "The return value above may be nil or meaningless."
        else
          parts << "Exception in scope: #{exception_info}"
        end
      end

      parts.length > 1 ? parts.join("\n\n") : output
    end

    # Detect the stop event type from debug output.
    # Returns the event name string (e.g., "b_return") or nil.
    def detect_stop_event(output)
      return nil unless output

      match = output.match(STOP_EVENT_PATTERN)
      match ? match[1] : nil
    end

    def annotate(output, notes)
      return output unless output

      event = detect_stop_event(output)
      return output unless event

      note = notes[event]
      note ? "#{output}\n\n#{note}" : output
    end
  end
end
