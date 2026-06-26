#!/usr/bin/ruby
# Copyright (c) 2005-2006 ActiveState Software Inc.
#
# See the LICENSE file for full details on this software's license.
#
# Authors:
#    Eric Promislow <EricP@ActiveState.com>

# DB/context.rb
#
# Implements the debugger's Context class
#

=begin
= DB/context.rb

Each thread has its own context object, and shares other
objects with the singleton DEBUGGER__

:belongs_to :DEBUGGER__

=end

# Classes

=begin rdoc

The Context class tracks the thread-specific state for each thread in 
the system.  This includes the Komodo socket, stepping status, frames,
eval blocks, settings (we might end up with one thread that does
url encoding of data values, while all others are doing base64, but
I don't see how that can happen).

Add other things as we figure them out.

The Context class also references some of the DEBUGGER__ object's
attributes, such as breakpoints, hooks to stdout and stderr, and
utility classes like the property formatter.  Most of these need
to be set when the Context is created; others can be updated on
a thread switch.  If we don't need to update on thread-switch,
let's remove that option.

Any thread that executes in the Context object owns the
DEBUGGER__.Mutex object, and can't suspend itself, or cause
another thread to run that will try to enter the debugger
and grab the Mutex.    This means that any thread/Context object
can answer questions from Komodo on the state of all threads
in the system.

=end

module Dbgr_Context

# Library require's
    
require 'socket'


  class Context

# Import our own modules and files







require 'DB/breakpoints'   #exposed DBGP_Breakpoints class
require 'DB/filetable'



include FileTable

require 'DB/constants'     #buncha global constants
include DBGR_Constants

require 'DB/commandline'   #command-line handling module
include Dbgr_Commandline






require 'DB/DbgrCommon'




include Dbgr_Common










include DBGR_FunctionBreakpoints # Function breakpoints lookup class
require 'DB/DbgrProperties'
require 'DB/redirect'
require 'DB/session'





include Dbgr_Properties


    attr_writer :supportedCommands, :supportedFeatures, :settings
    attr_reader :dbgp_in_debugger, :frames
    attr_accessor :single
    
    @@stopReasons = %w(starting stopping stopped running break interactive)
    @@thread_ids = []
    @@base_eval_uri = "dbgp:///ruby/eval/rb-" + (Process.pid || 1).to_s
    @@eval_count = 0
    @@is_keyword = {'print' => 1,
      'puts' => 1,
    }
    # escape regexp /^\t*\*[\r\n]*$/
    @@stop_collecting_cmd_re = Regexp.new('\\t*\\*[\\r\\n]*$')
    
    @@prompts = [">", "*"]
    
    def initialize(debugger__)
      # Used for handing the right binding to overridden eval()
      @dbgp_in_debugger=false
      @debugger__ = debugger__
      
      # We have no frame info until we're done with the debugger
      # and process the first line event
      # @frames: array of [binding, file_URI_No, line#, id, <single>]
      @frames = []

      @single = (Thread.current == Thread.main ? SINGLE_DONT_STOP : @debugger__.single)      

      # Give the frame size at which we have a break due
      # to a step_over or finish cmd.
      @finish_pos = nil 
      @finish_action = nil 
      
      @stopReason = 0;
      @lastContinuationCommand = nil
      @lastContinuationStatus = 'break';
      @lastTranID = 0;  # The transactionID that started

      # Should this be here or in Debugger?
      @finished = false

      # Should these be in Context or the Debugger object?
      # It depends on how new sub-threads start life
      @sentInitString_p = false
      @fakeFirstStepInto = true

      # Definitely a context var
      @starting_require = false

      @suspend_next = false
      t_idx = @@thread_ids.index(Thread.current)

      # Interactive variables
      @ibState = IB_STATE_NONE
      @ibBuffer = ''

      cc_update_values()
    end

    def thread_idx
      t_idx = @@thread_ids.index(Thread.current)
      if t_idx.nil?
        @@thread_ids << Thread.current
        t_idx = @@thread_ids.size - 1
      end
      t_idx
    end

    def dblog(*msgs)
      @debugger__.dblog(*msgs)
    end
    
    def set_suspend
      @suspend_next = true
    end
    
    def clear_suspend
      @suspend_next = false
    end
    
    def resume_all
      @debugger__.resume
    end
    
    def suspend_all
      @debugger__.suspend
    end
    
    def check_suspend
      return if Thread.critical
      while (Thread.critical = true; @suspend_next)
        @debugger__.waiting.push Thread.current
        @suspend_next = false
        Thread.stop
      end
      Thread.critical = false
    end

    # Put things that can fail here, not in the constructor
    
    def final_init
      # Other instance variables
      init_debugger_vals(@debugger__)
      
      # And finish initializing the context thing
      dblog("about to talk to host %s, port %s, thread %s\n", @debugger__.remotehost, @debugger__.remoteport, Thread.current)
      @out_sock = TCPSocket.new(@debugger__.remotehost, @debugger__.remoteport)
      if !@out_sock
        dblog("Failed!")
        raise "Can't get a network connection"
      end

      @session = Dbgr_Session.new(@out_sock, @debugger__)
    end
    
    # These class-local references to the debugger object's properties
    # only need to be set when the thread/context is created.
    
    def init_debugger_vals(debugger__)
      @bpts = debugger__.bpts
      @ftable = debugger__.ftable
      @function_bpts = debugger__.function_bpts
      @propInfo = debugger__.propInfo
      @stdout = debugger__.stdout
      @stderr = debugger__.stderr
    end

    #XXX: delete this method and the call if we aren't doing anything.
    def update_debugger_vals(debugger__)
      init_debugger_vals(debugger__) unless defined? @bpts
    end

    # These class-local references to the debugger object's properties
    # need to be refreshed everytime we switch contexts
    
    def refresh_debugger_vals(debugger__)
    end

    def last_ditch_initialize
      @single = SINGLE_STEP_IN
    end

    def emitBanner()
      require 'rbconfig'
      cnf = Config::CONFIG
      printf("Ruby %s [%s]\n", RUBY_VERSION, cnf['arch'])
    end

    # Return true if we should enter the loop
    def debug_command_filter(file_URI_No, line, id, binding)
      begin

        if !@sentInitString_p
          @frames = [[binding, file_URI_No, line, id, SINGLE_DONT_STOP]]
        end

        if @frames[-1][1] == EvalStringEntry
          # Don't stop in an eval block
          # We can visit them by walking the call-stack,
          # but that's it.
          return false
        end
        
        if @single == SINGLE_DONT_STOP



          if @finish_pos && @finish_pos >= @frames.size




            return true
          elsif @session.is_breaking?



            @session.break_off!
            return true
          elsif !@bpts.can_break_here(file_URI_No, line, binding)
            return false
          else
            dblog("we hit a breakpoint at #{file_URI_No}:#{line}")
          end
        end
        # Update the current frame
        # Moved to trace_func2::line
        ####  f = @frames[0]
        #### f[FRAME_IDX_BINDING] = binding
        #### f[FRAME_IDX_LINENO] = line

        if !@sentInitString_p
          if $0 == "-e"
            @startedAsInteractiveShell = true
            @stopReason = STOP_REASON_INTERACT
	    emitBanner()
          else
            @startedAsInteractiveShell = false
            @stopReason = STOP_REASON_BREAK;
          end
          sendInitString()
          @sentInitString_p = true
        end
        return true
      rescue
        return false
      end
    end

    # Core debugger methods go here:
    # breakpoints, stepping, variables(properties), frames, threads
    # Add interactive shell later
    
    def debug_command(file_URI_No, line, id, binding)
      begin
        @dbgp_in_debugger = true




        
        if !@lastContinuationCommand.nil?
          printWithLength(sprintf(%Q(%s\n<response %s command="%s" status="%s"
                                     reason="ok" transaction_id="%s"/>),
                                xmlHeader(),
                                namespaceAttr(),
                                @lastContinuationCommand,
                                @lastContinuationStatus,
                                @lastTranID));
        end
      
        # command loop
        $ldebug = true
        while true
          dblog("Going for a command...\n")
          @debugger__.mutex.unlock
          begin
            cmdstr = @session.get_command()
          ensure
            @debugger__.mutex.lock
            begin
              @debugger__.thread_swap_check
            rescue => msg
              dblog("error doing thread_swap_check: #{msg}")
            end
          end
          if cmdstr.length == 0
            dblog("Got no command\n") if $ldebug;
            if Thread.list.length > 1
              Thread.exit
            else
              Kernel.exit!(0)
            end
          end
          dblog("Got command [#{cmdstr}]\n") if $ldebug;
          @single = SINGLE_DONT_STOP
          @finish_pos = nil
          begin
            cmdArgs = splitCommandLine(cmdstr)
            @cmd = cmdArgs.shift
            @transactionID = getArg(cmdArgs, '-i')
            if @supportedCommands.has_key?(@cmd)
              if @supportedCommands[@cmd] == 0
                _makeErrorResponse(DBP_E_CommandUnimplemented,
                                   "Command #{@cmd} not currently supported")
                next;
              end
            else
              _makeErrorResponse(DBP_E_CommandUnimplemented,
                                 "Command #{@cmd} not recognized")
              next;
            end
            
            do_name = "do_" + @cmd
            if self.respond_to?(do_name)
              res = self.send(do_name, cmdArgs, file_URI_No, line, id, binding)
              if res == false
                break
              end
            else
              $stderr.printf("%s:%d...\n", __FILE__, __LINE__)
              $stderr.printf("Failed to respond to cmd name %s\n", do_name)
              sp2 = sprintf(%Q(<error code="%d" apperr="%d"><message>%s command not recognized</message></error></response>),
                               DBP_E_UnrecognizedCommand,
                               4,
                               @cmd)
              $stderr.printf("sprintf(...)=%s\n", sp2)
              res = (_response_start_1() + sp2);
              printWithLength(res + "</response>")
            end  # main switch
          rescue => msg
            _makeErrorResponse(DBP_E_InternalException, _trimExceptionInfo(msg))
          end
        end  # main loop
      ensure
        @dbgp_in_debugger=false
      end
    end # debug_cmd
  





























    def function_stack_check(callType, function_symbol, klass, binding)
      return if @single == SINGLE_STEP_IN # we're about to break anyway.
      begin
      if @function_bpts.break_at_function_call(callType, function_symbol.to_s, klass, binding)
        @single = SINGLE_STEP_IN
      end
      rescue => msg
        dblog("function_stack_check threw exception: #{msg}")
      end
    end

    @@guard_line = __LINE__

    # Precondition: this is called before pushing a frame on @frames
    def adjust_single_on_call
      if @single == SINGLE_STEP_OVER
        @single = SINGLE_DONT_STOP
        @finish_pos = @frames.size
        @finish_action = :line  # Don't stop unless we need to
        # ':line' is never tested, but I've put it this way to
        # contrast it with ':return'
      end
    end

    def wrap_up



      if !@out_sock.closed?
        printWithLength(sprintf(%Q(%s\n<response %s command="%s" status="%s"
				       reason="ok" transaction_id="%s"/>),
                                xmlHeader(),
                                namespaceAttr(),
                                @lastContinuationCommand || 'run',
                                @lastContinuationStatus = 'stopped',
                                @lastTranID || '0'));
        close_socket()
      end
      @finished = true
      "Debugged program terminated.";
    end

    # private

    ################ Command Dispatch Functions @@@@@@@@@@@@@@@@
    
    def do_status(cmdArgs, file_URI_No, line, id, binding)
      printWithLength(sprintf(%Q(%s\n<response %s command="%s" status="%s"
                                      reason="ok" transaction_id="%s"/>),
                              xmlHeader(),
                              namespaceAttr(),
                              @cmd,
                              @startedAsInteractiveShell ? 'interactive' : getStopReason(),
                              @transactionID));
    end

    def do_feature_get(cmdArgs, file_URI_No, line, id, binding)
      featureName = getArg(cmdArgs, '-n');
      innerText = "";
      if featureName.nil?
        featureName = "unspecified";
        supported = 0;
      elsif @supportedCommands.has_key?(featureName)
        supported = @supportedCommands[featureName];
      elsif @supportedFeatures.has_key?(featureName)
        vals = @supportedFeatures[featureName]
        supported = vals[0];
        if vals[2] == 0 || !@settings.has_key?(featureName)
          innerText = "";
        else
          innerText = @settings[featureName][0];
        end
      else
        # Command not recognized
        supported = 0;
      end
      printWithLength(sprintf(%Q(%s\n<response %s command="%s" feature_name="%s")\
                              ' supported="%d" transaction_id="%s">%s</response>',
                      xmlHeader(),
                      namespaceAttr(),
                      @cmd,
                      featureName,
                      supported,
                      @transactionID,
                      innerText));
    end # do_feature_get
  
    def do_feature_set(cmdArgs, file_URI_No, line, id, binding)
      featureName, featureValue = pickArgs(cmdArgs, "n:v:")
      reason = nil
      status = 0
      if featureName.nil?
        success = 0;
        reason = "Command not specified";
      elsif !@supportedFeatures.has_key?(featureName)
        status = 0;
        reason = "Command #{featureName} not recognized";
      else
        vals = @supportedFeatures[featureName]
        if vals[1] == 0
          status = 0;
          reason = "Command #{featureName} not modifiable";
        elsif vals[2] == 0
          # No associated data, use boolean value in table
          vals[0] = featureValue ? 1 : 0;
          status = 1;
          success = vals[0];
        elsif !@settings.has_key?(featureName)
          status = 0;
          reason = "Command #{featureName} not in settings table";
        else
          svals = @settings[featureName][1];
          if (svals.nil?)
            status = 0;
            reason ="Command #{featureName} is readonly settings table";
          elsif svals.class == Array
            status = 0;
            svals.each {|allowedValue|
              if featureValue == allowedValue
                status = 1;
                @settings[featureName][0] = featureValue;
                if status == 1 && featureName == 'data_encoding'
                  @propInfo.default_encoding = featureValue
                  @stdout.default_encoding = featureValue if @stdout
                  @stderr.default_encoding = featureValue if @stderr
                end
                break
              end
            }
            if status == 0
              reason = "Command #{featureName} value of #{featureValue} isn't an allowed value.";
            end
          elsif svals == 1
            # Hardwire numeric values
            if featureValue =~ /^\d+/
              status = 1;
              @settings[featureName][0] = featureValue.to_i;
            else
              status = 0;
              reason = "Command #{featureName} value of #{featureValue} isn't numeric.";
            end
          elsif svals == 'a'
            # Allow any ascii data
            status = 1;
            @settings[featureName][0] = featureValue;
          else
            status = 0;
            reason = "Command #{featureName}=#{featureValue}, can't deal with current setting of " + pp(vals) + "\n";
          end
        end
      end
      printWithLength(sprintf(%Q(%s\n<response %s command="%s" feature_name="%s")\
                              ' success="%d" transaction_id="%s" %s/>',
                      xmlHeader(),
                      namespaceAttr(),
                      @cmd,
                      featureName,
                      status,
                      @transactionID,
                      reason.nil? ? "" : ('reason="' + xmlEncode(reason) + '"')
                      ))
    end # do_feature_set

    # Continuation commands

    def do_run(cmdArgs, file_URI_No, line, id, binding)
      if @finished and @frames.size == 0
        _end_report()
        return
      end
      @lastContinuationCommand = @cmd;
      @lastContinuationStatus = 'break';
      @lastTranID = @transactionID;
  
      # Is this the first time we're invoked?
      # debug message
      returnStayInLoop = false
      if @fakeFirstStepInto
        if @bpts.can_break_here(file_URI_No, line, binding)



          returnStayInLoop = true
        else
          dblog("fakeFirstStepInto was true, turning it off.");
          dblog("single = #{@single}");
        end
        @fakeFirstStepInto = nil
      end
  
      # continue
      @frames.each {|f| f[FRAME_IDX_SINGLE] &= ~SINGLE_STEP_IN }
      if returnStayInLoop
        _send_break_status()
      else
        @stopReason = STOP_REASON_RUNNING;
      end
      return returnStayInLoop
    end
    
    def do_break(cmdArgs, file_URI_No, line, id, binding)
      @fakeFirstStepInto = 0;
      printWithLength(sprintf(%Q(%s\n<response %s command="%s"
                                      status="break"
                                      success="1"
                                      transaction_id="%s"/>),
                                   xmlHeader(),
                                   namespaceAttr(),
                                   @cmd,
                                    @transactionID));
    end
  
    def do_step_into(cmdArgs, file_URI_No, line, id, binding)
      if @finished and @frames.size == 0
        _end_report()
        return true
      elsif @fakeFirstStepInto
        @fakeFirstStepInto = nil
        _send_break_status()
        return true
      end
  
      @lastContinuationCommand = @cmd;
      @lastContinuationStatus = 'break';
      @lastTranID = @transactionID;
      # debug message
      dblog("Stepping into...\n") if $ldebug;
  
      # step into
      @single = SINGLE_STEP_IN
      @finish_pos = nil
      @stopReason = STOP_REASON_RUNNING;
      return false
    end
  
    def do_step_over(cmdArgs, file_URI_No, line, id, binding)
      if @finished and @frames.size == 0
        _end_report()
        return true
      elsif @fakeFirstStepInto
        # We're already at position 1, so don't go anywhere.
        @fakeFirstStepInto = nil
        _send_break_status()
        return true
      end
      @lastContinuationCommand = @cmd;
      @lastContinuationStatus = 'break';
      @lastTranID = @transactionID;
      # debug message
      dblog("Stepping over...\n") if $ldebug;
  
      # step over
      @single = SINGLE_STEP_OVER;
      @finish_pos = nil
      @stopReason = STOP_REASON_RUNNING;
      return false
    end
    
    def do_step_out(cmdArgs, file_URI_No, line, id, binding)
      if @finished and @frames.size == 0
        _end_report()
        return true
      elsif @fakeFirstStepInto
        if @bpts.can_break_here(file_URI_No, line, binding)
          dblog("hit a breakpoint at first breakable line");
          getNextCmd = true
        else
          dblog("@fakeFirstStepInto was true, turning it off.");
          dblog("@single = #{@single}");
        end
        @fakeFirstStepInto = nil
      end
      @lastContinuationCommand = @cmd;
      @lastContinuationStatus = 'break';
      @lastTranID = @transactionID;
      # debug message
      dblog("Stepping out...\n") if $ldebug;
  
      if getNextCmd
        _send_break_status()
        return true
      end
      @single = SINGLE_DONT_STOP
      
      # Indicate that we want to stop on return
      if @frames.size >= 2
        @finish_pos = @frames.size - 1
      else
        @finish_pos = nil
      end
      @finish_action = :return

      @stopReason = STOP_REASON_RUNNING;
      return false
    end        
  
    def do_stop(cmdArgs, file_URI_No, line, id, binding)
      @fall_off_end = 1
      @finish_pos = nil
      @stopReason = STOP_REASON_STOPPING;
      begin
        printWithLength(sprintf(%Q(%s\n<response %s command="%s" status="%s"
                                             reason="ok" transaction_id="%s"/>),
                                          xmlHeader(),
                                          namespaceAttr(),
                                          @cmd,
                                          'stopped',
                                          @transactionID));
      rescue
        # The socket's probably shut down
        # Komodo doesn't need a stop command thrown back at it
      end
      dblog("Exiting script on stop command ...\n") if $ldebug;
      @session.end_session
      close_socket()
      Kernel.exit!(0);
    end

    def do_detach(cmdArgs, file_URI_No, line, id, binding)
      # Do everything running does, but then set a few other values.
      do_run(cmdArgs, file_URI_No, line, id, binding)
      @finish_pos = nil
      @stopReason = STOP_REASON_STOPPED;
      @runnonstop = 1;
      # Disable all the move commands
      %w(run step_into step_over step_out detach).each {|w|
        @supportedCommands[w] = nil
      }
      @lastContinuationStatus = 'stopping';
      return false
    end

    def do_breakpoint_set(cmdArgs, file_URI_No, line, id, binding)

      # Common stuff here
      bWorkingFileURI, bFunctionName, bLine, bIsTemporary, bState, bType,
        bHitValue, bHitConditionOperator =
        pickArgs(cmdArgs, 'f:m:n+:r+:s:t:h:o:')
      # Big simplification for start -- files and lines only
      bLine = line if line == 0
      bState = 'enabled' if bState.nil?
      if bWorkingFileURI
        bWorkingFileURI = bWorkingFileURI.sub(%r{^dbgp:///file:/}, 'file:/').
          sub(%r{^file:/([^/])}, 'file://\1')
      end

      bFileURI, bFileURINo, bFilePath, rubyFileName = @ftable.getFileInfo(bWorkingFileURI, file_URI_No)
      dblog("do_breakpoint_set -- bFileURI=#{bFileURI}, bFileURINo=#{bFileURINo}, bFilePath=#{bFilePath}, rubyFileName=#{rubyFileName}\n")
      bptErrorCode = 0
      bptErrorMsg = nil

      # Common problems here
      if bType.nil? 
        bptErrorCode = DBP_E_InvalidOption;
        bptErrorMsg = "No breaktype specified"
      elsif @bpts.state_name_to_type(bState, bIsTemporary).nil?
        bptErrorCode = DBP_E_BreakpointStateInvalid;
        bptErrorMsg = "Breakpoint state '#{bState}' not recognized.";
      end

      if (bptErrorCode != 0)
        return _makeErrorResponse(bptErrorCode, bptErrorMsg);
      end

      # Split this large function based on different breakpoint types
      breakpoint_type_handle_name = "do_breakpoint_set_" + bType
      begin
        #XXX Create a function-arg class to handle these.
        return self.send(breakpoint_type_handle_name,
                         bFileURI, bFileURINo, bFilePath, rubyFileName,
                         bLine, bIsTemporary, bState, bType,
                         bFunctionName,
                         bHitValue, bHitConditionOperator, cmdArgs)
      rescue => msg
        return _makeErrorResponse(DBP_E_InternalException, _trimExceptionInfo(msg) + " #{__LINE__}")
      end
    end

    def do_breakpoint_set_line(*args)
      # No condition at this line
      return do_breakpoint_set_line_with_condition(*args + [nil])
    end

    def do_breakpoint_set_line_with_condition(bFileURI, bFileURINo, bFilePath,
                                              rubyFileName,
                                              bLine, bIsTemporary,
                                              bState, bType,
                                              bFunctionName,
                                              bHitValue, bHitConditionOperator,
                                              cmdArgs, bCondition)
      # Watch for unbreakable lines
      #todo: add pending, etc. on the dbline thing
      bptErrorCode = 0
      bptErrorMsg = nil
      if (rubyFileName.nil? && bLine.nil?)
        # Need a filename and a line no for breaking
        bptErrorMsg = "Filename and line number required for setting a breakpoint.";
        bptErrorCode = DBP_E_InvalidOption;
      elsif (bLine < 0)
        bptErrorMsg = "Negative line numbers not supported (got [$bLine])";
        bptErrorCode = DBP_E_InvalidOption;
      end

      if (bptErrorCode != 0)
        return _makeErrorResponse(bptErrorCode, bptErrorMsg);
      end
      
      bStateVal = @bpts.state_name_to_type(bState, bIsTemporary)
      if !rubyFileName.nil? && !SCRIPT_LINES__.has_key?(rubyFileName)
        dblog("**** No SCRIPT_LINES__ entry for file #{rubyFileName}")
        begin
          SCRIPT_LINES__[rubyFileName] = File.open(rubyFileName) {|f| f.readlines}
        rescue => msg
          dblog("Trying to read %s, got error %s", rubyFileName, msg)
        end
      end
      if !rubyFileName.nil? && rubyFileName.length > 0 && SCRIPT_LINES__.has_key?(rubyFileName)
        lines = SCRIPT_LINES__[rubyFileName]
        if !defined? @dumped
          @dumped = {}
        end
        if !@dumped[rubyFileName]
          if false
            def number_lines(alines)
              if alines.kind_of? Array
                i = 1
                return alines[0..9].collect { |line| s = "#{i}:#{line}" ; i += 1 ; s}
              elsif alines.kind_of? String
                i = 2
                alines2 = alines.gsub(/\n/) { "\n#{(i = i + 1).to_s}:" }
                return "1:" + alines2
              end
              return alines
            end
            dblog("Dump file %s: %s\n", rubyFileName, number_lines(lines))
          else
            dblog("Dump file %s: %s\n", rubyFileName, lines[0..9].join(""))
          end
          @dumped[rubyFileName] = true
        end
        bptErrorCode = nil
        if bLine > lines.size
          bptErrorCode = DBP_E_Unbreakable_InvalidCodeLine
        elsif lines[bLine - 1].chomp.length == 0
          bptErrorCode = DBP_E_Unbreakable_EmptyCodeLine
        end
        return _makeErrorResponse(bptErrorCode, "Line #{bLine} isn't breakable") if bptErrorCode
      else
        dblog("Curr file = |#{@frames[-1][1]}|, bpt set for file |#{bFilePath}|, bStateVal = |#{bStateVal}|, bFileURI = |#{bFileURI}|, rubyFileName=#{rubyFileName}\n") if $ldebug;
        ### @bpts.postpone_URI(bFileURINo)
      end
        
   
      # None of these can fail
      bkptID = @bpts.internFileURINo_LineNo(bFileURINo, bLine)
      # Because I don't like 'nil's' in long arg lists...
      bFunctionName = nil
      @bpts.storeBkPtInfo(bkptID, bFileURINo, bLine, bStateVal, bType, bFunctionName, bCondition);
      do_breakpoint_update_hit_info(bkptID, bHitValue, bHitConditionOperator)
      
      printWithLength(sprintf(%Q(%s\n<response %s command="%s")\
                              ' state="%s" id="%d" transaction_id="%s" />',
                      xmlHeader(),
                      namespaceAttr(),
                      @cmd,
                      bState,
                      bkptID,
                      @transactionID));
    end

    def do_breakpoint_set_call(*args)
      return do_breakpoint_set_function(BKPT_FUNCTION_CALL, *args)
    end

    def do_breakpoint_set_return(*args)
      return do_breakpoint_set_function(BKPT_FUNCTION_RETURN, *args)
    end

    def do_breakpoint_set_function(callType,
                                    bFileURI, bFileURINo, bFilePath, rubyFileName,
                                    bLine, bIsTemporary, bState, bType,
                                   bFunctionName,
                                   bHitValue, bHitConditionOperator, cmdArgs)
      # Watch for unbreakable lines
      #todo: add pending, etc. on the dbline thing
      #todo: test breaking on overloaded operators, class methods
      bptErrorCode = 0
      bptErrorMsg = nil
      if (bFunctionName.nil?)
        # Need a filename and a line no for breaking
        bptErrorMsg = "No function name specified for a #{bState}-type breakpoint"
        bptErrorCode = DBP_E_InvalidOption;
      end
      
      if (bptErrorCode != 0)
        return _makeErrorResponse(bptErrorCode, bptErrorMsg);
      end
      
      bStateVal = @bpts.state_name_to_type(bState, bIsTemporary)
      bFunctionName, suffixPart = FunctionBreakpoints.get_function_parts(bFunctionName)
      if bFunctionName =~ /^(.*)(?:::|\#|\.)([a-zA-Z0-9_]+)$/
        classPart, bFunctionName = [$1, $2]
      else
        classPart = ""
      end
      bkptID = @function_bpts.intern_function_name(bFunctionName, suffixPart, classPart, callType)




      @bpts.storeBkPtInfo(bkptID, bFileURINo, bLine, bStateVal, bType);
      do_breakpoint_update_hit_info(bkptID, bHitValue, bHitConditionOperator)
      
      printWithLength(sprintf(%Q(%s\n<response %s command="%s")\
                              ' state="%s" id="%d" transaction_id="%s" />',
                              xmlHeader(),
                              namespaceAttr(),
                              @cmd,
                              bState,
                              bkptID,
                              @transactionID));
    end
    
    def do_breakpoint_set_conditional(bFileURI, bFileURINo, bFilePath, rubyFileName,
                                      bLine, bIsTemporary, bState, bType,
                                      bFunctionName,
                                      bHitValue, bHitConditionOperator, cmdArgs)
      if bLine.nil?
        return _makeErrorResponse(DBP_E_InvalidOption,
                                  "Line number required for setting a conditional breakpoint.")
      end
      enc_cond = getDataArgs(cmdArgs)
      if enc_cond.length == 0
        return _makeErrorResponse(DBP_E_InvalidOption,
                                  "Condition required for setting a conditional breakpoint.")
      end
      dec_cond = decodeData(enc_cond, @settings['data_encoding'][0])
      return do_breakpoint_set_line_with_condition(bFileURI, bFileURINo,
                                                   bFilePath, rubyFileName,
                                                   bLine, bIsTemporary,
                                                   bState, bType,
                                                   bFunctionName,
                                                   bHitValue, bHitConditionOperator,
                                                   cmdArgs, dec_cond)
    end

    def do_breakpoint_update_hit_info(bkptID, bHitValue, bHitConditionOperator)
      if bHitValue
        @bpts.setBkPtHitInfo(bkptID, bHitValue, bHitConditionOperator)
      end
    end
    private :do_breakpoint_update_hit_info
  
    def do_breakpoint_get(cmdArgs, file_URI_No, line, id, binding)
      bkptID = getArg(cmdArgs, '-d').to_i
      print_breakpoint_info(bkptID)
    end

    def do_breakpoint_list(cmdArgs, file_URI_No, line, id, binding)
      res = _response_start_1()
      res += @bpts.getAllBreakpointInfoStrings().join("\n")
      res += "\n</response>\n";
      printWithLength(res);
    end
    
    def do_breakpoint_remove(cmdArgs, file_URI_No, line, id, binding)
      bkptID = getArg(cmdArgs, '-d').to_i
      error_code, msg = @bpts.remove(bkptID)
      if error_code
        _makeErrorResponse(error_code, msg)
      else
        printWithLength(_response_start_1() + "</response>")
      end
    end

    def do_breakpoint_update(cmdArgs, file_URI_No, line, id, binding)
      bkptID, bState, bLine, hit_value, hit_condition = pickArgs(cmdArgs, 'd+:s:n+:h:o:')
      bState = 'enabled' if bState.nil?
      if (bStateVal = @bpts.state_name_to_type(bState)).nil?
        return _makeErrorResponse(DBP_E_BreakpointStateInvalid,
                                  "Breakpoint state '#{bState}' not recognized.")
      end
      # bLine ignored
      if hit_value || hit_condition
        res = @bpts.setBkPtHitInfo(bkptID, hit_value, hit_condition)
        if res
          return _makeErrorResponse(*res)
        end
      end

      res = @bpts.update(bkptID, bStateVal)
      if res
        _makeErrorResponse(*res)
      else
        print_breakpoint_info(bkptID)
      end
    end


    ################ Breakpoint Helper Functions ################
    
    def print_breakpoint_info(bkptID)
      bpInfo = @bpts.getBreakpointInfoString(bkptID);
      if (bpInfo.nil? || bpInfo.length == 0)
          return _makeErrorResponse(DBP_E_NoSuchBreakpoint,
                                    "Unknown breakpoint ID #{bkptID}.");
      end
      res = _response_start_1() + bpInfo + "\n</response>\n";
      printWithLength(res);
    end
      
    ################ Other Dispatch Functions ################
    
    def do_stack_depth(cmdArgs, file_URI_No, line, id, curr_binding)
      printWithLength(sprintf(%Q(%s\n<response %s command="%s" 
                                      depth="%d" transaction_id="%s" />),
                              xmlHeader(),
                              namespaceAttr(),
                              @cmd, @frames.size, @transactionID))
    end
  
    def do_stack_get(cmdArgs, file_URI_No, line, id, binding)
      stackDepth = getArg(cmdArgs, '-d', 'default' => '0');
      begin
        stackDepth = stackDepth.to_i
        raise "Negative stack_depth" if stackDepth < 0
      rescue => msg
        return _makeErrorResponse(DBP_E_StackDepthInvalid,
                                  "Invalid stack depth arg of '#{stackDepth}' : #{msg}")
      end
      res = _response_start_1() + "\n"
      sd = stackDepth
      @frames.reverse[stackDepth .. -1].each { |f|
        fbinding, ffile_URI_No, fline, fcontext = f
        if ffile_URI_No == EvalStringEntry
          ftype = "eval"
          ffile = @@base_eval_uri + "-" + @@eval_count.to_s
        else
          ftype = "file"
          ffile = @ftable.get_URI(ffile_URI_No)
        end
        fcontext2 = fcontext ? xmlAttrEncode(fcontext.to_s) : ""
        res += sprintf(%Q(<stack level="%d" type="%s" filename="%s" lineno="%s" where="%s"/>\n),
                       sd, ftype, ffile, fline, fcontext2)
        sd += 1
      }
      res += "\n</response>\n";
      # dblog("#{@cmd} => #{res}") if $ldebug;
      printWithLength(res);                         
    end
  
    def do_context_names(cmdArgs, file_URI_No, line, id, binding)
      # stack-depth not used yet
      # stackDepth = getArg(cmdArgs, '-d', 'default' => '0');
      res = _response_start_1()
      @propInfo.contextPropertyNames.each {|name|
        res += sprintf(%Q(<context name="%s" id="%d" />\n),
                       name,
                       @propInfo.contextProperties[name])
      }
      res += "\n</response>\n";
      printWithLength(res);
    end

    def get_adjusted_stack_depth(proposed_stack_depth)
      currStackSize = @frames.size
      # Reverse the meaning of stack-depth
      stackDepth = (currStackSize > proposed_stack_depth ?
                    currStackSize - proposed_stack_depth - 1 : 0)
      dblog("get_adjusted_stack_depth: mapping (prop sd, stack sz => new stack sz) = (%d, %d => %d)", proposed_stack_depth, currStackSize, proposed_stack_depth)
      return stackDepth
    end
    private :get_adjusted_stack_depth
    
    def do_context_get(cmdArgs, file_URI_No, line, id, binding)
      stackDepth = get_adjusted_stack_depth(getArg(cmdArgs, '-d', 'default' => 0).to_i)
      context_id = getArg(cmdArgs, '-c', 'default' => 0).to_i
      _settings = @settings['max_depth'][0]
      begin
        the_binding = @frames[stackDepth][FRAME_IDX_BINDING] || binding
        sorted = false
        case context_id
        when LocalVars
          names = eval('local_variables', the_binding)
        when InstanceVars
          inames = eval('instance_variables', the_binding)



          cnames = eval('self.class.class_variables', the_binding)



          names = @propInfo.get_sorted_object_varnames(inames, cnames, @settings['sort_ignore_at_signs'][0] == 1).collect {|name, status| name}



          sorted = true
        when PunctuationVariables
          names = global_variables.delete_if {|x|
            x =~ /^\$[_a-zA-Z]/
          }
        when GlobalVars
          # User-space globals
          names = global_variables.delete_if {|x|
            x =~ /^\$[^_a-z]/ ||
              x == "$ldebug"
          }
        when BuiltinGlobals
          # Ruby-space globals
          names = global_variables.delete_if {|x|
            x =~ /^\$[^A-Z]/
          }
        end
        dblog("vars (#{context_id}):", names.join(" ")) if $ldebug;
        namesAndValues = []
        names.sort! unless sorted
        names.each {|name|
          val = debug_log_eval(name, the_binding)
          if !val.nil? && (val.to_s.length > 0 ||
                           val.instance_variables.length > 0)
            namesAndValues << [name, val]
          end
        }
        res = @propInfo.emitContextProperties(@cmd, context_id, @transactionID,
                                              namesAndValues,
                                              @settings['max_data'][0])
        printWithLength(res)
      rescue => msg
        _makeErrorResponse(DBP_E_ParseError, _trimExceptionInfo(msg))
      ensure
        @settings['max_depth'][0] = _settings
      end
    end
    
    def do_property_get(cmdArgs, file_URI_No, line, id, binding)
      key_address, context_id, stackDepth, propertyKey, maxDataSize, property_long_name, \
      pageIndex, data_type = pickArgs(cmdArgs, 'a:c+:d+:k:m+:n:p+:t:')
      return _makeErrorResponse(DBP_E_InvalidOption, "No long name supplied") if property_long_name.nil?
      maxDataSize = @settings['max_data'][0] if maxDataSize.nil? or maxDataSize == 0
      stackDepth = get_adjusted_stack_depth(stackDepth)
      # Context doesn't matter here.
      the_binding = @frames[stackDepth][FRAME_IDX_BINDING] || binding
      begin
        val = debug_log_eval_check_address(property_long_name, the_binding, key_address)
        res = @propInfo.emitProperty(@cmd, context_id, @transactionID,
                                     property_long_name, val, pageIndex,
                                     @settings['max_children'][0],
                                     maxDataSize,
                                     (@settings['sort_ignore_at_signs'][0] == 1))
        printWithLength(res)
      rescue => msg
        _makeErrorResponse(DBP_E_PropertyEvalError, "Can't get a value for #{property_long_name}: (#{msg}")
      end
    end
    
    def do_property_value(cmdArgs, file_URI_No, line, id, binding)
      context_id, stackDepth, propertyKey, property_long_name = pickArgs(cmdArgs, 'c+:d+:k:n:')
      if @@is_keyword[property_long_name]
        res = @propInfo.emitPropertyValue(@cmd, context_id, @transactionID,
                                   property_long_name, '', 0,
                                   @settings['max_children'][0],
                                          10)
        printWithLength(res)
        return
      end
      return _makeErrorResponse(DBP_E_InvalidOption, "No long name supplied") if property_long_name.nil?
      if propertyKey
        return _makeErrorResponse(DBP_E_InvalidOption, "Value #{propertyKey} too complex right now")
      end
      maxDataSize = @settings['max_data'][0]
      stackDepth = get_adjusted_stack_depth(stackDepth)
      the_binding = @frames[stackDepth][FRAME_IDX_BINDING] || binding
      pageIndex = 0
      begin
        val = debug_log_eval(property_long_name, the_binding)
        res = @propInfo.emitPropertyValue(@cmd, context_id, @transactionID,
                                   property_long_name, val, pageIndex,
                                   @settings['max_children'][0],
                                          maxDataSize)
        printWithLength(res)
      rescue => msg
        _makeErrorResponse(DBP_E_PropertyEvalError, "Can't get a value for #{property_long_name}: (#{msg}")
      end
    end
  
    def do_property_set(cmdArgs, file_URI_No, line, id, binding)
      key_address, context_id, stackDepth, propertyKey, advertisedDataLength, maxDataSize, property_long_name, \
      pageIndex, data_type = pickArgs(cmdArgs, 'a:c+:d+:k:l+:m+:n:p+:t:')
      return _makeErrorResponse(DBP_E_InvalidOption, "No long name supplied") if property_long_name.nil?
      new_val = decodeData(getDataArgs(cmdArgs), "base64")
      if data_type == "string" && new_val !~ /^\s*\d+\s*$/
        new_val = '"' + new_val.gsub('"', '\\"') + '"'
      end
      
      # Context doesn't matter here.
      stackDepth = get_adjusted_stack_depth(stackDepth)
      the_binding = @frames[stackDepth][FRAME_IDX_BINDING] || binding
      begin
        debug_log_set(property_long_name, new_val, the_binding, key_address)
        printWithLength(sprintf(%Q(%s\n<response %s command="%s" 
                                      transaction_id="%s" success="1" />),
                              xmlHeader(),
                              namespaceAttr(),
                              @cmd, @transactionID))
      rescue => msg
        dblog("debug_log_set: ", msg)
        _makeErrorResponse(DBP_E_CantSetProperty, "Can't set [#{property_long_name}] to [#{new_val}]: (#{msg}")
      end
    end
  
    def do_typemap_get(cmdArgs, file_URI_No, line, id, binding)
      res = sprintf(%Q(%s\n<response %s %s %s command="%s"\n transaction_id="%s" >),
                    xmlHeader(),
                    namespaceAttr(),
                    xsdNamespace(),
                    xsiNamespace(),
                    @cmd,
                    @transactionID)
      # Schema, CommonTypeName (type attr) LanguageTypeName (name attr)
      names =  [['boolean', 'bool'],
        ['float'],
        ['integer', 'int'],
        ['string']]
      names.each {|e|
        xsdName = e[0];
        commonTypeName = e[1] || xsdName;
        languageTypeName = e[2] || commonTypeName;
        res += %Q(<map type="#{commonTypeName}" name="#{languageTypeName}" xsi:type="xsd:#{xsdName}"/>);
      }
      printWithLength(res + "\n</response>")
    end

    def do_source(cmdArgs, file_URI_No, line, id, binding)
      begin
        beginLine, endLine, fileURI = pickArgs(cmdArgs, 'b+:e+:f:')
        raise "No file URI specified." unless fileURI
        if fileURI[@@base_eval_uri]
          source = "# Sorry, source isn't available for eval statements in Ruby\n"
        else
          source = do_source_file(fileURI)
        end
        numLines = source.count("\n")
        actualBeginLine = beginLine <= 0 ? 0 : beginLine - 1
        # Sanity check the end-line
        if endLine == 0
          actualEndLine = numLines - 1
        elsif endLine >= numLines
          actualEndLine = numLines - 1
        elsif endLine < beginLine
          actualEndLine = beginLine
        else
          actualEndLine = endLine
        end
        a1 = source.split(/\n/, actualEndLine + 2)
        a2 = a1[actualBeginLine .. -2]
        s2 = a2.join("\n")
        s2 = "" if s2.nil?
        encoding = @settings['data_encoding'][0]
        encVal = "<![CDATA[" + encodeData(cdataEncode(s2), encoding) + "]]>"
        printWithLength(sprintf(%Q(%s\n<response %s command="%s"
                                transaction_id="%s" success="1"
                                encoding=\"%s\">%s</response>\n),
                              xmlHeader(),
                              namespaceAttr(),
                                @cmd,
                                @transactionID,
                                encoding,
                                encVal))
      rescue => msg
        _makeErrorResponse(DBP_E_CantOpenSource, msg)
      end
    end

    def do_source_file(fileURI)
      # For now just loop through the loaded files
      # going by basename
      filename = @ftable.uriToFilename(fileURI)
      raise "Can't work with URI #{fileURI}" unless filename
      basename = File.basename(filename)
      begin
        fd = File.open(fn = basename, 'r')
      rescue
        begin
          fd = File.open(fn = filename, 'r')
        rescue
          fd = nil
        end
      end
      if fd
        begin
          source = fd.read()
          fd.close
          dblog("Pulled source [[%s]] right out of file %s", source, fn)
        rescue
          fd = nil
        end
      end
      if !fd
        source = do_source_file_from_script_lines(filename, basename)
      end
      source += "\n" unless source[-1] == ?\n
      return source
    end

    def do_source_file_from_script_lines(filename, basename)
      re = Regexp.new("\\b#{basename}$", isWin32())
      dblog("do_source_file -- looking for URI %s, file %s\n", fileURI, filename)
      SCRIPT_LINES__.each{|key, val|
        dblog("do_source_file -- looking at file %s\n", key)
        if re.match(key)
          dblog("do_source_file -- yes\n")
          source = nil
          begin
            if val && val[0] && val[0].size == 0 && val.size > 0
              source = File.open(key, "r") { |fd| fd.read() }
            end
          rescue => msg
            dblog("do_source_file recovery: error %s reading file %s", msg, file)
          end
          source = val.join("") unless source
          source += "\n" unless source[-1] == ?\n
          return source
        end
        dblog("do_source_file -- no\n")
      }
      throw "Couldn't find a file matching #{filename}"
    end

    def do_common_stdio_redirection(cmdArgs, origStream, streamType)
      copyType = getArg(cmdArgs, '-c', 'default' => 0).to_i
      raise "Invalid -c value of #{copyType}" unless (RedirectStdOutput::DBGP_Redirect_Disable .. RedirectStdOutput::DBGP_Redirect_Redirect) === copyType
      obj = RedirectStdOutput.new(origStream, @out_sock, streamType, copyType, @debugger__)
      # Print common code before continuing
      res = generic_response_start_tag_start + 'success="1"/>'
      printWithLength(res);
      return obj
    end
    
    def do_stderr(cmdArgs, file_URI_No, line, id, binding)
#      res = generic_response_start_tag_start + 'success="1"/>'
#      printWithLength(res);
#      return
      begin
        $stderr = @stderr = do_common_stdio_redirection(cmdArgs, $stderr, 'stderr')
        @stderr.default_encoding = @settings['data_encoding'][0]
      rescue => msg
        _makeErrorResponse(DBP_E_InvalidOption, msg)
      end
    end

    def do_stdout(cmdArgs, file_URI_No, line, id, binding)
      begin
        $stdout = @stdout = do_common_stdio_redirection(cmdArgs, $stdout, 'stdout')
	if $ldebug
	  dblog("stdout is now : #{$stdout.dump}\n")
	end
        @stdout.default_encoding = @settings['data_encoding'][0]
      rescue => msg
        _makeErrorResponse(DBP_E_InvalidOption, msg)
      end
    end

    def do_interact(cmdArgs, file_URI_No, line, id, binding)
      do_abort, i_mode = pickArgs(cmdArgs, 'a:m+:')
      decodedData = decodeData(getDataArgs(cmdArgs), "base64")
      @stopReason = STOP_REASON_INTERACT
      @ibState = IB_STATE_START if @ibState == IB_STATE_NONE
      if i_mode && i_mode == 0
        @ibState = IB_STATE_NONE
        @stopReason = @startedAsInteractiveShell ? STOP_REASON_STOPPED : STOP_REASON_BREAK
        printWithLength(sprintf(%Q(%s\n<response %s command="%s"
                                transaction_id="%s"
                                status="%s"
                                reason="ok"                                
                                more="0"
                                prompt=""
                                />),
                                xmlHeader(),
                                namespaceAttr(),
                                @cmd,
                                @transactionID,
                                getStopReason()));
        return true # NEXT
      end
      @stopReason = STOP_REASON_INTERACT
      if !do_abort && decodedData
        if @ibState == IB_STATE_START
          @ibBuffer = decodedData
        else
          @ibBuffer += "\n#{decodedData}"
          case @ibBuffer
          when /<<(\w+).+^\1$/sm
            # dblog("Found bareword here-doc ending for [#{@ibBuffer}]")
            @ibBuffer += "\n"
          when /<<([\"\'])((?:\.|.)*?)\1.*^\2$/sm
            dblog("Found quoted-target here-doc ending for [#{@ibBuffer}]")
            @ibBuffer += "\n"
          when /<< .*\n$/s
            dblog("Found empty-line here-doc ending for [#{@ibBuffer}]")
            @ibBuffer += "\n"
          end
          dblog("Have -- 1 ** [#{@ibBuffer}]")
        end
        @ibBuffer.gsub!(/^\s+$/, '') # Remove all white-space
        @doContinue = false
        if @ibBuffer.length > 0
          if @ibBuffer =~ /^(.*?[^\\](?:\\\\)*)\\$/m
            # Make sure the final \\ isn't an escaped
            # \\ at the end of a string.
            @ibBuffer = $1
            dblog("found it, now: #{@ibBuffer}")
            @doContinue = true
          else
            #XXX: Capture stdout side effects
            begin
              dblog("Have -- 3 ** [#{@ibBuffer}]");
              res = eval(@ibBuffer, binding)
              #dblog("After eval, res is a #{res.class}")
              @doContinue = false
              mainError = nil
            rescue SyntaxError
              mainError = $! && $!.to_s
              res = nil
              dblog("Syntax Error: #{mainError}")
              # Don't complain about syntax errors at the end of the line
              if mainError =~ /^(.*)\n(\s*)\^\s*$/ && $2.size < $1.size
                # This doesn't handle tabs correctly, but we can't
                # get the tab size from the IDE.
                @doContinue = false
              elsif mainError =~ /:\d+:\s*syntax error.*\n.*:\d+:\s*syntax error/m
                # Two syntax errors: print them and bail out
                dblog("Found two syntax errors in |#{mainError}|")
                @doContinue = false
              elsif mainError =~ /:(\d+):\s*syntax error.*/ && $1.to_i < @ibBuffer.split(/\n/).size
                dblog("Got a syntax error at line %d of %d", $1.to_i, @ibBuffer.split(/\n/).size)
                @doContinue = false
              elsif decodedData =~ @@stop_collecting_cmd_re
                @doContinue = false
                mainError = nil
              else
                @doContinue = true
                res = '*resetting command buffer*'
              end
            rescue ScriptError
              mainError = $! && $!.to_s
              res = nil
              dblog("Script Error: #{mainError}")
              @doContinue = false
            rescue Exception
              mainError = $! && $!.to_s
              if mainError == 'exit'
                Kernel.exit!(0)
              end
              res = nil
              dblog("general Exception: #{mainError}")
              @doContinue = false
            end
          end
          if @doContinue
            @ibState = IB_STATE_PENDING
            moreValue = 1
          else
            @ibState = IB_STATE_START
            moreValue = 0
            if mainError
              # Make sure we print one last \n
              $stderr.print((mainError + "\n").sub(/\n+$/, "\n"))
            elsif res.nil?
              print "\n"
              #dblog('res is nil')
            elsif res.class == String
              #dblog("res is a string = #{res}")
              print res
              print "\n" unless res[-1] == ?\n
            else
              #dblog("res is a #{res.class}")
              require 'pp'
              pp res
            end
          end
        else
          #dblog("interact: decodedData not defined\n")
          if !i_mode || @ibState == IB_STATE_START
            #dblog("State start")
            moreValue = 0
          else
            moreValue = 1
          end
        end
      end
      printWithLength(sprintf(%Q(%s\n<response %s command="%s" 
                          transaction_id="%s"
                          status="%s"
                          more="%d"
                          prompt="%s"
                          />),
                       xmlHeader(),
                       namespaceAttr(),
                       @cmd,
                       @transactionID,
                       getStopReason(),
                       moreValue,
                       @@prompts[moreValue]
                       ))
    end

    ################ Other Helper Functions ################
    
    def close_socket
      @out_sock.close_write()
    end

    def getStopReason
      res = @@stopReasons[@stopReason]
      raise "Bad stop reason: #{@stopReason}" if res.nil?
      res
    end

    def xsdNamespace
      return %q(xmlns:xsd="http://www.w3.org/2001/XMLSchema");
    end

    def xsiNamespace
      return %q(xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance");
    end

    ################ Property Get/Set Helper Functions ################

    def reflect_expression(str)
      return str.gsub(/.(@@\w+)/, %Q(.class.class_eval("\\1"))).gsub(/\.(\@\w+)/, %Q(.instance_eval("\\1")))
    end

    def debug_log_eval(str, binding)
      if str =~ /^\!backdoor\b(.*)$/
        # backdoor in this context..., must return something
        #
        # samples
        #
        # !backdoor @debugger__.instance_eval('@logger.level = Logger::DEBUG')
        # !backdoor $ldebug=true
        #
        # Sort ignoring @
        # !backdoor @settings['sort_ignore_at_signs'][0] = 0
        #
        # This is all it is: use the binding of the context class
        #
        return eval($1) || ""
      end

      begin
        # Replace instance and class variables in expressions
        # with calls to reflection API
        # Do not use getters -- this can cause unwanted side-effects
        # for complex getters.
        #
        #XXX - don't translate instances of /\.@\w/ inside keys.
        #
        # Also, note that dbgp doesn't allow for non-string keys.
        
        str2 = reflect_expression(str)
        return eval(str2, binding)
      rescue StandardError, ScriptError => e
        dblog("trying to eval[#{str} => #{e}") if $ldebug
      end
      return nil
    end

    def debug_log_eval_check_address(str, binding, key_address)
      if key_address.to_s.length > 0 && str =~ /^(.*)\[([^\[\]]*)\]$/
        first_part = $1
        # Ignore the key, as we're using key_address
        str2 = reflect_expression(first_part) + "[ObjectSpace._id2ref(#{key_address.to_i})]";
        begin
          # dblog("About to eval {#{str2}}...")
          res = eval(str2, binding)
          return res
        rescue StandardError, ScriptError => e
          dblog("trying to eval[#{str} => #{e}") if $ldebug
        end
      end
      return debug_log_eval(str, binding)
    end

    def debug_log_hashval_set(lhs, new_val2, binding, key_address)
      if lhs =~ /^(.*)\[([^\[\]]*)\]$/
        first_part = $1
        # Ignore the key, as we're using key_address
        str2 = reflect_expression(first_part) + "[ObjectSpace._id2ref(#{key_address})] = " + new_val2;
        begin
          # dblog("About to eval {#{str2}}...")
          res = eval(str2, binding)
          return true
        rescue StandardError, NameError, ScriptError => e
          dblog("Trying to eval (%s), got error %s", str2, msg)
          dblog("do_property_set:%s:%d", __FILE__, __LINE__)
        rescue => msg
          dblog("Trying to eval (%s), got error %s", str2, msg)
          dblog("do_property_set:%s:%d", __FILE__, __LINE__)
        end
      end
    end
    
    def debug_log_set(lhs, new_val, binding, key_address=nil)
      new_val2 = new_val.to_s
      if ! key_address.nil?
        res = debug_log_hashval_set(lhs, new_val2, binding, key_address.to_i)
        return if res
      end
      if lhs =~ /^(.*)\.(@@\w+)$/
        first_part, accessor = $1, $2
        # For some reason this one needs the string-eval form, not the block.
        str2 = reflect_expression(first_part) + ".class.class_eval(%Q(#{accessor} = #{new_val2}))"
      elsif lhs =~ /^(.*)\.(@\w+)$/
        first_part, accessor = $1, $2
        str2 = reflect_expression(first_part) + ".instance_eval{" + accessor + " = " + new_val2 + "}"
      else
        str2 = reflect_expression(lhs) + " = " + new_val2
      end
      begin
        # dblog("debug_log_set: About to eval {#{str2}}...")
        res = eval(str2, binding)
        return
      rescue StandardError, NameError, ScriptError => e
        dblog("trying to eval[#{str} => #{e}") if $ldebug
      rescue => msg
        dblog("Trying to eval (%s), got error %s", str2, msg)
      end
    end
    
    ################ Generic Helper Functions ################

    def _send_break_status
      printWithLength(sprintf(%Q(%s\n<response %s command="%s" status="break")\
                              ' reason="ok" transaction_id="%s"/>',
                       xmlHeader(),
                       namespaceAttr(),
                       @cmd,
                       @transactionID));
    end
  
    def _response_start_1
      return generic_response_start_tag_start() + " >"
    end

    def generic_response_start_tag_start
      return sprintf(%Q(%s<response %s command="%s" transaction_id="%s" ),
                     xmlHeader(), namespaceAttr(), @cmd, @transactionID)
    end
  
    def _makeErrorResponse(ecode, emsg)
      makeErrorResponse(@cmd,
                         @transactionID,
                         ecode,
                         emsg)
    end

    def conditional_hash(h, k, v="")
      h.has_key?(k) ? h[k] : v
    end
    
    def sendInitString
      # Send the init command at this point
      ppid = conditional_hash(ENV, 'DEBUGGER_APPID')
      appid = $$.to_s;  # getpid
      ideKey = conditional_hash(ENV, 'DBGP_IDEKEY')
      initString = sprintf(%Q(%s\n<init %s
                                    appid="%s"
                                    idekey="%s"
                                    parent="%s"
                                   ),
                                 xmlHeader(),
                                 namespaceAttr(),
                                 appid,
                                 ideKey,
                                 ppid
                                 )
      if ENV.has_key?('DBGP_COOKIE') && ENV['DBGP_COOKIE'].length > 0
        initString += %Q( session="#{ENV['DBGP_COOKIE']}")
      end
      initString += sprintf(%Q( thread="%s" language="%s" protocol_version="%s"),
                               # Thread.current,
                            sprintf("%s %s", 
                                    (Thread.current == Thread.main ? "main" : "Thread"), thread_idx()),
                               # Thread.current == Thread.main ? '0' : Thread.current.to_s,
                               'Ruby', # Language
                               1	# Protocol
                               )
      if @startedAsInteractiveShell
	initString += ' interactive=">"'
      else
        initString += ' fileuri="' + @ftable.filenameToURI(__FILE__) + '"'
      end
      initString += '/>'
      printWithLength(initString);
      ENV['DEBUGGER_APPID'] = appid;
    end
        
    def decodeCmdLineData(dataLength, args)
        currDataEncoding = settings[data_encoding][0];
        if (currDataEncoding == 'none' || currDataEncoding == 'binary')
          decodedData = join(" ", args);
        elsif args.size == 0
          return _makeErrorResponse(DBP_E_CommandUnimplemented, @cmd)
        else
          decodedData = decodeData(args.join(""))
        end
        dataLength = decodedData.length
        dblog("decodeCmdLineData: returning [$decodedData]\n") if $ldebug;
        return [dataLength, currDataEncoding, decodedData]
    end

    ################ Tracer Helper Functions ################
    #
    # Tracing is owned by the Context, not the Debugger,
    # as each thread has to keep track of its own stack-frame
          
    def trace?
      true
    end

    private
    
    def eval_count_inc
        @@eval_count += 1
    end
    
    def do_trace_push_state(file_URI_No, line, id, binding)
      # Save the current @single status
      # Map step_over to stop_into current frame, dont_stop new frame
      adjust_single_on_call()  # Updates @single
      @frames.push [binding, file_URI_No, line, id]
    end
    
    def do_trace_pop_state()
      if @frames.size == 0
        # Leave @single as is
        dblog("@frames is empty on trace_pop_state \n\t" + caller.join("\n\t") + "\n")
      else
        # What were we doing at the end of the closing scope?
        if @frames.size == 1
          dblog("@frames emptied on trace_pop_state \n\t" + caller.join("\n\t") + "\n")
          @frames = []
          return
        end
        @frames.pop
      end
    end
        
    # context/thread-based Thread management functions
  
  end # end class

  #XXX Make this work with different versions, and in unprocessed-mode






  begin
    require "DB/#{RUBY_VERSION}/ccontext"
    CDbgr_Context.cc_extend_class(Context)
  rescue LoadError
    # Can't find/load the binary
  class Context





      require 'DB/ccontext_fallback'



    include Dbgr_Context_fallback
  end
    
  end




end # end module
