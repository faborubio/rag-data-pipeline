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
        retrieval = Rag::QueryService.new.retrieve(
          tenant: current_tenant, question: question, document_ids: document_ids
        )

        response.headers["Content-Type"] = "text/event-stream"
        response.headers["Cache-Control"] = "no-cache"
        response.headers["X-Accel-Buffering"] = "no" # disable proxy buffering (nginx)
        sse = ActionController::Live::SSE.new(response.stream)

        Rag::Llm.new.answer_stream(question: question, contexts: retrieval[:contexts]) do |delta|
          sse.write({ delta: delta }, event: "token")
        end
        sse.write({ sources: retrieval[:sources], done: true }, event: "done")
      rescue ActionController::Live::ClientDisconnected
        # client closed the connection mid-stream; nothing to do
      ensure
        sse&.close
      end
    end
  end
end
