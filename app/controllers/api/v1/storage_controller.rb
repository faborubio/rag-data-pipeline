module Api
  module V1
    # Upload storage quota for the authenticated tenant, so the demo can show a
    # space counter and the largest file still uploadable. The budget is a logical
    # per-tenant guardrail (see Tenant::STORAGE_BUDGET_MB), not the VPS disk.
    class StorageController < BaseController
      # GET /api/v1/storage
      def show
        tenant = current_tenant
        max_upload = [ DocumentsController::MAX_SIZE, tenant.storage_available_bytes ].min
        render json: {
          used_mb: mb(tenant.storage_used_bytes),
          budget_mb: mb(tenant.storage_budget_bytes),
          available_mb: mb(tenant.storage_available_bytes),
          max_upload_mb: mb(max_upload)
        }
      end

      private

      def mb(bytes) = (bytes / 1.megabyte.to_f).round(1)
    end
  end
end
