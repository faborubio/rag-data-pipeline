module Api
  module V1
    # Per-tenant query analytics: volume, how often the corpus could answer, and
    # which questions it couldn't (content gaps worth feeding the corpus).
    class AnalyticsController < BaseController
      def show
        scope = QueryLog.where(tenant: current_tenant)
        total = scope.count

        render json: {
          total: total,
          answered: scope.answered.count,
          abstained: scope.abstained.count,
          cache_hit_rate: total.zero? ? 0.0 : (scope.where(cache_hit: true).count.fdiv(total)).round(3),
          thumbs_up: scope.where(rating: 1).count,
          thumbs_down: scope.where(rating: -1).count,
          top_questions: QueryLog.top_questions(current_tenant, limit: 10),
          content_gaps: QueryLog.content_gaps(current_tenant, limit: 10)
        }
      end
    end
  end
end
