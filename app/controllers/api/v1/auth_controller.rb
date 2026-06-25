module Api
  module V1
    # Login for the demo's two fixed accounts (admin curates, visitor reads). No
    # public signup — accounts are seeded (see db/seeds.rb). Inherits from
    # ApplicationController since it's the entry point before having a key. On
    # success returns the user's API key + role, which the demo stores and uses.
    class AuthController < ApplicationController
      # POST /api/v1/login {email, password}
      def login
        user = User.find_by(email: params[:email].to_s.strip.downcase)&.authenticate(params[:password].to_s)
        # Generic message: never reveal whether the email exists.
        return render(json: { error: "invalid email or password" }, status: :unauthorized) unless user

        render json: { api_key: user.api_key, email: user.email, role: user.role }
      end
    end
  end
end
