module Api
  module V1
    # Unauthenticated endpoint that hands the public demo its credentials, so the
    # static demo page works without anyone pasting a key. The demo tenant is
    # read-only (see AddReadOnlyToTenants), so exposing its key only allows
    # querying the seeded corpus — never ingestion. Runs on the deterministic
    # fallback in production (no OPENAI_API_KEY), so there is no token cost.
    class DemoController < ApplicationController
      # GET /api/v1/demo
      def show
        tenant = Tenant.where(read_only: true).order(:created_at).first
        return render(json: { error: "no demo tenant configured" }, status: :not_found) unless tenant

        render json: { api_key: tenant.api_key, tenant: tenant.name }
      end
    end
  end
end
