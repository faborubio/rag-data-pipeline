Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Prometheus metrics scrape endpoint.
  get "metrics" => "metrics#show", as: :metrics

  namespace :api do
    namespace :v1 do
      # Write Path: upload a PDF (async ingestion) and inspect its status.
      resources :documents, only: %i[index create show]
      # Upload storage quota for the authenticated tenant (used/budget/available).
      get "storage", to: "storage#show"
      # Read Path: synchronous RAG query.
      post "chats/query", to: "chats#query", as: :chats_query
      # Account signup/login for the demo's personal mode (returns the user's
      # tenant API key). Unauthenticated entry points.
      post "signup", to: "auth#signup"
      post "login", to: "auth#login"
      # Public demo bootstrap: returns the read-only demo tenant's API key.
      get "demo", to: "demo#show"
      # Per-tenant query analytics (volume, answer rate, content gaps).
      get "analytics", to: "analytics#show"
      # 👍/👎 feedback on a previous answer (by query_id).
      post "feedback", to: "feedback#create"
    end
  end

  # Visiting the bare domain lands on the public demo page (served from
  # public/demo.html) instead of a 404.
  root to: redirect("/demo.html")
end
