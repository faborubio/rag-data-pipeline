module Rag
  # Structure-aware chunking. Real documents carry meaning in their layout:
  # paragraphs and headings/sections. Instead of feeding a whole page to a
  # character splitter (which merges unrelated paragraphs and cuts at an
  # arbitrary offset), we:
  #
  #   1. segment the page into structural blocks — paragraphs (blank-line
  #      separated, with hard-wrapped lines reflowed back into one), and headings
  #      that stay attached to the text they introduce;
  #   2. pack consecutive blocks into chunks up to CHUNK_SIZE, but NEVER merge
  #      across the start of a new section, so a section never bleeds into the
  #      previous one;
  #   3. split a single block larger than CHUNK_SIZE recursively (langchainrb
  #      RecursiveText — spec's RecursiveCharacterTextSplitter, with overlap;
  #      sliding-window fallback if unavailable).
  #
  # This keeps each chunk semantically coherent, which matters for big, messy
  # real PDFs. The demo corpus is already clean, so the evals stay at 1.0 (see
  # AUDIT.md) — the win is robustness on real-world input.
  class SemanticChunker
    CHUNK_SIZE = 500
    CHUNK_OVERLAP = 50

    # A heading must be a SHORT, SINGLE line that looks like a section title:
    # legal/structured ("Artículo 5", "Capítulo II", "Sección 3", "Título I") or
    # numbered ("1", "1.2", "3.4.1."). Requiring a single short line excludes
    # hard-wrapped prose that merely happens to start with a number.
    MAX_HEADING_LENGTH = 80
    HEADING = /\A(?:
        (?:art(?:[íi]culo|\.)|cap[íi]tulo|secci[óo]n|t[íi]tulo)\b   # Artículo 5, Capítulo II
      | \d+(?:\.\d+)*\.?(?:\s|\z)                                   # 1   1.2   3.4.1.
    )/xi

    def initialize(chunk_size: CHUNK_SIZE, chunk_overlap: CHUNK_OVERLAP)
      @chunk_size = chunk_size
      @chunk_overlap = chunk_overlap
    end

    # text -> Array<String>
    def chunk(text)
      return [] if text.nil? || text.strip.empty?

      pack(blocks(text))
    end

    private

    # Page text -> Array<{ text:, section_start: }>. A heading is buffered and
    # prepended to the next body paragraph (so the heading travels with its first
    # paragraph); blocks beginning with a heading are flagged as section starts.
    def blocks(text)
      result = []
      pending_headings = []

      paragraphs(text).each do |raw|
        if heading?(raw)
          pending_headings << reflow(raw)
        else
          body = (pending_headings + [ reflow(raw) ]).join("\n")
          result << { text: body, section_start: pending_headings.any? }
          pending_headings = []
        end
      end
      result << { text: pending_headings.join("\n"), section_start: true } if pending_headings.any?

      result
    end

    # Raw paragraphs: normalize line endings, split on blank lines, drop empties.
    def paragraphs(text)
      text.to_s.gsub(/\r\n?/, "\n").split(/\n[ \t]*\n+/).map(&:strip).reject(&:empty?)
    end

    # A single short line matching a section-title pattern.
    def heading?(raw)
      raw.length <= MAX_HEADING_LENGTH && !raw.include?("\n") && raw.match?(HEADING)
    end

    # Reflow a hard-wrapped paragraph back into one line and collapse the runs of
    # spaces that `pdftotext -layout` leaves behind.
    def reflow(raw)
      raw.split("\n").map(&:strip).join(" ").gsub(/[ \t]+/, " ").strip
    end

    # Greedily concatenate blocks up to CHUNK_SIZE, flushing before any block
    # that starts a new section. Oversized blocks are split first.
    def pack(blocks)
      chunks = []
      current = +""

      blocks.each do |block|
        fit(block[:text]).each_with_index do |piece, index|
          force_break = block[:section_start] && index.zero?
          if current.empty?
            current = +piece
          elsif force_break || current.length + 2 + piece.length > @chunk_size
            chunks << current
            current = +piece
          else
            current << "\n\n" << piece
          end
        end
      end
      chunks << current unless current.empty?

      chunks
    end

    # A block that fits is one piece; an oversized one is split recursively
    # (langchainrb, with the sliding-window fallback) so overlap is preserved.
    def fit(text)
      return [ text ] if text.length <= @chunk_size

      langchain_chunks(text) || fallback_chunks(text)
    end

    def langchain_chunks(text)
      return nil unless defined?(Langchain::Chunker::RecursiveText)

      Langchain::Chunker::RecursiveText
        .new(text, chunk_size: @chunk_size, chunk_overlap: @chunk_overlap)
        .chunks
        .map { |c| c.respond_to?(:text) ? c.text : c.to_s }
        .map(&:strip)
        .reject(&:empty?)
    rescue StandardError => e
      Rails.logger.warn("[SemanticChunker] langchainrb failed (#{e.class}: #{e.message}); using fallback")
      nil
    end

    def fallback_chunks(text)
      step = [ @chunk_size - @chunk_overlap, 1 ].max
      chunks = []
      i = 0
      while i < text.length
        piece = text[i, @chunk_size].to_s.strip
        chunks << piece unless piece.empty?
        i += step
      end
      chunks
    end
  end
end
