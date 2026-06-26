#!/usr/bin/ruby
# Copyright (c) 2005-2006 ActiveState Software Inc.
#
# See the LICENSE file for full details on this software's license.
#
# Authors:
#    Eric Promislow <EricP@ActiveState.com>

module Dbgr_Commandline
  
  def splitCommandLine(cmd)
    args = []
    while cmd.length > 0
      if cmd =~ /^\s+(.*)$/ then
        cmd = $1
      elsif cmd[0] == ?' then
        cmd =~ /^\'((?:\\.|[^\'\\]+)*)('?)(.*)$/
        cmd = $3
        args << $1.gsub(/\\(.)/, '\1')
      elsif cmd[0] == ?" then
        cmd =~ /^\"((?:\\.|[^\"\\]+)*)("?)(.*)$/
        cmd = $3
        args << $1.gsub(/\\(.)/, '\1')
      elsif cmd =~ /^['"]/ then
        cmd =~ /^(.)((?:\\.|[^\1\\]+)*)(\1?)(.*)$/
        cmd = $3
        args << $1.gsub(/\\(.)/, '\1')
      elsif cmd =~ /^([^'"\s]+)\s*(.*)$/ then
        cmd = $2
        args << $1.gsub(/\\(.)/, '\1')
      else
        raise "Can't deal with string <<#{cmd}>>"
      end
    end
    return args
  end

  def getArg(args, option, opts={})
    (0 .. args.size - 1).each {|i|
      if args[i] == option
        return opts['keep'] ? args[i + 1] : args.slice!(i, 2)[1]
      end
    }
    return opts['default'] if opts.has_key?('default')
    raise "Can't find option #{option} in #{args.join(" ")}"
  end

  def getDataArgs(args)
    return "" if args.size == 0
    args.shift() if args[0] == '--'
    return args.join("")
  end

  # Experimental
  # Template consists of a <letter>+?:
  # If there's a "+", convert the value to a number
  def pickArgs(args, template)
    retvals = []
    template.split(/:/).each {|typ|
      let, isplus = "-" + typ[0, 1], typ[1] == ?+
      val = getArg(args, let, 'default' => nil)
      val = val.to_i if isplus
      retvals << val
    }
    return retvals
  end

    
    
end

if __FILE__ == $0
  include Dbgr_Commandline
  strings = [
    %q(-a straight -b forward moose),
    # Put in 4 bs's to get the string parser to see 2
    %q(-a 'sq stu \'\" \\\\ x@$#' -b 'onk'),
    %q(-a "sq stu \'\" \\\\ x@$#" -b 'onk' -c em\\\\b##\\#ded),
  ]
  expected = [
   %w(-a straight -b forward moose),
    ['-a', 'sq stu \'" \\ x@$#', '-b', 'onk'],
    ['-a', 'sq stu \'" \\ x@$#', '-b', 'onk', '-c', 'em\\b###ded']
  ]
  (0 .. strings.size - 1).each {|i|
    args = splitCommandLine(strings[i])
    if args != expected[i]
      print "Expected     <#{expected[i].join("><")}>,\n\t got <#{args.join("><")}>\n\t from #{strings[i]}\n";
    end
  }
  string = %q(-i 38 -c breakpoint_set -f foo.rb -l 10 -s enabled)
  args = splitCommandLine(string)
  vals = {'i' => '38',
    'c' => 'breakpoint_set',
    'f' => 'foo.rb',
    'l' => '10',
    's' => 'enabled'
  }
  argSize = args.size
  if argSize != 2 * vals.size
    print "Expected #{2 * vals.size} args, got #{argSize}\n";
  end
  vals.each {|key, val|
    lookup = getArg(args, "-" + key, 'keep' => 1)
    if lookup != val
      print "Expected -#{key} => <#{val}>, got <#{lookup}>\n";
    end
  }
  val = 'xyz'
  lookup = getArg(args, "-b", 'default' => val)
  if lookup != val
    print "Expected -#{key} => <#{val}>, got <#{lookup}>\n";
  end
  # Test destroying the values
  vals.each {|key, val|
    lookup = getArg(args, "-" + key)
    if lookup != val
      print "Expected -#{key} => <#{val}>, got <#{lookup}>\n";
    end
    argSize -= 2
    if args.size != argSize
      print "Expected to now have #{argSize} args, but have #{args.size}\n"
    end
  }
  # Test destroying the values
  vals.each {|key, val|
    lookup = getArg(args, "-" + key, 'default' => vals[key])
    if lookup != val
      print "Expected -#{key} => <#{val}>, got <#{lookup}>\n";
    end
  }
  begin
    lookup = getArg(args, "-i")
    print "Failed: expected to throw arg not found\n"
  end

  # Test pickArgs
  cmdArgs = '-f dbgp://ruby/eval/1'
  beginLine, endLine, fileURI = pickArgs(splitCommandLine(cmdArgs), 'b+:e+:f:')
  print "Failed: #{__LINE__}\n" unless (beginLine == 0)
  print "Failed: #{__LINE__}\n" unless (endLine == 0)
  print "Failed: #{__LINE__}\n" unless (fileURI == 'dbgp://ruby/eval/1')
end

 
