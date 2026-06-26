#!/usr/bin/ruby
# Copyright (c) 2005-2006 ActiveState Software Inc.
#
# See the LICENSE file for full details on this software's license.
#
# Authors:
#    Eric Promislow <EricP@ActiveState.com>

# Keep all the breakpoint-related functions here.

class DBGP_Breakpoints

  require 'cgi'
  require 'DB/constants'
  include DBGR_Constants

  attr_reader :bkptLookupTable
  attr_reader :state_type_names

  class BreakpointHitInfo
      @@hitConditions = {
        # hit_count is the varying value the debugger maintains
        # hit_value is the thing the user specifies, stating when to break
        
        '>=' => Proc.new {|hit_count, hit_value| hit_count >= hit_value },
        '==' => Proc.new {|hit_count, hit_value| hit_count == hit_value },
        '%'  => Proc.new {|hit_count, hit_value| hit_count % hit_value == 0 },
    }
    require 'DB/DbgrCommon'
    include Dbgr_Common

    def stringToProc(bkptHitConditionString)
      # $stderr.printf("%s: %d\n", __FILE__, __LINE__)
      bkptHitConditionString ||= ">="
      bkptHitConditionProc = @@hitConditions[bkptHitConditionString]
      if bkptHitConditionProc.nil?
        raise "Unknown breakpoint test [#{bkptHitConditionString}]"
      end
      return [bkptHitConditionString, bkptHitConditionProc]
    end
    private :stringToProc
    
    def initialize(bHitValue, bkptHitConditionString)
      # $stderr.printf("%s: %d\n", __FILE__, __LINE__)
      if bHitValue.nil?
        @hit_count = 0
        @hit_value = 0
        @eval_func = nil
        @cond_string = ""
      else
        bkptHitConditionString, bkptHitConditionProc = stringToProc(bkptHitConditionString)
        @hit_count = 0
        @hit_value = bHitValue
        @eval_func = bkptHitConditionProc
        @cond_string = bkptHitConditionString
      end
    end

    def update(bHitValue, bkptHitConditionString)
      # $stderr.printf("%s: %d\n", __FILE__, __LINE__)
      @hit_count = 0   # Is this what we always want to do -- restart?
      if bkptHitConditionString
        bkptHitConditionString, bkptHitConditionProc = stringToProc(bkptHitConditionString)
        @eval_func = bkptHitConditionProc
        @cond_string = bkptHitConditionString
      end
      if bHitValue && bHitValue > 0
        @hit_value = bHitValue
      end
    end

    def inc_and_test
      @hit_count += 1
      if @eval_func
        res = @eval_func.call(@hit_count, @hit_value)
      else
        return true
      end
      return res
    end

    def add_attributes(lvs)
      if @hit_value
      lvs['hit_count'] = @hit_count
      lvs['hit_value'] = @hit_value
        lvs['hit_condition'] = xmlAttrEncode(@cond_string) if @cond_string
      end
    end

    def clear
      @hit_count = @hit_value = 0
      @eval_func = null
    end

  end # end class

  class BreakpointInfo
    # Info on a breakpoint -- used to be an array, but this is better
    attr_accessor :bFileURINo, :bLine, :bState, :bType
    attr_accessor :bFunctionName, :bExpression, :bException, :bHitInfo
    include DBGR_Constants
    include Dbgr_Common
    def initialize(bFileURINo, bLine, bState, bType, bFunctionName, bExpression, bException)
      @bFileURINo = bFileURINo
      @bLine = bLine
      @bState = bState
      @bType = bType
      @bFunctionName = bFunctionName
      @bExpression = bExpression
      @bException = bException
      @bHitInfo = nil
    end

    def getBreakpointInfoString(bkptID, parent, extraInfo)
      res = sprintf(%Q(<breakpoint id="%d" type="%s"),
                    bkptID,
                    @bType
                    )
      lvs = {}
      # Find a clean way fot this class to get the fileURI
      if ((bFileURINo = (extraInfo['fileURI'] || @bFileURINo)) &&
            (fileURI = parent.get_URI(bFileURINo)))
        lvs['filename'] = fileURI
      end

      lvs['lineno'] = extraInfo['lineNo'] || @bLine
      if !(val = extraInfo['function'] || @bFunction).nil?
        lvs['function'] = val
      end
      lvs['state'] = parent.state_type_names[@bState]
      lvs['temporary'] = @bState == BKPT_TEMPORARY ? 1 : 0
      lvs['exception'] = @bException if !@bException.nil?
      @bHitInfo.add_attributes(lvs) if @bHitInfo
      lvs.each {|key, value| res += %Q{ #{key}="#{value}"}}
      if @bExpression.nil?
        res += "/>"
      else
        res += sprintf(">%s</breakpoint>", cdata(encodeData(@bExpression, parent.getCurrentEncoding())))
      end
      res
    end
    
  end # end nested class

  # Main class starts here

  def initialize(debugger__, ftable, initial_dir=Dir.getwd)
    @initial_dir = initial_dir
    $IS_WIN32 = RUBY_PLATFORM =~ /mswin32/ || RUBY_PLATFORM =~ /cygwin/

    # Class data structures

    @bkptLookupTable = []               #   uri# => hash of [line# => bkpt#]
    @bkptInfoTable = []                 #  bkpt# => [array of bk info]
    @nextBkPtIndex = 0                  # index into bkptLookupTable

    @FQFnNameLookupTable = {}           # map fully qualified fn names => 
		                        # { call => bkptID, return => bkptID }
    @state_types = {
      'enabled' => BKPT_ENABLE,
      'disabled' => BKPT_DISABLE,
    }
    @state_type_names = []
    @state_type_names[BKPT_DISABLE] = 'disabled'
    @state_type_names[BKPT_ENABLE] = 'enabled'
    @state_type_names[BKPT_TEMPORARY] = 'enabled' # Not temporary according to dbgp

    @debugger__ = debugger__
    @ftable = ftable  # The filetable handler
  end

  def dblog(*args)
    @debugger__.dblog(*args)
  end

  def settings(_settings)
    @settings = _settings
  end

  def state_name_to_type(bState, bIsTemporary=0)
    return bIsTemporary == 1 ? BKPT_TEMPORARY : @state_types[bState]
  end

  def break_test_on_bkptID(bkptID, binding)
    bkptInfo = @bkptInfoTable[bkptID]
    if ! bkptInfo
      return false
    end
    # Check conditions here
    # Temporary applies only after everything else is checked.
    case bkptInfo.bState
    when BKPT_DISABLE
      return false
    when BKPT_TEMPORARY
      bkptInfo.bState = BKPT_DISABLE
    end

    # Check hit-counts, etc., here
    # Check hit-counts before checking expressions, as they're
    # cheaper, and we should always count a hit
    if (bhi = bkptInfo.bHitInfo) && !bhi.inc_and_test
      dblog("break_test_on_bkptID ... failed on conditional breakpoint")
      return false
    end

    # Finally evaluate an expression
    if (bExpression = bkptInfo.bExpression)
      begin
        res = eval(bExpression, binding)
        if !res
          dblog("break_test_on_bkptID ... failed on condition %s", bExpression)
          return false
        end
      rescue => msg
        dblog("break_test_on_bkptID ... threw exception %s", msg)
        # Doesn't make sense to break here
        return false
      end
    end
    
    return true
  end

  def break_at_function_call(direction, function_name, klass, binding)
    fqName = klass == Object ? function_name : klass.to_s + "#" + function_name
    begin
      bkptID = FQFnNameLookupTable[fqName][direction]
      return break_test_on_bkptID(bkptID, binding)
    end
  end
  
  def can_break_here(file_URI_No, lineNo, binding=nil)



    if @bkptLookupTable[file_URI_No].nil?
      return
    end
    bplist = @bkptLookupTable[file_URI_No]
    bkptID = bplist[lineNo]
    if ! bkptID
      return
    end
    begin
      return break_test_on_bkptID(bkptID, binding)
    rescue NoMethodError
      # Do nothing
    rescue => msg



    end
    return false
  end

  def getAllBreakpointInfoStrings
    bkpt_list = (0 .. @nextBkPtIndex - 1).collect {|bkptID|
      getBreakpointInfoString(bkptID)
    }.delete_if {|x| x.nil?}
    return bkpt_list
  end

  def getBreakpointInfoString(bkptID, extraInfo={})
    bkptInfo = @bkptInfoTable[bkptID]
    if bkptInfo.nil?



      return nil
    end
    # self gives access to functions in this class
    return bkptInfo.getBreakpointInfoString(bkptID, self, extraInfo)
  end

  def getCurrentEncoding
    return @settings['data_encoding'][0]
  end

  def get_URI(bFileURINo)
    @ftable.get_URI(bFileURINo)
  end

  def newBkptInfo
    { :hit_count => 0,
      :hit_value => 0,
      :eval_func => nil,
      :cond_string => nil
    }
  end

  def setBkPtHitInfo(bkptID, bHitValue, bHitConditionOperator)
    if (bkptInfo = @bkptInfoTable[bkptID]).nil?
      return [DBP_E_NoSuchBreakpoint, "Unknown breakpoint ID #{bkptID}."]
    end
    begin
      bHitValue2 = bHitValue.to_i
    rescue
      return
    end
    if bHitValue2 > 0
      begin
        if bkptInfo.bHitInfo.nil?
          bkptInfo.bHitInfo = BreakpointHitInfo.new(bHitValue2, bHitConditionOperator)
        else
          bkptInfo.bHitInfo.update(bHitValue2, bHitConditionOperator)
        end
      rescue => msg
        return [DBP_E_NoSuchBreakpoint, msg]
      end
    end # end if
    return # nil
  end

  def setNullBkPtHitInfo(bkptID)
    if (bkptInfo = @bkptInfoTable[bkptID])
      if (bhi = bkptInfo.bHitInfo)
        bhi.clear
      end
    end
  end
      

  def remove(bkptID)
    if (bkptInfo = @bkptInfoTable[bkptID]).nil?
      return [DBP_E_NoSuchBreakpoint, "Unknown breakpoint ID #{bkptID}."]
    end
    bFileURINo = bkptInfo.bFileURINo
    if bkptInfo.bType == 'watch'
      return DBP_E_InvalidOption, "Not yet handling watchpoint expressions"
    elsif bFileURINo.nil?
      return DBP_E_NoSuchBreakpoint, "Unknown breakpoint ID #{bkptID}."
    elsif !@ftable.has_URI(bFileURINo)
      return DBP_E_NoSuchBreakpoint, "Unknown fileURI No. #{bFileURINo} for breakpoint ID #{bkptID}."
    end
    @bkptInfoTable[bkptID] = nil

    # And remove the entry from the file URL table

    if (activeLines = @bkptLookupTable[bFileURINo]).nil?



    else
      activeLines.delete_if { |k, v| v == bkptID }
    end
    return nil
  end

  def update(bkptID, bStateVal)
    if (bkptInfo = @bkptInfoTable[bkptID]).nil?
      return [DBP_E_NoSuchBreakpoint, "Unknown breakpoint ID #{bkptID}."]
    end
    bkptInfo.bState = bStateVal
    return nil
  end

  #XXX Move to a common routine
  def encode(str)
    return encode_data(str, @settings['data_encoding'][0])
  end

  def internFileURINo_LineNo(bFileURINo, bLine)
    if @bkptLookupTable[bFileURINo].nil?
      bkptID = getNextBreakpointID()
      @bkptLookupTable[bFileURINo] = {bLine => bkptID}
      return bkptID
    elsif ! @bkptLookupTable[bFileURINo].has_key?(bLine)
      @bkptLookupTable[bFileURINo][bLine] = getNextBreakpointID()
    end
    return @bkptLookupTable[bFileURINo][bLine]
  end
  
  def storeBkPtInfo(bkptID, bFileURINo, bLine, bstate, bType,
                    bFunctionName=nil, bCondition=nil, bException=nil)
    @bkptInfoTable[bkptID] = BreakpointInfo.new(bFileURINo, bLine, bstate, bType, bFunctionName, bCondition, bException)
  end
  
  def lookupBkptInfo(fileNameURINo, lineNo)
    begin
      bkptID = @bkptLookupTable[fileNameURINo][lineNo]



      return @bkptInfoTable[bkptID]
    end
  end

  def getNextBreakpointID()
    # Simulate return x++
    @nextBkPtIndex += 1
    return @nextBkPtIndex - 1
  end

end #end class










































































































































