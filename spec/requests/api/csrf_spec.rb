require 'rails_helper'

RSpec.describe 'Api::CSRF', type: :request do
  around do |example|
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    example.run
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

  def csrf_token
    get '/api/csrf'
    expect(response).to have_http_status(:ok)
    expect(response.headers['Cache-Control']).to include('no-store')
    JSON.parse(response.body).fetch('csrf_token')
  end

  it 'rejects state-changing requests without a token, including login' do
    create(:user, email: 'csrf@example.com', password: 'password123')

    post '/api/login', params: { email: 'csrf@example.com', password: 'password123' }

    expect(response).to have_http_status(:forbidden)
    expect(JSON.parse(response.body)).to eq('error' => 'Token CSRF inválido ou ausente')
  end

  it 'accepts the session token on login and requires a fresh token after authentication' do
    user = create(:user, email: 'csrf@example.com', password: 'password123')
    token = csrf_token

    post '/api/login', params: { email: user.email, password: 'password123' },
                       headers: { 'X-CSRF-Token' => token }
    expect(response).to have_http_status(:ok)

    patch '/api/me', params: { user: { name: 'Alterado' } },
                     headers: { 'X-CSRF-Token' => token }
    expect(response).to have_http_status(:forbidden)
    expect(user.reload.name).not_to eq('Alterado')

    refreshed_token = csrf_token
    patch '/api/me', params: { user: { name: 'Alterado' } },
                     headers: { 'X-CSRF-Token' => refreshed_token }
    expect(response).to have_http_status(:ok)
    expect(user.reload.name).to eq('Alterado')
  end
end
