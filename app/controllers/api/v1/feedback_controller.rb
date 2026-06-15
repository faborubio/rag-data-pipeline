module Api
  module V1
    # Records 👍/👎 feedback on a previous answer, looked up by the query_id the
    # query response returned. Scoped to the tenant so one tenant can't rate
    # another's queries.
    class FeedbackController < BaseController
      def create
        rating = params[:rating].to_i
        return render_error("rating must be 1 or -1", :unprocessable_entity) unless [ 1, -1 ].include?(rating)

        log = QueryLog.find_by(id: params[:query_id], tenant: current_tenant)
        return render_error("query not found", :not_found) unless log

        log.update!(rating: rating)
        render json: { ok: true }
      end
    end
  end
end
