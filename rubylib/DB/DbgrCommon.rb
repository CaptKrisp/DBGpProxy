#!/usr/bin/ruby
# Copyright (c) 2005-2006 ActiveState Software Inc.
#
# See the LICENSE file for full details on this software's license.
# 
# Authors:
#    Eric Promislow <EricP@ActiveState.com>

module Dbgr_Common

# A buncha globals and functions to do common stuff

  @_common_types = {
    "NilClass" => 'null',
    "FixNum" => 'int',
    "Integer" => 'int',
    "Float" => 'float',
    "Bignum" => 'float',
    "String" => 'string',
  }
    

  def _fmt_time
    return Time.new.localtime().to_s.sub(%r{(\w+) (Standard|Daylight) Time}) {
      $1[0,1] + $2[0,1] + "T"
    }
  end

  def namespaceAttr()
    return 'xmlns="urn:debugger_protocol_v1"'
  end

  def xsdNamespace
    return %q(xmlns:xsd="http://www.w3.org/2001/XMLSchema")
  end
  
  def xsiNamespace
    return %q(xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance")
  end

  def setDefaultOutput(out)
    $OUT = out
  end

  def decodeData(str, currDataEncoding)
    case currDataEncoding
    when 'none', 'binary'
      finalStr = str
    when 'urlescape'
      require 'cgi'
      finalStr = CGI.unescape(outLogName);
    when 'base64'
      finalStr = str.unpack("m")[0]
    else
      dblog("Converting #{str} with unknown encoding of #{currDataEncoding}\n")
      finalStr = str;
    end
    return finalStr
  end

  def cdata(str)
    "<![CDATA[" + str + "]]>"
  end

  def encodeData(str, currDataEncoding)
    begin
      case currDataEncoding
      when 'none', 'binary'
        finalStr = str
      when 'urlescape'
        require 'cgi'
        finalStr = CGI.escape(outLogName);
      when 'base64'
        finalStr = [str].pack("m")
      else
        dblog("Converting #{str} with unknown encoding of #{currDataEncoding}\n")
        finalStr = str;
      end
    end
  end

  def endPropertyTag(encVal, encoding)
    return ((!encVal.nil? && encVal.length > 0) ?
            "><![CDATA[#{encVal}]]></property>\n" :
              "/>\n")
  end

  def getCommonType(val)
    if @_common_types.has_key?(val)
      return @_common_types[val]
    else
      return 'object'
    end
  end

  # This is too easy...
  
  def isFloat(val)
    val.is_a?(Float)
  end

  def isWin32()
    RUBY_PLATFORM =~ /mswin32/ || RUBY_PLATFORM =~ /cygwin/
  end

  def makeErrorResponse(cmd, transactionID, code, error)
    printWithLength(sprintf(%Q(%s\n<response %s command="%s" 
			transaction_id="%s" ><error code="%d" apperr="4">
			<message>%s</message>
			</error></response>),
                            xmlHeader(),
                            namespaceAttr(),
                            cmd,
                            transactionID,
                            code,
                            xmlEncode(error)));
  end
  
  def printWithLength(str)
    argLen = str.length
    finalStr = sprintf("%d\0%s\0", argLen, str);
    # Ruby doesn't do null-byte truncation
    # even though the method takes only a string arg

    # We can use @out_sock as this module gets included into the debugger class
    begin
      @out_sock.syswrite(finalStr)
    rescue SystemCallError
    rescue IOError
    end



  end

  def _trimExceptionInfo(msg="")
    msg.to_s.sub(/ for \#<<DEBUGGER__::Context:0x\d+>\s*$/, '')
  end
  
  def xmlAttrEncode(str)
    return xmlEncode(str).gsub(/([\'\"])/) { '&#' + $1[0].to_s + ';' }
  end    
    
  def safe_dump(str)
    str.gsub(%r{([^\x09\x0a\0x0d\x20-\x7f])}){sprintf('\\x%02x', $1[0])}
  end

  def xmlEncode(str)
    # No need to escape quotes.
    return str.
      gsub('&', '&amp;').
      gsub('<', '&lt;').
      gsub('>', '&gt;').
      gsub(/([\x00-\x08\x0b\x0c\x0e-\x1f])/){"&#" + $1[0].to_s + ";"}
  end

  def cdataEncode(str)
    # No need to escape quotes.
    return str.gsub(/\]\]>/, "]]&gt;")
  end

  def xmlHeader(encoding='utf-8')
    %Q(<?xml version="1.0" encoding="#{encoding}" ?>);
  end

end # module
