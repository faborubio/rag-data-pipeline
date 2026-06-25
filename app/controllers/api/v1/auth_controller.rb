module Api
  module V1
    # Account signup/login for the demo's personal mode. Inherits from
    # ApplicationController (not BaseController) since these are the entry points
    # that exist *before* the caller has an API key. On success they return the
    # API key of the user's own writable tenant, which the demo stores and uses
    # for uploads/queries — same shape as DemoController for the public tenant.
    class AuthController < ApplicationController
      # POST /api/v1/signup {email, password}
      def signup
        user = User.register(email: param(:email), password: param(:password))
        render json: credentials(user), status: :created
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.record.errors.full_messages.first || "invalid signup" },
               status: :unprocessable_entity
      end

      # POST /api/v1/login {email, password}
      def login
        user = User.find_by(email: param(:email))&.authenticate(param(:password))
        # Generic message: never reveal whether the email exists.
        return render(json: { error: "invalid email or password" }, status: :unauthorized) unless user

        render json: credentials(user)
      end

      private

      def param(key) = params[key].to_s.strip

      def credentials(user) = { api_key: user.tenant.api_key, email: user.email }
    end
  end
end
