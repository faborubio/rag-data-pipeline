require "test_helper"

class Rag::PdfTextExtractorTest < ActiveSupport::TestCase
  test "extracts text per page with 1-based page numbers" do
    path = build_pdf(Rails.root.join("tmp", "extractor_test.pdf"), [
      "Primera pagina sobre incendios.",
      "Segunda pagina sobre evacuacion."
    ])

    pages = Rag::PdfTextExtractor.new.extract(path)

    assert_equal [ 1, 2 ], pages.map { |p| p[:page] }
    assert_includes pages.first[:text], "incendios"
    assert_includes pages.second[:text], "evacuacion"
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  test "raises ExtractionError when extraction exceeds the timeout" do
    # A shim that ignores its args and just hangs, so the timeout path fires
    # deterministically without depending on a pathological real PDF.
    shim = Rails.root.join("tmp", "slow_pdftotext.sh")
    File.write(shim, "#!/bin/sh\nsleep 30\n")
    FileUtils.chmod("+x", shim)

    extractor = Rag::PdfTextExtractor.new(binary: shim.to_s, timeout: 1)
    error = assert_raises(Rag::PdfTextExtractor::ExtractionError) do
      extractor.extract("whatever.pdf")
    end
    assert_match(/timed out/, error.message)
  ensure
    File.delete(shim) if shim && File.exist?(shim)
  end
end
