module Rag
  # Extracts plain-text formats (.txt, .md). There are no real pages, so the
  # whole file is a single page-1 unit; the structure-aware chunker then splits
  # it into paragraphs/sections like any other document.
  class PlainTextExtractor
    def extract(path)
      [ { page: 1, text: File.read(path, encoding: "UTF-8") } ]
    end
  end
end
