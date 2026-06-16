module Api
  module V1
    # Unauthenticated endpoint that hands the public demo its credentials, so the
    # static demo page works without anyone pasting a key. In production the demo
    # tenant is read-only (see AddReadOnlyToTenants), so exposing its key only
    # allows querying the seeded corpus — never ingestion. Runs on the
    # deterministic fallback in production (no OPENAI_API_KEY), so no token cost.
    #
    # `can_upload` lets the same static page enable file upload when the served
    # tenant is writable (local dev) and hide it when it's read-only (prod). The
    # backend is still the real gate: DocumentsController#create rejects uploads to
    # a read-only tenant regardless of what the UI shows.
    class DemoController < ApplicationController
      # GET /api/v1/demo
      def show
        tenant = demo_tenant
        return render(json: { error: "no demo tenant configured" }, status: :not_found) unless tenant

        render json: { api_key: tenant.api_key, tenant: tenant.name, can_upload: !tenant.read_only? }
      end

      private

      # Which tenant the demo speaks for. Prod serves the read-only demo tenant;
      # an explicit DEMO_TENANT name overrides; in development only we fall back to
      # any tenant so a fresh dev DB (no read-only tenant) still boots the demo
      # against a writable tenant. Production and test never fall back to a writable
      # tenant (prod stays read-only; test stays deterministic).
      def demo_tenant
        if (name = ENV["DEMO_TENANT"].presence)
          Tenant.find_by(name: name)
        else
          Tenant.where(read_only: true).order(:created_at).first ||
            (Tenant.order(:created_at).first if Rails.env.development?)
        end
      end
    end
  end
end
