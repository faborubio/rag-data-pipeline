Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  namespace :api do
    namespace :v1 do
      # Write Path: upload a PDF (async ingestion) and inspect its status.
      resources :documents, only: %i[create show]
      # Read Path: synchronous RAG query.
      post "chats/query", to: "chats#query"
    end
  end

  # Defines the root path route ("/")
  # root "posts#index"
end
