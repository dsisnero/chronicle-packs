module Chronicle::Packs::PublicPresence
  # Zero-key HTML→text extraction: stdlib only, deterministic. Ported from
  # upstream packs/importers/public_presence/html_text.py.
  #
  # BeautifulSoup-grade in ambition, html.parser in dependency weight:
  # scripts/styles dropped, block elements become line breaks, whitespace
  # collapsed. A keyed Firecrawl-grade fetcher replaces the whole fetch
  # capability behind the same seam — it never needs this module.
  module HtmlText
    SKIP  = Set{"script", "style", "noscript", "template", "svg", "head"}
    BLOCK = Set{"p", "div", "br", "li", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6", "tr", "table", "section", "article", "header", "footer", "blockquote", "pre"}

    # A minimal HTML tokenizer: handles start/end tags, data, comments, and
    # doctypes; tracks skip depth for script/style/etc.
    class TextExtractor
      @chunks = [] of String
      @skip_depth = 0
      @title = ""
      @in_title = false

      def title : String
        @title
      end

      # Tokenize the whole document.
      def feed(html : String) : Nil
        i = 0
        size = html.size
        while i < size
          if html[i] == '<'
            close = html.index('>', i + 1)
            if close.nil?
              _append_data(html[i..])
              break
            end
            _handle_tag(html[(i + 1)...close])
            i = close + 1
          else
            data_start = i
            next_lt = html.index('<', i)
            data_end = next_lt || size
            _append_data(html[data_start...data_end])
            i = data_end
          end
        end
      end

      private def _handle_tag(tag_text : String) : Nil
        return if tag_text.starts_with?('!') || tag_text.starts_with?('?') || tag_text.starts_with?('%')
        stripped = tag_text.lstrip
        if stripped.starts_with?('/')
          name = _tag_name(stripped[1..])
          _handle_endtag(name) unless name.empty?
          return
        end
        name = _tag_name(stripped)
        return if name.empty?
        _handle_starttag(name)
      end

      private def _tag_name(raw : String) : String
        idx = raw.index(/\s/)
        idx ? raw[0...idx] : raw
      end

      private def _handle_starttag(tag : String) : Nil
        if SKIP.includes?(tag)
          @skip_depth += 1
        end
        if tag == "title"
          @in_title = true
        end
        if BLOCK.includes?(tag)
          @chunks << "\n"
        end
      end

      private def _handle_endtag(tag : String) : Nil
        if SKIP.includes?(tag) && @skip_depth > 0
          @skip_depth -= 1
        end
        if tag == "title"
          @in_title = false
        end
        if BLOCK.includes?(tag)
          @chunks << "\n"
        end
      end

      private def _append_data(data : String) : Nil
        if @in_title
          @title += data
          return
        end
        return if @skip_depth > 0
        @chunks << data
      end

      def text : String
        raw = @chunks.join
        lines = raw.split('\n').map(&.split.join(' '))
        lines.reject(&.empty?).join("\n")
      end
    end

    # Return (text, title) for one HTML document; plain text passes through.
    def self.html_to_text(html : String) : {String, String}
      lowered = html[0, Math.min(html.size, 2048)].downcase
      looks_html = lowered.includes?("<html") || lowered.includes?("<body") || lowered.includes?("<div") || lowered.includes?("<p") || lowered.includes?("<!doctype")
      unless looks_html
        collapsed = html.split('\n').map(&.split.join(' ')).join("\n")
        return {collapsed.split('\n').reject(&.empty?).join("\n"), ""}
      end
      parser = TextExtractor.new
      begin
        parser.feed(html)
      rescue
        # Defensive: a malformed document yields whatever was parsed.
      end
      {parser.text, parser.title.split.join(' ')}
    end
  end

  # Public alias so callers use `PublicPresence.html_to_text`.
  def self.html_to_text(html : String) : {String, String}
    HtmlText.html_to_text(html)
  end
end
