#!/usr/bin/ruby
# Copyright (c) 2005-2006 ActiveState Software Inc.
#
# See the LICENSE file for full details on this software's license.
#
# Authors:
#    Eric Promislow <EricP@ActiveState.com>

# DB/crdbgp_fallback.rb
#
# Load this module if we don't have a binary component, and use the
# pure Ruby code.

module CRdbgp

  require 'DB/constants'     #buncha global constants
  include DBGR_Constants
# #if defined('DEBUG')
  begin
    require 'DB/redirect_unprocessed'
  rescue LoadError
# #endif
    require 'DB/redirect'
# #if defined('DEBUG')
  end
# #endif

  def c_discard_event(event_num, file, id, klass, debug_mode=0)
    return 2 if klass == Module
    if event_num == RB_EVENT_C_CALL || event_num == RB_EVENT_C_RETURN
      if klass == Kernel && @kernel_ids.index(id)
        # dblog("**************** Got a c-call/:require|eval/Kernel thing")
        return false
      else
        return 2
      end
    end
      
    if klass == RedirectStdOutput
      return 2
    elsif @_this_file_re.match(file)
      return 2
    elsif file =~ %r{/DB/redirect(?:_unprocessed)?.rb}
      return 2
    elsif event_num == RB_EVENT_RETURN
      # Return files are usually in terms of the caller,
      # which makes things harder.
      if klass == DebuggerShroud::DEBUGGER__
        if @local_eval_ids.index(id)
          return 1
        end
      end
    end
    return false
  end
end

