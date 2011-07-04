require 'linguist/language'
require 'linguist/mime'
require 'linguist/pathname'

require 'escape_utils'
require 'yaml'

module Linguist
  # BlobHelper is a mixin for Blobish classes that respond to "name",
  # "data" and "size" such as Grit::Blob.
  module BlobHelper
    # Internal: Get a Pathname wrapper for Blob#name
    #
    # Returns a Pathname.
    def pathname
      Pathname.new(name || "")
    end

    # Public: Get the extname of the path
    #
    # Examples
    #
    #   blob(name='foo.rb').extname
    #   # => '.rb'
    #
    # Returns a String
    def extname
      pathname.extname
    end

    # Public: Get the actual blob mime type
    #
    # Examples
    #
    #   # => 'text/plain'
    #   # => 'text/html'
    #
    # Returns a mime type String.
    def mime_type
      @mime_type ||= pathname.mime_type
    end

    # Public: Get the Content-Type header value
    #
    # This value is used when serving raw blobs.
    #
    # Examples
    #
    #   # => 'text/plain; charset=utf-8'
    #   # => 'application/octet-stream'
    #
    # Returns a content type String.
    def content_type
      pathname.content_type
    end

    # Public: Get the Content-Disposition header value
    #
    # This value is used when serving raw blobs.
    #
    #   # => "attachment; filename=file.tar"
    #   # => "inline"
    #
    # Returns a content disposition String.
    def disposition
      if text? || image?
        'inline'
      else
        "attachment; filename=#{EscapeUtils.escape_url(pathname.basename)}"
      end
    end

    # Public: Is the blob binary?
    #
    # Return true or false
    def binary?
      pathname.binary?
    end

    # Public: Is the blob text?
    #
    # Return true or false
    def text?
      !binary?
    end

    # Public: Is the blob a supported image format?
    #
    # Return true or false
    def image?
      ['.png', '.jpg', '.jpeg', '.gif'].include?(extname)
    end

    MEGABYTE = 1024 * 1024

    # Public: Is the blob too big to load?
    #
    # Return true or false
    def large?
      size.to_i > MEGABYTE
    end

    # Public: Is the blob viewable?
    #
    # Non-viewable blobs will just show a "View Raw" link
    #
    # Return true or false
    def viewable?
      text? && !large?
    end

    vendored_paths = YAML.load_file(File.expand_path("../vendor.yml", __FILE__))
    VendoredRegexp = Regexp.new(vendored_paths.join('|'))

    # Public: Is the blob in a vendored directory?
    #
    # Vendored files are ignored by language statistics.
    #
    # See "vendor.yml" for a list of vendored conventions that match
    # this pattern.
    #
    # Return true or false
    def vendored?
      name =~ VendoredRegexp ? true : false
    end

    # Public: Get each line of data
    #
    # Requires Blob#data
    #
    # Returns an Array of lines
    def lines
      @lines ||= (viewable? && data) ? data.split("\n", -1) : []
    end

    # Public: Get number of lines of code
    #
    # Requires Blob#data
    #
    # Returns Integer
    def loc
      lines.size
    end

    # Public: Get number of source lines of code
    #
    # Requires Blob#data
    #
    # Returns Integer
    def sloc
      lines.grep(/\S/).size
    end

    # Internal: Compute average line length.
    #
    # Returns Integer.
    def average_line_length
      if lines.any?
        lines.inject(0) { |n, l| n += l.length } / lines.length
      else
        0
      end
    end

    # Public: Is the blob a generated file?
    #
    # Generated source code is supressed in diffs and is ignored by
    # language statistics.
    #
    # Requires Blob#data
    #
    # Includes:
    # - XCode project XML files
    # - Minified JavaScript
    #
    # Return true or false
    def generated?
      if ['.xib', '.nib', '.pbxproj'].include?(extname)
        true
      elsif generated_coffeescript? || minified_javascript?
        true
      else
        false
      end
    end

    # Internal: Is the blob minified JS?
    #
    # Consider JS minified if the average line length is
    # greater then 100c.
    #
    # Returns true or false.
    def minified_javascript?
      return unless extname == '.js'
      average_line_length > 100
    end

    # Internal: Is the blob JS generated by CoffeeScript?
    #
    # Requires Blob#data
    #
    # CoffeScript is meant to output JS that would be difficult to
    # tell if it was generated or not. Look for a number of patterns
    # outputed by the CS compiler.
    #
    # Return true or false
    def generated_coffeescript?
      return unless extname == '.js'

      if lines[0] == '(function() {' &&     # First line is module closure opening
          lines[-2] == '}).call(this);' &&  # Second to last line closes module closure
          lines[-1] == ''                   # Last line is blank

        score = 0

        lines.each do |line|
          if line =~ /var /
            # Underscored temp vars are likely to be Coffee
            score += 1 * line.gsub(/(_fn|_i|_len|_ref|_results)/).count

            # bind and extend functions are very Coffee specific
            score += 3 * line.gsub(/(__bind|__extends|__hasProp|__indexOf|__slice)/).count
          end
        end

        # Require a score of 3. This is fairly arbitrary. Consider
        # tweaking later.
        score >= 3
      else
        false
      end
    end

    # Public: Should the blob be indexed for searching?
    #
    # Excluded:
    # - Files over 0.1MB
    # - Non-text files
    # - Langauges marked as not searchable
    # - Generated source files
    #
    # Return true or false
    def indexable?
      if binary?
        false
      elsif language.nil?
        false
      elsif !language.searchable?
        false
      elsif generated?
        false
      elsif size > 100 * 1024
        false
      else
        true
      end
    end

    # Public: Detects the Language of the blob.
    #
    # May load Blob#data
    #
    # Returns a Language or nil if none is detected
    def language
      if defined? @language
        @language
      else
        @language = guess_language
      end
    end

    # Internal: Guess language
    #
    # Returns a Language or nil
    def guess_language
      return if binary?

      # If its a header file (.h) try to guess the language
      header_language ||

        # If it's a .r file, try to guess the language
        r_language ||

        # See if there is a Language for the extension
        pathname.language ||

        # Try to detect Language from shebang line
        shebang_language ||

        # Try to detect Language from first line
        first_line_language
    end

    # Internal: Get the lexer of the blob.
    #
    # Returns a Lexer.
    def lexer
      language ? language.lexer : Lexer['Text only']
    end

    # Internal: Guess language of header files (.h).
    #
    # Returns a Language.
    def header_language
      return unless extname == '.h'

      if lines.grep(/^@(interface|property|private|public|end)/).any?
        Language['Objective-C']
      elsif lines.grep(/^class |^\s+(public|protected|private):/).any?
        Language['C++']
      else
        Language['C']
      end
    end

    # Internal: Guess language of .r files.
    #
    # Returns a Language.
    def r_language
      return unless extname == '.r'

      if lines.grep(/(rebol|(:\s+func|make\s+object!|^\s*context)\s*\[)/i).any?
        Language['Rebol']
      else
        Language['R']
      end
    end

    # Internal: Extract the script name from the shebang line
    #
    # Requires Blob#data
    #
    # Examples
    #
    #   '#!/usr/bin/ruby'
    #   # => 'ruby'
    #
    #   '#!/usr/bin/env ruby'
    #   # => 'ruby'
    #
    #   '#!/usr/bash/python2.4'
    #   # => 'python'
    #
    # Returns a script name String or nil
    def shebang_script
      # Fail fast if blob isn't viewable?
      return unless viewable?

      if lines.any? && (match = lines[0].match(/(.+)\n?/)) && (bang = match[0]) =~ /^#!/
        bang.sub!(/^#! /, '#!')
        tokens = bang.split(' ')
        pieces = tokens.first.split('/')
        if pieces.size > 1
          script = pieces.last
        else
          script = pieces.first.sub('#!', '')
        end

        script = script == 'env' ? tokens[1] : script

        # python2.4 => python
        if script =~ /((?:\d+\.?)+)/
          script.sub! $1, ''
        end

        # Check for multiline shebang hacks that exec themselves
        #
        #   #!/bin/sh
        #   exec foo "$0" "$@"
        #
        if script == 'sh' &&
            lines[0...5].any? { |l| l.match(/exec (\w+).+\$0.+\$@/) }
          script = $1
        end

        script
      end
    end

    # Internal: Get Language for shebang script
    #
    # Returns the Language or nil
    def shebang_language
      if script = shebang_script
        Language[script]
      end
    end

    # Internal: Guess language from the first line
    #
    # Returns a Language.
    def first_line_language
      if lines[0] =~ /^<\?php/
        Language['PHP']
      end
    end

    # Public: Highlight syntax of blob
    #
    # Returns html String
    def colorize
      return if !text? || large?
      lexer.colorize(data)
    end

    # Public: Highlight syntax of blob without the outer highlight div
    # wrapper.
    #
    # Returns html String
    def colorize_without_wrapper
      return if !text? || large?
      lexer.colorize_without_wrapper(data)
    end
  end
end
