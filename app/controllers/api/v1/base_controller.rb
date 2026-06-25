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
        raw_key = api_key_from_request
        # A user key resolves to a specific account (→ tenant + role); a tenant key
        # is the anonymous/public path (Current.user stays nil). Either authenticates.
        if (user = User.authenticate(raw_key))
          Current.user = user
          Current.tenant = user.tenant
        elsif (tenant = Tenant.authenticate(raw_key))
          Current.tenant = tenant
        else
          render_error("invalid or missing API key", :unauthorized)
        end
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
