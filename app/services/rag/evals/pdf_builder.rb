module Rag
  module Evals
    # Writes a minimal, valid multi-page PDF (one text line per page). Used by
    # the quality evals to feed the golden corpus through the real ingestion
    # pipeline (pdftotext -> chunk -> embed), and by the test helpers.
    #
    # Texts are embedded as PDF literal strings with the built-in Helvetica
    # font: keep them ASCII (no accents) — parentheses are stripped.
    class PdfBuilder
      def self.write(path, page_texts)
        objects = {}
        objects[1] = "<< /Type /Catalog /Pages 2 0 R >>"
        objects[3] = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"

        page_ids = []
        next_id = 4
        page_texts.each do |text|
          page_id = next_id
          content_id = next_id + 1
          next_id += 2
          page_ids << page_id
          safe = text.to_s.gsub("(", " ").gsub(")", " ")
          stream = text_stream(safe)
          objects[page_id] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " \
                             "/Contents #{content_id} 0 R /Resources << /Font << /F1 3 0 R >> >> >>"
          objects[content_id] = "<< /Length #{stream.bytesize} >>\nstream\n#{stream}\nendstream"
        end
        objects[2] = "<< /Type /Pages /Kids [#{page_ids.map { |i| "#{i} 0 R" }.join(' ')}] " \
                     "/Count #{page_texts.size} >>"

        header = "%PDF-1.4\n"
        ids = objects.keys.sort
        body = +""
        offsets = {}
        pos = header.bytesize
        ids.each do |id|
          offsets[id] = pos
          chunk = "#{id} 0 obj\n#{objects[id]}\nendobj\n"
          body << chunk
          pos += chunk.bytesize
        end
        max_id = ids.max
        xref_pos = header.bytesize + body.bytesize
        xref = +"xref\n0 #{max_id + 1}\n0000000000 65535 f \n"
        (1..max_id).each do |id|
          xref << (offsets[id] ? format("%010d 00000 n \n", offsets[id]) : "0000000000 65535 f \n")
        end
        trailer = "trailer\n<< /Size #{max_id + 1} /Root 1 0 R >>\nstartxref\n#{xref_pos}\n%%EOF\n"
        File.binwrite(path, header + body + xref + trailer)
        path
      end

      # Word-wraps the text into short lines inside the page width: a single
      # long Tj overflows the MediaBox and pdftotext -layout clips whatever
      # falls outside, silently truncating the extracted content.
      def self.text_stream(text, width: 70)
        lines = []
        current = +""
        text.split(" ").each do |word|
          if current.empty?
            current << word
          elsif current.length + 1 + word.length <= width
            current << " " << word
          else
            lines << current
            current = +word.dup
          end
        end
        lines << current unless current.empty?

        body = lines.map { |line| "(#{line}) Tj 0 -18 Td" }.join(" ")
        "BT /F1 14 Tf 72 720 Td #{body} ET"
      end
    end
  end
end
