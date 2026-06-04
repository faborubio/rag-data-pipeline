module Api
  module V1
    class ChatsController < BaseController
      # POST /api/v1/chats/query
      # Body: { document_ids: [uuid...], question: "...", stream: false }
      def query
        question = params[:question].to_s
        document_ids = Array(params[:document_ids]).map(&:to_s).reject(&:blank?)

        return render_error("question is required", :unprocessable_entity) if question.blank?
        return render_error("document_ids is required", :unprocessable_entity) if document_ids.empty?

        result = Rag::QueryService.new.call(
          tenant: current_tenant,
          question: question,
          document_ids: document_ids
        )

        render json: {
          answer: result.answer,
          sources: result.sources,
          latency_ms: result.latency_ms
        }
      end
    end
  end
end
