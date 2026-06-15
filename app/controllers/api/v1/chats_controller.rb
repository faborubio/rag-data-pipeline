module Api
  module V1
    class ChatsController < BaseController
      include ActionController::Live

      # POST /api/v1/chats/query
      # Body: { document_ids: [uuid...], question: "...", stream: false }
      # When stream=true the answer is sent token-by-token as Server-Sent Events.
      def query
        question = params[:question].to_s
        document_ids = Array(params[:document_ids]).map(&:to_s).reject(&:blank?)

        return render_error("question is required", :unprocessable_entity) if question.blank?
        return render_error("document_ids is required", :unprocessable_entity) if document_ids.empty?

        if streaming?
          stream_answer(question, document_ids)
        else
          result = Rag::QueryService.new.call(
            tenant: current_tenant, question: question, document_ids: document_ids
          )
          render json: { answer: result.answer, sources: result.sources, latency_ms: result.latency_ms }
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
        sse.write({ sources: sources, done: true,
                    cache_hit: Current.rag[:cache_hit], latency_ms: Current.rag[:latency_ms] }, event: "done")
      rescue ActionController::Live::ClientDisconnected
        # client closed the connection mid-stream; nothing to do
      ensure
        sse&.close
      end
    end
  end
end
