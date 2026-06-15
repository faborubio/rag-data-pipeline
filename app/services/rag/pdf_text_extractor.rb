require "open3"

module Rag
  # Extracts text per page from a PDF by shelling out to Poppler's `pdftotext`
  # (spec: delegate heavy extraction to the compiled C/C++ binary via subprocess).
  class PdfTextExtractor
    class ExtractionError < StandardError; end

    # Hard cap on extraction time. A 100MB+ or malformed PDF can make pdftotext
    # run for a very long time (or hang); without this it would block the worker
    # indefinitely. Override with PDF_EXTRACTION_TIMEOUT (seconds).
    def initialize(binary: "pdftotext", timeout: (ENV["PDF_EXTRACTION_TIMEOUT"] || 120).to_i)
      @binary = binary
      @timeout = timeout
    end

    # Returns an Array of { page: Integer, text: String }.
    # pdftotext separates pages with a form-feed (\f) character.
    def extract(path)
      out, err, status = run(path)
      raise ExtractionError, (err.presence || "pdftotext exited #{status.exitstatus}") unless status.success?

      out.split("\f").each_with_index.map do |page_text, index|
        { page: index + 1, text: page_text.to_s }
      end
    end

    private

    # Runs pdftotext with a wall-clock timeout. stdout/stderr are drained on their
    # own threads so a large document can't deadlock on a full pipe buffer; if the
    # process overruns the timeout it is SIGKILLed (and reaped) and we raise.
    def run(path)
      Open3.popen3(@binary, "-layout", "-enc", "UTF-8", path.to_s, "-") do |stdin, stdout, stderr, wait_thr|
        stdin.close
        out_reader = Thread.new { stdout.read }
        err_reader = Thread.new { stderr.read }

        unless wait_thr.join(@timeout)
          Process.kill("KILL", wait_thr.pid)
          wait_thr.join
          out_reader.kill
          err_reader.kill
          raise ExtractionError, "pdftotext timed out after #{@timeout}s"
        end

        [ out_reader.value, err_reader.value, wait_thr.value ]
      end
    end
  end
end
