#!/usr/bin/ruby
# Copyright (c) 2005-2006 ActiveState Software Inc.
#
# See the LICENSE file for full details on this software's license.
#
# Authors:
#    Eric Promislow <EricP@ActiveState.com>

# This class subclasses IO so we can set $defout and $deferr to it,
# but it follows a delegate pattern.  It would be good to have
# an "AUTOLOAD" method, but I'm not sure how, to handle undefined
# methods.

class RedirectStdOutput < IO






  require 'DB/DbgrCommon'



  include Dbgr_Common

  VERSION = 0.10;
  DBGP_Redirect_Disable = 0;
  DBGP_Redirect_Copy = 1;
  DBGP_Redirect_Redirect = 2;

  attr_writer :default_encoding
  @default_encoding = nil
  @@orig_stderr = $stderr
  
  def initialize(stdio_fd, komodo_sock, streamType, redirectState, debugger__)
    @stdio_fd = stdio_fd
    @komodo_sock = komodo_sock
    @redirectState = redirectState
    @streamType = streamType
    @debugger__ = debugger__
  end

  def dump
    b = binding
    ['@stdio_fd.fileno', '@redirectState', '@streamType'].collect {|name|
      sprintf("%s = [%s]\n", name, eval(name, b))
    }
  end

  def wrap
    saved_guard = @debugger__.debug_guard
    @debugger__.debug_guard = true
    begin
      yield
    rescue
    end
    @debugger__.debug_guard = saved_guard
  end
    

  def flush
####    @@orig_stderr.print(">> flush\n")
    wrap {
      @komodo_sock.flush if @redirectState != DBGP_Redirect_Disable
      @stdio_fd.flush if @redirectState == DBGP_Redirect_Copy
    }
  end

  def close
    wrap {
####    @@orig_stderr.print(">> close\n")
      @komodo_sock.close if @redirectState != DBGP_Redirect_Disable
      @stdio_fd.close if @redirectState == DBGP_Redirect_Copy
    }
  end

  def print(*args)
    wrap {
####    @@orig_stderr.print(">> print(#{args})\n")
      str = args.join($,)
      doOutput(str)
    }
  end

  def printf(*args)
    wrap {
####    @@orig_stderr.print(">> printf(#{args})\n")
      doOutput(sprintf(*args))
    }
  end

  def putc(obj)
    wrap {
      if obj.is_a?(Fixnum)
        doOutput([obj].pack("c"))
      else
        doOutput(obj.to_s[0, 1])
      end
    }
  end

  def puts(*args)
    wrap {
      str = args.collect{|x| x[-1] == ?\n ? x : x + "\n"}.join("")
      doOutput(str)
    }
  end

  attr_accessor :sync  # But do nothing

  def syswrite(str)
    wrap {
####    @@orig_stderr.print(">> syswrite(#{str})\n")
      doOutput(str)
    }
  end

  def write(str)
    wrap {
####    @@orig_stderr.print(">> write(#{str})\n")
      doOutput(str)
    }
  end

  #XXX Hack warning -- copied code
  def printWithLength(str)
    argLen = str.length
    finalStr = sprintf("%d\0%s\0", argLen, str);
    # Ruby doesn't do null-byte truncation
    # even though the method takes only a string arg

    # We can use @out_sock as this module gets included into the debugger class
    begin
####      @@orig_stderr.print("about to write a packet...\n")
      @komodo_sock.syswrite(finalStr)
    rescue => msg
####      @@orig_stderr.print("write failed: #{msg}")
    end
####    @@orig_stderr.print("should have written a packet...\n")
    @@orig_stderr.print(finalStr, "\n") unless finalStr =~ /<stream\s+xmlns.*encoding=\"base64\"/m
  end

  def doOutput(str)
    if (@redirectState != DBGP_Redirect_Disable)
      # Coupling with caller here
      encval = encodeData(str, @default_encoding)
      printWithLength(sprintf(%Q(%s\n<stream %s
				   type="%s"
				   encoding="%s">%s</stream>\n),
				xmlHeader(),
				namespaceAttr(),
				@streamType,
				@default_encoding,
				encval
				))
    end
    if (@redirectState != DBGP_Redirect_Redirect)
      @stdio_fd.print(str)
    end
  end
end
