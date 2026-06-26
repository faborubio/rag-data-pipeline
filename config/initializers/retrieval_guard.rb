# Fail-fast guard for the abstention safety net.
#
# Abstention (answering "no encontré información" instead of inventing) only
# works when the active reranker can GATE on its top score. The lexical reranker
# never gates (Reranker#confident? is always true), so running production with
# the lexical reranker silently disables abstention and the RAG goes back to
# confidently answering off-topic questions — with NO test catching it (CI runs
# the lexical tier).
#
# So: in production, refuse to boot unless the reranker actually gates. The
# escape hatch ALLOW_NON_GATING_RERANKER=1 is for a deliberate deployment that
# accepts non-abstaining answers (e.g. a closed corpus where every question is
# in-scope).
Rails.application.config.after_initialize do
  next unless Rails.env.production?
  next if ENV["ALLOW_NON_GATING_RERANKER"] == "1"

  # confident?(-Float::INFINITY) is true only for a reranker that never gates
  # (the lexical one). Cheap + safe: it reads a threshold constant, never loads
  # the ONNX model.
  gating = !Rag.reranker.confident?(-Float::INFINITY)
  next if gating

  raise <<~MSG
    Abstention is disabled: the active reranker (#{Rag.reranker.class}) never gates on
    relevance, so the Read Path will answer even off-topic questions instead of abstaining.
    Set RERANKER=neural to enable abstention, or ALLOW_NON_GATING_RERANKER=1 to accept this
    on purpose. See AUDIT.md (gate de abstención).
  MSG
end
