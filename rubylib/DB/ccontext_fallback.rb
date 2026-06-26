#!/usr/bin/ruby
# Copyright (c) 2005-2006 ActiveState Software Inc.
#
# See the LICENSE file for full details on this software's license.
#
# Authors:
#    Eric Promislow <EricP@ActiveState.com>

# DB/context_fallback.rb
#
# Load this module if we don't have a binary component, and use the
# pure Ruby code.

module Dbgr_Context_fallback







require 'DB/filetable'



include FileTable

require 'DB/constants'     #buncha global constants
include DBGR_Constants

    public

    # The old pure-Ruby trace_func2 function
    def cc_trace_func2(event_num, file, line, id, binding, klass)



      
      file_URI_No = @ftable.intern_file(file)
      case event_num
      when RB_EVENT_LINE
        if @frames.size == 0
          @frames = [[binding, file_URI_No, line, id]]
        else
          f = @frames[-1]
          f[FRAME_IDX_FILENAME] = file_URI_No unless file_URI_No == EvalStringEntry
          f[FRAME_IDX_BINDING] = binding
          f[FRAME_IDX_LINENO] = line
        end




        if @starting_require
          @starting_require = false
          # Fix the stack
          @frames[-1] = [binding, file_URI_No, line, id]
        end
        # For now always step into debug_command
        # and examine the break-conditions there
        #
        # Separate the entry filter from the debugger read-eval-print loop
        # so we can rewrite the filter in Ruby-C
        
        if debug_command_filter(file_URI_No, line, id, binding)
          debug_command(file_URI_No, line, id, binding)
        end
        
      when RB_EVENT_CALL
        do_trace_push_state(file_URI_No, line, id, binding)
        function_stack_check(BKPT_FUNCTION_CALL, id, klass, binding)
        
      when RB_EVENT_C_CALL
        if id == :require
          do_trace_push_state(file_URI_No, line, id, binding)
          @starting_require = true
        elsif @debugger__.kernel_ids.index(id)
          eval_count_inc()
          do_trace_push_state("(eval)", 1, id, binding)
        end
        
      when RB_EVENT_C_RETURN
        if @debugger__.kernel_ids.index(id)
          do_trace_pop_state()
        end
        
      when RB_EVENT_CLASS
        do_trace_push_state(file_URI_No, line, id, binding)
        
      when RB_EVENT_RETURN
        do_trace_pop_state()
        if @single == SINGLE_STEP_OVER
          # step-over on last line of a call: stop asap
          @single = SINGLE_STEP_IN
        elsif @single == SINGLE_STEP_IN
          # Nothing to do
        else
          if @finish_pos
            if @finish_pos > @frames.size
              @single = SINGLE_STEP_IN
            elsif @finish_pos == @frames.size && @finish_action == :return
              @single = SINGLE_STEP_IN
              @finish_action = nil
            end
          end
          if @single == SINGLE_STEP_IN



          else
            function_stack_check(BKPT_FUNCTION_RETURN, id, klass, binding)
          end
        end
        
      when RB_EVENT_END
        do_trace_pop_state()
        
        #XXX Handle exceptions.
        # when 'raise' 
        # excn_handle(file_URI_No, line, id, binding)
        
      end



    end # End function
    
    def cc_update_values()
    end

#  end # class

  def cc_extend_class(klass)
    # Stub
  end

end # module

