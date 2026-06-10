module Api
  module V1
    # Base API controller enforcing strict per-tenant authentication.
    # The raw secret API key is matched via the blind index (constant time).
    class BaseController < ApplicationController
      before_action :set_request_context
      before_action :authenticate_tenant!

      rescue_from ActiveRecord::RecordNotFound do
        render_error("not found", :not_found)
      end

      private

      def set_request_context
        Current.request_id = request.request_id
      end

      def authenticate_tenant!
        tenant = Tenant.authenticate(api_key_from_request)
        return render_error("invalid or missing API key", :unauthorized) unless tenant

        Current.tenant = tenant
      end

      def api_key_from_request
        authorization = request.headers["Authorization"].to_s
        return authorization.split(" ", 2).last if authorization.start_with?("Bearer ")

        request.headers["X-Api-Key"].presence
      end

      def current_tenant
        Current.tenant
      end

      def render_error(message, status)
        render json: { error: message }, status: status
      end
    end
  end
end
