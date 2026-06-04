require "open3"

module Rag
  # Extracts text per page from a PDF by shelling out to Poppler's `pdftotext`
  # (spec: delegate heavy extraction to the compiled C/C++ binary via subprocess).
  class PdfTextExtractor
    class ExtractionError < StandardError; end

    def initialize(binary: "pdftotext")
      @binary = binary
    end

    # Returns an Array of { page: Integer, text: String }.
    # pdftotext separates pages with a form-feed (\f) character.
    def extract(path)
      out, err, status = Open3.capture3(@binary, "-layout", "-enc", "UTF-8", path.to_s, "-")
      raise ExtractionError, (err.presence || "pdftotext exited #{status.exitstatus}") unless status.success?

      out.split("\f").each_with_index.map do |page_text, index|
        { page: index + 1, text: page_text.to_s }
      end
    end
  end
end
