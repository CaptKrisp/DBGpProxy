#!/usr/bin/ruby
# Copyright (c) 2005-2006 ActiveState Software Inc.
#
# See the LICENSE file for full details on this software's license.
#
# Authors:
#    Eric Promislow <EricP@ActiveState.com>

# Class for encapsulating reading commands from the debugger client

require 'thread'    # for the queue
require 'monitor'   # for the condition variable

#XXX Wrap @is_breaking in a monitor to guarantee single-threaded access.

class Dbgr_Session

  def initialize(sock_, dbgr)
    @sock = sock_
    @queue = Queue.new
    @is_breaking = false
    @dbgr = dbgr

    @producer = Thread.new(@sock) do |sock|
      Thread.stop  # Set it up
      # Sometimes we read more than one cmd at a time
      # We always append to the last string in @pending, and always put
      # a possibly null string at the end to avoid the boundary condition
      # of finding one complete command
      amtToRead = 2048
      finalBuffer = ""
      while true
        begin
          thisBuffer = sock.sysread(amtToRead)



        rescue EOFError
          thisBuffer = ""
          break
        end
        leave = thisBuffer.length == 0
        finalBuffer += thisBuffer.delete("\r\n")
        parts = finalBuffer.split(0.chr, -1)
        finalBuffer = parts.pop  # Usually empty

        # Some things don't go on the queue,
        # so we'll look for them and do appropriate action
        
        new_parts = parts.delete_if { |p| p.index("STOP") == 0 }
        leave ||= (new_parts.size < parts.size)




        ib = new_parts.find { |p| p.index("break ") == 0 }
        if ib && !@is_breaking
          @is_breaking = true
        end
        if @is_breaking



        end

        leave ||= new_parts.find { |p| p.index("stop ") == 0 }
        



        new_parts.each { |p| @queue.enq(p) }
        if leave



          # sock.close_read()
          break
        end
      end



    end # end thread




    # Register this thread with the debugger so it ignores it
    # in the trace_func
    @dbgr.worker_threads[@producer] = 1
    @producer.run
  end

  def get_command
    return @queue.deq
  end

  def end_session
    thr = @producer.join(0.01)
    if !thr
      @producer.exit()
    end
    @dbgr.worker_threads.delete(@producer)
  end

  def is_breaking?
    if @is_breaking
      @is_breaking = false
      return true
    end
  end

  def break_off!
    @is_breaking = false
  end
end
