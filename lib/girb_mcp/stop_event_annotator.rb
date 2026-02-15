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
    }.freeze

    BREAKPOINT_HIT_NOTES = {
      "return" => "Stop event (return): the marked line (=>) is the method definition. " \
                  "The method has ALREADY finished executing and returned.",
      "b_return" => "Stop event (b_return): the marked line (=>) has ALREADY been executed. " \
                    "This is a block return — the block iteration just completed.",
    }.freeze

    RETURN_EVENTS = %w[return b_return c_return].freeze

    STOP_EVENT_PATTERN = /BP - \w+\s+.+\((\w+)\)/

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
    # At return events: fetches __return_value__ and $! to distinguish
    # normal return from exception unwinding.
    # At all events: checks $! for in-scope exceptions.
    def enrich_stop_context(output, client)
      event = detect_stop_event(output)
      at_return = event && RETURN_EVENTS.include?(event)

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
      if exception_info
        if at_return
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
