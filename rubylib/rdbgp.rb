#!/usr/bin/ruby
# Copyright (c) 2005-2006 ActiveState Software Inc.
#
# See the LICENSE file for full details on this software's license.
#
# Authors:
#    Eric Promislow <EricP@ActiveState.com>

=begin
= rdbgp.rb

A DBGP-based Ruby Debugger library

To be invoked with this command:

ruby -I<path to rdbgp.rb> -r rdbgp.rb program.rb

set RUBYDB_OPTS to the following space-separated values:

    remoteport=<hostname>:<port>        - location of debug server
    logfile={stderr|stdout|<dirpath>|<filepath>}
                                - turns logging onto specified destination
                                If only a dir is specified, use filename ruby_dbgp.log
    
    Possible future options (not yet supported):
    ide_key=<key>     - an IDE key used with proxies
    interactive       - start debugger in interactive mode (not yet supported)
    nodebug           - run without debugging (not yet supported)
    log_level={CRITICAL|ERROR|WARN|INFO|DEBUG}
                      - Logging levels from the logging module:

Options need to be separated by spaces.

Strings such as file and directory names/paths might be urlescaped.

=end

$RUBY_DBGP_VERSION = 0.80

# Require at least ruby 1.8
if RUBY_VERSION.to_f < 1.8
  msgs = ["The Komodo Ruby debugger requires at least version 1.8 of Ruby"]
  msgs << "The current version is #{RUBY_VERSION}"
  msgs << "Please select a newer interpreter in the preferences section,"
  msgs << "or download a newer version from http://www.ruby-lang.org/"
  msgs << ""
  $stderr.print(msgs.join("\n"))
  exit
end

# Modules to bring in
# No setup code will go through the trace proc,
# as that's the last thing we do.

begin
  require 'logger'
rescue LoadError
  require 'DB/logger_fallback'  # Older versions don't have a logger module
end

require 'tracer'
require 'pp'

class Tracer
  def Tracer.trace_func(event, file, line, id, binding, klass)
    return sprintf("**** event %s, file %s, line %d, id %s, class %s, thread %s\n",
                   event, file, line, id, (!klass ? "<nil>" : klass), Thread.current)
    # Single.trace_func(*vars)
  end
end

# Classes

SCRIPT_LINES__ = {} unless defined? SCRIPT_LINES__

module DebuggerShroud

class DEBUGGER__
  # Singleton stuff

# Import our own modules and files







require 'DB/breakpoints'   #exposed DBGP_Breakpoints class
require 'DB/filetable'




include FileTable

require 'DB/constants'     #buncha global constants
include DBGR_Constants

require 'DB/commandline'   #command-line handling module
include Dbgr_Commandline






require 'DB/DbgrCommon'




# Don't do this -- keep internal debugger names out of this namespace.
# include Dbgr_Common







require 'DB/function_breakpoints' # Function breakpoints lookup class
require 'DB/redirect'



include DBGR_FunctionBreakpoints







require 'DB/DbgrProperties'
# Context class
require 'DB/context'



include Dbgr_Properties

# Settings
require 'DB/settings'

#External stuff





  begin
    require "DB/#{RUBY_VERSION}/crdbgp"
  rescue LoadError
    # Can't find/load the binary
    require 'DB/crdbgp_fallback'
  end



include CRdbgp
  
  @@dbgr = nil
  @@guard_line = nil
  private_class_method :new
  def DEBUGGER__.get
    @@dbgr = new unless @@dbgr
    @@dbgr
  end

  def initialize
    @threads = [Thread.current]
    @worker_threads = {}
    @logger = Logger.new(STDERR)
    @logger.level = Logger::ERROR
    @local_eval_ids = [:get, :is_in_debugger?]
    @kernel_ids = [:require, :eval, :instance_eval, :class_eval]
    @event_name_to_num = {
      'line' 		=> RB_EVENT_LINE,
      'call'		=> RB_EVENT_CALL,
      'c-call'		=> RB_EVENT_C_CALL,
      'c-return'	=> RB_EVENT_C_RETURN,
      'class'		=> RB_EVENT_CLASS,
      'return'		=> RB_EVENT_RETURN,
      'end'		=> RB_EVENT_END,
      'raise'		=> RB_EVENT_RAISE,
      'unknown'		=> RB_EVENT_UNKNOWN,
    }
  end

  require 'DB/mutex'
  class FakeMutex
    def locked?
      false
    end
    def lock
    end
    def unlock
    end
  end
  # MUTEX = FakeMutex.new
  MUTEX = RDBGP::Mutex.new
  @debug_guard = true        # One-time only guard while we're processing this file
  attr_accessor :debug_guard   # Only changed from the context
  attr_reader :trace_proc, :bpts, :function_bpts, :propInfo, :ftable
  attr_reader :single
  attr_reader :stdout, :stderr, :worker_threads
  attr_reader :remotehost, :remoteport, :main_settings, :kernel_ids
  attr_accessor :waiting
    
  def main
    # Access to all the breakpoint info
    @ftable = FileNameTable.new
    # @ftable = FileNameTable.new(Dir.getwd())
    @bpts = DBGP_Breakpoints.new(self, @ftable, Dir.getwd())
    @function_bpts = FunctionBreakpoints.new(@bpts)
    
    # Access to the property stuff
    @propInfo = Dbgr_Properties.new()
    @propInfo.default_encoding = 'base64'
    
    # Redirector streams
    @stdout = @stderr = nil

    # Debugger-wide global
    $ldebug = false
    
    @trace_proc =  proc { |event, file, line, id, binding, klass, *rest|
      trace_func event, file, line, id, binding, klass
    }

    @main_settings = Dbgr_Settings::Settings.new
    @supportedCommands, @supportedFeatures, @settings = @main_settings.get
    @bpts.settings(@settings)

    # Duplicate the filehandles
    
    @out_fh = STDOUT.clone || STDERR.clone
    @out_fh.sync = true
    STDOUT.sync = true if STDOUT
    STDERR.sync = true if STDERR
    
    @remoteport = nil
    @remotehost = nil
    
    if !ENV['RUBYDB_OPTS'].nil?
      options = parse_options(ENV['RUBYDB_OPTS'])
      @remoteport = options["remoteport"]
      if (log_info = options['logfile'])
        begin
          case log_info.downcase
          when 'stderr'
            @logger = Logger.new(STDERR) unless defined? @logger
          when 'stdout'
            @logger = Logger.new(STDOUT)
          else
            # Check to see if the filename is urlencoded
            if (log_info =~ /\%u?[a-fA-F0-9]{2}/ &&
                  !FileTest.directory?(log_info) &&
                  !FileTest.directory?(File.dirname(log_info)))
              require 'cgi'
              log_info = CGI.unescape(log_info);
            end
            if FileTest.directory?(log_info)
              log_info = log_info.gsub('\\', '/').sub(%r(/$), '') + "/ruby_dbgp.log"
            end
            @logger = Logger.new(log_info)
          end
          @logger.level = Logger::DEBUG
          @logger.debug("Komodo Ruby debugger version #{$RUBY_DBGP_VERSION} -- starting...")
          $ldebug = true
        rescue Exception => e
          $stderr.print("Got exception in logger: #{e}, #{e.backtrace}\n")
        rescue
          # This shouldn't fire an exception
        end
      end
    end
    
    if @remoteport.nil?
      if ENV.has_key?('@remoteport')
        @remoteport = ENV['@remoteport']
      else
        raise "Env variable @remoteport not set.";
      end
    else
      dblog("@remoteport = " + @remoteport)
    end
    @remotehost, @remoteport = @remoteport.split(/:/)
    if @remoteport.to_s !~ /^\d+$/
      raise "Env variable @Remoteport not numeric (set to #{remoteport}).";
    end

    @waiting = []

    @context = context()
    
    @curr_thread = Thread.current
    
    @_this_file_re = Regexp.new("(?:\\b|\\A)" + Regexp.escape(__FILE__))
    
  end

  def is_in_debugger?
    # This should be in the context!
    return @debug_guard || context.dbgp_in_debugger
  end

  def dblog(*vals)
    if vals.size > 0
      str2 = nil
      if $ldebug && vals.size > 1 && vals[0].index('%')
        begin
          str2 = sprintf(*vals)
        rescue => msg
          @logger.debug("**** Internal error in dblog: " + msg.to_s)
        end
      end
      if !str2
        if vals.class == Array
          vals[-1].to_s.chomp!
          str2 = vals.join(" ")
        else
          str2 = vals.chomp
        end
      end
      @logger.debug(Thread.current.to_s + "\n\t" + str2)
    end
  end
    
  def parse_options(opts)
    options = {}
    while opts.length > 0
      if opts =~ /^\s+(.*)$/
        opts = $1
      elsif opts =~ /^(\w+)=(.*)/
        name, rest = $1, $2
        if rest =~ /^([\"\'])(.*?)\1(.*)$/
          val, opts = $2, $3
        elsif rest =~ /^(.*?)\s+(.*)$/
          val, opts = $1, $2
        else
          val = rest
          opts = ""
        end
        options[name.downcase] = val
      else
        break
      end
    end  # end while
    options
  end

  def function_stack_check(callType, function_symbol, klass, binding)
    return if @single == SINGLE_STEP_IN # we're about to break anyway.
    if @function_bpts.break_at_function_call(callType, function_symbol.to_s, klass, binding)
      @single = @context.single = SINGLE_STEP_IN
    end
  end

  def trace?
    true
  end

  def mutex
    MUTEX
  end

  def thread_swap_check
    if (this_thread = Thread.current) != @curr_thread



      # @single = @context.single
      @context = context(this_thread)
      @context.update_debugger_vals(self)
      # @context.single = @single
      @curr_thread = this_thread
    end
  end
    
  def trace_func(event, file, line, id, binding, klass)
    # Check for a new thread
    return if @debug_guard
    return if @worker_threads[Thread.current]
    mutex.lock
    begin
      thread_swap_check






      event_num = @event_name_to_num[event]
      if c_discard_event(event_num, file, id, klass, 0)



        return
      end

      @context.cc_trace_func2(event_num, file, line, id, binding, klass)
    ensure
      mutex.unlock
    end
  end
  
  def context(thread=Thread.current)
    c = thread[:__debugger_context__]
    if !c
      thread[:__debugger_context__] = c = Dbgr_Context::Context.new(self)
      setup_thread(c, thread)
    end
    c
  end

  def suspend
    saved_crit = Thread.critical
    Thread.critical = true
    for thread in @threads
      next if !thread || thread == Thread.current || thread.status != "run"
      context(thread).set_suspend
    end
    Thread.critical = saved_crit
    # Schedule other threads to suspend as soon as possible.
    Thread.pass unless Thread.critical
  end

  def resume
    saved_crit = Thread.critical
    Thread.critical = true
    for thread in @threads
      next if !thread || thread == Thread.current || thread.status != "run"
      context(thread).clear_suspend
    end
    waiting.each do |thread|
      thread.run
    end
    waiting.clear
    Thread.critical = saved_crit
    # Schedule other threads to restart as soon as possible.
    Thread.pass
  end

  def wrap_up
    if $!
      $stderr.printf("%s\n%s\n", $!.to_s, $@.join("\n"))
    end
    @context.wrap_up
#    @threads.each do |thread|
#      context(thread).wrap_up() if thread && thread.status == "run"
#    end
  end

  def setup_thread(c, thread)
    # Have the main thread reference the global settings
    #
    # Other threads will either reference or clone these
    # I'm not sure which yet

    c.supportedCommands, c.supportedFeatures, c.settings = @main_settings.get
    c.final_init
    c.refresh_debugger_vals(self)
    c.last_ditch_initialize
    @threads << thread
  end

  # global/DEBUGGER__-based Thread management functions

end  # end class DEBUGGER__
end  # end module DebuggerShroud

Thread.abort_on_exception = true
dbgr = DebuggerShroud::DEBUGGER__.get()

# make sure we don't end up showing this in the callstack.

module DebuggerShroud
class DEBUGGER__
  @@guard_line = __LINE__
end
end

if dbgr
  
  dbgr.debug_guard = false

  begin
    dbgr.main()
    dbgr.context.last_ditch_initialize
    set_trace_func(dbgr.trace_proc)
  end
  
end  # end if dbgr

END {
  set_trace_func(nil)
  if dbgr
    dbgr.wrap_up()
  end
}
