Rails.application.routes.draw do
  resources :users, only: [:index, :show, :create, :update, :destroy]

  resources :posts, only: [:index, :show, :create, :update] do
    collection do
      get :trending
      get :search
    end
  end

  resources :orders, only: [:index, :show, :create, :update] do
    member do
      post :cancel
    end
    collection do
      get :user_orders
      get :report
    end
  end

  # セッション管理
  post   "/login",  to: "sessions#create"
  get    "/me",     to: "sessions#show"
  delete "/logout", to: "sessions#destroy"

  # ヘルスチェック
  get "/health", to: "health#show"

  # ダッシュボード（HTML）
  get "/dashboard", to: "dashboard#index"

  # ルートパス
  root "health#show"
end
