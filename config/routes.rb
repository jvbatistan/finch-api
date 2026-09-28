Rails.application.routes.draw do
  devise_for :users, skip: :all

  root to: "api/health#show"

  namespace :api do
    get "dashboard", to: "dashboard#show"
    get "health",    to: "health#show"
    get "me",        to: "me#show"
    get "csrf",      to: "csrf#show"
    patch "me",      to: "me#update"
    post "register", to: "registrations#create"
    post "login",    to: "sessions#create"
    delete "logout", to: "sessions#destroy"
    resource :data_environment, only: [:show] do
      post :switch
    end

    resources :transactions, only: [:index, :create, :update, :destroy] do
      collection do
        get :export_csv
      end
    end
    resources :classification_suggestions, only: [:index] do
      member do
        post :apply
        post :accept
        post :reject
        post :correct
      end
    end
    resources :accounts, only: [:index, :show, :create, :update, :destroy] do
      member do
        patch :restore
        get :statement
        get "statement/print", action: :print_statement
        get "statement/export_csv", action: :export_csv
      end
    end
    resources :account_transfers, only: [:index, :show, :create] do
      member do
        patch :reverse
      end
    end
    resources :categories, only: [:index, :create, :update, :destroy]
    resources :cards, only: [:index, :create, :update, :destroy]

    get  "payments", to: "payments#index"
    post "payments/card_statements/pay", to: "payments#pay_card_statement_by_reference"
    post "payments/card_statements/:id/pay", to: "payments#pay_card_statement"
    post "payments/card_statements/ignore", to: "payments#ignore_card_statement_by_reference"
    post "payments/card_statements/:id/ignore", to: "payments#ignore_card_statement"
    post "payments/loose_expenses/:id/pay", to: "payments#pay_loose_expense"
    post "payments/loose_expenses/:id/ignore", to: "payments#ignore_loose_expense"
    post "payments/loose_expenses/pay", to: "payments#pay_loose_expenses"
  end
end
