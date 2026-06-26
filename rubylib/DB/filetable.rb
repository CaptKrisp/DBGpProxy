#!/usr/bin/ruby
# Copyright (c) 2005-2006 ActiveState Software Inc.
#
# See the LICENSE file for full details on this software's license.
#
# Authors:
#    Eric Promislow <EricP@ActiveState.com>

# This class handles mapping between
# local filenames, file URIs, and file numbers

module FileTable

require 'DB/constants'     #buncha global constants
include DBGR_Constants

require 'DB/commandline'   #command-line handling module
include Dbgr_Commandline






require 'DB/DbgrCommon'




include Dbgr_Common

EvalString = '(eval)'
EvalStringEntry = 0

class FileNameInfo
  attr_accessor :local_name, :abspath, :uri, :file_URI_for_display
  def initialize(local_name, abspath, uri, file_URI_for_display)
    @local_name = local_name
    @abspath = abspath
    @uri = uri
    @file_URI_for_display = file_URI_for_display
  end

  def items
    return [@uri, @local_name, @abspath]
  end
end
  

# Best used as a singleton class

class FileNameTable
  
  require 'cgi'

  def initialize
    # Basic values
    @IS_WIN32 = RUBY_PLATFORM =~ /mswin32/ || RUBY_PLATFORM =~ /cygwin/

    @uri_to_int = {}            # Map URIs to int
    @filename_URIs = {}         # Map canonical filenames to URIs
    @fileNameTable = []         # uri# => [uri, fullpath, rubypath]

    # Initialize the tables
    @uri_to_int[EvalString] = EvalStringEntry
    @fileNameTable[EvalStringEntry] = FileNameInfo.new(EvalString, EvalString, EvalString, EvalString)

    # Memoizers
    @rel_filename_to_num = {EvalString => EvalStringEntry}
    @raw_uri_to_num = {}
    @canonical_filenames = {EvalString => EvalString}
    @canonical_uris = {EvalString => EvalString}

    @initial_dir = Dir.getwd
  end


  def get_filename(file_URI_no)
    entry = get_ftable_entry(file_URI_no)
    return entry.local_name
  end


  # local_filename -- the name Ruby uses to identify a file
  # actual_filename -- its actual local or UNC path

  def getFileInfo(proposed_file_URI, file_URI_No)
    if proposed_file_URI
      bFileURINo = intern_uri(proposed_file_URI)
    else
      bFileURINo = file_URI_No
    end
    bFileURI, local_filename, actual_filename = @fileNameTable[bFileURINo].items
    return [bFileURI, bFileURINo, actual_filename, local_filename]
  end


  def get_URI(file_URI_no)
    # When this routine is called, the info it returns
    # is always for display purposes, so we don't want
    # to fold case
    entry = get_ftable_entry(file_URI_no)
    return entry.file_URI_for_display
  end

  def get_ftable_entry_items(file_URI_no)
    entry = get_ftable_entry(file_URI_no)
    return entry.items
  end

  def has_URI(file_URI_no)
    begin
      entry = get_ftable_entry(file_URI_no)
      return entry.uri.length > 0
    rescue
      return false
    end
  end


  def get_ftable_entry(file_URI_no)
    if file_URI_no < 0 || file_URI_no >= @fileNameTable.length
      raise "Invalid file # of #{file_URI_no}"
    end
    entry = @fileNameTable[file_URI_no]
    if entry.nil?
        raise "File # of #{file_URI_no} is null"
    end
    return entry
  end
  private :get_ftable_entry


  # Map local filename => URI #
  def intern_file(local_filename)
    @rel_filename_to_num.has_key?(local_filename) and return @rel_filename_to_num[local_filename]
    canonical_absfile = canonicalizeFName(local_filename)
    tmp_URI = filenameToURI(canonical_absfile)
    file_URI = canonicalizeURI(tmp_URI)
    file_URI_for_display = canonicalizeURI(tmp_URI, false)
    if @uri_to_int.has_key?(file_URI)
      res = @uri_to_int[file_URI]
      # Now is the perfect time to set the local name -- default is fullname
      @fileNameTable[res].local_name = local_filename
    else
      res = @fileNameTable.size
      @uri_to_int[file_URI] = res
      @fileNameTable[res] = FileNameInfo.new(local_filename,
                                             canonical_absfile, file_URI,
                                             file_URI_for_display)
    end
    return @rel_filename_to_num[local_filename] = res
  end


  # Map URI (coming from IDE) => URI #
  def intern_uri(raw_file_uri)
    @raw_uri_to_num.has_key?(raw_file_uri) and return @raw_uri_to_num[raw_file_uri]
    file_URI = canonicalizeURI(raw_file_uri)
    file_URI_for_display = canonicalizeURI(raw_file_uri, false)
    filename = uriToFilename(file_URI)
    if @uri_to_int.has_key?(file_URI)
      res = @uri_to_int[file_URI]
    else
      res = @fileNameTable.size
      @uri_to_int[file_URI] = res
      @fileNameTable[res] = FileNameInfo.new(filename, filename, file_URI,
                                             file_URI_for_display)
    end
    return @raw_uri_to_num[raw_file_uri] = res
  end

  def uriToFilename(file_uri)
    # Assume all file:// URIs are local
    if file_uri =~ %r{^file:///(\w:.*)}
      return uri_decode($1)
    elsif file_uri =~ %r{^file://(.*)}
      return uri_decode($1)
    end
  end

  ################ Helpers

  def canonicalizeFName(fname)
    return @canonical_filenames[fname] if @canonical_filenames.has_key?(fname)
    res = canonicalizeFName_aux(fname)
    @canonical_filenames[fname] = res if res
    return res
  end
    

  def canonicalizeFName_aux(fname)
    # Breaks on UNC paths
    if !@IS_WIN32
      return File.expand_path(fname, @initial_dir)
    else
      fname2 = fname.gsub('\\', '/')
      if fname2 =~ %r{^//}
        # don't change unc paths due to bug in ruby
        # don't change windows paths that start with a slash either
        # meaning we don't get folding of internal ".." pockets,
        # but they shouldn't be in the URL anyway
        fname3 = fname2
      elsif RUBY_PLATFORM =~ /mswin32/ && fname2[0] == ?/ #/bug 40952
        fname3 = fname2
      else
        fname3 = File.expand_path(fname2, @initial_dir)
      end
      # On Windows map everything to one case, and
      # map letters to lower-case
      return fname3.downcase
    end
  end
  private :canonicalizeFName_aux


  def canonicalizeURI(bFileURI, downCase=true)
    key = "#{bFileURI}:#{downCase ? 1 : 0}"
    return @canonical_uris[key] if @canonical_uris.has_key?(key)
    res = canonicalizeURI_aux(bFileURI, downCase)
    @canonical_uris[key] = res if res
    return res
  end


  def canonicalizeURI_aux(bFileURI, downCase)
    bFileURI_2 = bFileURI.gsub(' ', '%20')
    if @IS_WIN32 && downCase
      return bFileURI_2.downcase
    else
      return bFileURI_2
    end
  end


  def filenameToURI(canonical_absfile)
    return @filename_URIs[canonical_absfile] if @filename_URIs.has_key?(canonical_absfile)
    res = filenameToURI_aux(canonical_absfile)
    @filename_URIs[canonical_absfile] = res if res
    return res
  end
  

  def filenameToURI_aux(bFileName)
    bFileName = canonicalizeFName(bFileName)
    raise "#{bFileName} not canonical" if @IS_WIN32 && bFileName =~ /\\/



    start = "filenameToURI(#{bFileName}) => " if $ldebug
    if @IS_WIN32
      if bFileName =~ %r{^\w:}
        # Ruby seems to always use forward slashes
        # drive-letter -- colon -- path
        bFileName = encode_win_file_parts(bFileName)
        leadingSlashes = "///"
      elsif bFileName =~ %r{^//}
        # It's a UNC path
        # Remove extra "." and "x\\.." components
        #XXX As of 1.8, Ruby's File.expand_path method is broken on UNCs
        # So we have to do it by hand
        bFileName = "/" + encode_unix_file_parts(bFileName[1 .. -1])
        leadingSlashes = ""
      else
        bFileName = encode_win_file_parts(bFileName)
        slNum = ?/ #/
        leadingSlashes = bFileName[0] == slNum ? "//" : "///"
      end
    else
      # Unix pathnames go through the mount table,
      # so we never have a hostname here
      bFileName = encode_unix_file_parts(bFileName)
      leadingSlashes = "//"
    end
    canon_URI = "file:#{leadingSlashes}#{bFileName}"
    return canon_URI
  end
  private :filenameToURI_aux

# Like Windows, but this kind of filename has no initial volume

  def encode_unix_file_parts(full_name)
    new_name = File.join(full_name.split(File::SEPARATOR).collect {|x|
                           uri_encode(x)
                         })
    return new_name
  end
  private :encode_unix_file_parts


  #Precondition: backslashes have been flipped
  def encode_win_file_parts(full_win_name)
    if full_win_name =~ %r(^\w:#{File::SEPARATOR})
      volume, path = full_win_name.split(File::SEPARATOR, 2)
    else
      path = full_win_name
    end
    dir_parts = path.split(File::SEPARATOR).collect {|x| uri_encode(x) }
    new_name = File.join(dir_parts)
    new_name = "#{volume}#{File::SEPARATOR}#{new_name}" if !volume.nil? 
    return new_name
  end
  private :encode_win_file_parts

  def uri_decode(todecode)
    CGI.unescape(todecode)
  end
  private :uri_decode

  def uri_encode(toencode)
    CGI.escape(toencode).gsub(/\+/, '%20')
    # Note on '/\+/' -- used to be '+', but versions < 1.8.2
    # have trouble with regexp metacharacters in strings.
  end
  private :uri_encode

end

end # end Module



































































































































