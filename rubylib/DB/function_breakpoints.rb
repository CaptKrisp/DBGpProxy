#!/usr/bin/ruby
# Copyright (c) 2005-2006 ActiveState Software Inc.
#
# See the LICENSE file for full details on this software's license.#
#
# Authors:
#    Eric Promislow <EricP@ActiveState.com>

module DBGR_FunctionBreakpoints

  # This class does the lookup on qualified function names
  #
  # Unqualified functions match *.fn -- a breakpoint on
  # function 'fn' matches any access involving function fn
  #
  # A breakpoint on <class.fn> or <class#fn>, matches
  # all accesses on a function fn in a class that matches (.*\::)*<class>
  # to allow for qualified classes

  class FullyQualifiedFunctionNameLookupTable
    def initialize()
      # The table is a hash of hashes:
      # First hash on the class name,
      # then on the suffix
      # The idea is that specifying no suffix will match all forms,
      # but specifying a suffix will match only the suffix
      @table = {}
    end

    def FullyQualifiedFunctionNameLookupTable.SetBkptObj(bpts)
      @@bpts = bpts
    end

    # { function name =>
    #   { class_name =>
    #     { suffix => [call bkptID, return bkptID ]  }
    #   }
    # }
    def intern_function_name(functionPart, suffixPart, classPart, callType)
      if !@table.has_key?(classPart)
        @table[classPart] = {}
      end
      fc_hash = @table[classPart]
      if !fc_hash.has_key?(suffixPart)
        fc_hash[suffixPart] = [nil, nil]
      end
      fc_hash_list = fc_hash[suffixPart]
      if fc_hash_list[callType].nil?
        fc_hash_list[callType] = @@bpts.getNextBreakpointID()
      end
      bkptID = fc_hash_list[callType]
      return bkptID
    end
        

    # Work from most specific to least
    def has_break_at_function_call(callType, functionName, suffixPart, classPart)
      classEntry = nil
      origClassPart = classPart
      classPart = "fake::" + classPart  # Prime the boundary condition
      while true
        while true
          if classPart =~ /^.*?::(.+)$/
            classPart = $1
          elsif classPart.length == 0
            return false
          else
            classPart = ""
          end
          classEntry = @table[classPart]
          break if classEntry
        end
        if classEntry.nil?



          return false
        end
        
        # Choose <specific class><any suffix> over <general class><specific suffix>
        sfx1 = classEntry[suffixPart]
        if sfx1 and (bkptId = sfx1[callType])
            return bkptId
        end
        if suffixPart.length > 0 and (sfx1 = classEntry[""]) and (bkptId = sfx1[callType])
            return bkptId
        end        
        # Try with a less specific class
      end # outer while
    end
    
    def break_at_function_call(callType, functionName, suffixPart, classPart, binding)



      if (bkptID = has_break_at_function_call(callType, functionName, suffixPart, classPart))
        return @@bpts.break_test_on_bkptID(bkptID, binding)
      end
    end
    
    private :has_break_at_function_call
  end



  # This class implements the optimization that it's faster to rule out
  # breaking in a function if we don't have to convert the function's
  # host class from a symbol to a string, and then parse the string's
  # qualifier bits.
  #
  # So the real work is actually done in the
  # FullyQualifiedFunctionNameLookupTable class.
  #
  class FunctionBreakpoints

    def initialize(bpts)
      @fnNameLookupTable = {}
      @bpts = bpts
      # Track whether we have anything at all on call/returns
      @have_breakpoints = false  
      FullyQualifiedFunctionNameLookupTable.SetBkptObj(@bpts)
    end
    
    def intern_function_name(functionPart, suffixPart, classPart, callType)
      @have_breakpoints = true
      if !@fnNameLookupTable.has_key?(functionPart)
        @fnNameLookupTable[functionPart] = FullyQualifiedFunctionNameLookupTable.new()
      end
      bkptID = @fnNameLookupTable[functionPart].intern_function_name(functionPart, suffixPart, classPart, callType)



      return bkptID
    end

    def FunctionBreakpoints.get_function_parts(functionName)
      if functionName =~ /^(.*)([\?\!=])$/
        return [$1, $2]
      else
        return [functionName, ""]
      end
    end

    def break_at_function_call(callType, functionName, klass, binding)
      return false unless @have_breakpoints
      functionPart, suffixPart = FunctionBreakpoints.get_function_parts(functionName)
      if (fqLookupTable = @fnNameLookupTable[functionPart]).nil?
        




        return false
      end
      klass = klass.to_s
      res = fqLookupTable.break_at_function_call(callType, functionPart, suffixPart, klass, binding)



      return res
    end
  end # end class


end # end module




















































































































































