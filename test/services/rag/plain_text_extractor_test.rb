require "test_helper"

class Rag::PlainTextExtractorTest < ActiveSupport::TestCase
  test "reads a text file as a single page" do
    path = Rails.root.join("tmp", "pt_#{SecureRandom.hex(4)}.txt")
    File.write(path, "Primera linea.\n\nSegundo parrafo sobre evacuacion.")

    pages = Rag::PlainTextExtractor.new.extract(path.to_s)

    assert_equal 1, pages.size
    assert_equal 1, pages.first[:page]
    assert_includes pages.first[:text], "Segundo parrafo"
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  test "extractor_for dispatches by file extension" do
    assert_instance_of Rag::PlainTextExtractor, Rag.extractor_for("notes.txt")
    assert_instance_of Rag::PlainTextExtractor, Rag.extractor_for("README.md")
    assert_instance_of Rag::PdfTextExtractor, Rag.extractor_for("manual.pdf")
  end
end
