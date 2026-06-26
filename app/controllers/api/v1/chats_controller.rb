module Api
  module V1
    class ChatsController < BaseController
      include ActionController::Live

      # Hard cap on how many documents one query may target. A query fans out to a
      # vector + full-text scan over WHERE document_id IN (...); an unbounded array
      # lets a client build a pathological IN-list and hammer the DB. The demo only
      # ever selects a handful, so this is generous.
      MAX_DOCUMENT_IDS = (ENV["MAX_QUERY_DOCUMENT_IDS"] || 100).to_i
      # Bound the question length so an enormous body can't blow up embedding /
      # full-text / rerank work (and the cache key) per request.
      MAX_QUESTION_LENGTH = (ENV["MAX_QUESTION_LENGTH"] || 2000).to_i

      # POST /api/v1/chats/query
      # Body: { document_ids: [uuid...], question: "...", stream: false }
      # When stream=true the answer is sent token-by-token as Server-Sent Events.
      def query
        question = params[:question].to_s
        document_ids = Array(params[:document_ids]).map(&:to_s).reject(&:blank?).uniq

        return render_error("question is required", :unprocessable_entity) if question.blank?
        return render_error("question is too long (max #{MAX_QUESTION_LENGTH} chars)", :unprocessable_entity) if question.length > MAX_QUESTION_LENGTH
        return render_error("document_ids is required", :unprocessable_entity) if document_ids.empty?
        return render_error("too many document_ids (max #{MAX_DOCUMENT_IDS})", :unprocessable_entity) if document_ids.size > MAX_DOCUMENT_IDS

        # Distinguish "still indexing" from "not in the corpus": if the tenant owns
        # some of these documents but none have finished ingesting, say so instead
        # of returning a misleading "no encontré información". Scoped to the tenant,
        # so it never reveals anything about another tenant's documents (an
        # unowned/unknown id falls through to the normal empty-sources answer).
        owned = current_tenant.documents.where(id: document_ids)
        if owned.exists? && !owned.completed.exists?
          return render json: {
            answer: "Los documentos seleccionados todavía se están procesando. Probá de nuevo en unos momentos.",
            sources: [], processing: true, query_id: nil
          }, status: :accepted
        end

        if streaming?
          stream_answer(question, document_ids)
        else
          result = Rag::QueryService.new.call(
            tenant: current_tenant, question: question, document_ids: document_ids
          )
          render json: { answer: result.answer, sources: result.sources, latency_ms: result.latency_ms, query_id: result.query_id }
        end
      end

      private

      def streaming?
        ActiveModel::Type::Boolean.new.cast(params[:stream])
      end

      def stream_answer(question, document_ids)
        response.headers["Content-Type"] = "text/event-stream"
        response.headers["Cache-Control"] = "no-cache"
        response.headers["X-Accel-Buffering"] = "no" # disable proxy buffering (nginx)
        sse = ActionController::Live::SSE.new(response.stream)

        # Shares the query cache: a repeated question replays the stored answer
        # (no embed/search/rerank/LLM), and a freshly streamed answer is cached
        # for the next request — streamed or not.
        sources = Rag::QueryService.new.call_streaming(
          tenant: current_tenant, question: question, document_ids: document_ids
        ) do |delta|
          sse.write({ delta: delta }, event: "token")
        end
        sse.write({ sources: sources, done: true, query_id: Current.rag[:query_id],
                    cache_hit: Current.rag[:cache_hit], latency_ms: Current.rag[:latency_ms] }, event: "done")
      rescue ActionController::Live::ClientDisconnected
        # client closed the connection mid-stream; nothing to do
      ensure
        sse&.close
      end
    end
  end
end
