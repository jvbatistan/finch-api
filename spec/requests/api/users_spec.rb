require 'rails_helper'

RSpec.describe 'Api::Users', type: :request do
  it 'does not register the rememberable strategy for legacy remember cookies' do
    expect(User.devise_modules).not_to include(:rememberable)
    expect(Devise.mappings.fetch(:user).strategies).not_to include(:rememberable)
  end

  describe 'POST /api/register' do
    it 'refuses public registration in production' do
      allow(Rails.env).to receive(:production?).and_return(true)

      post '/api/register', params: {
        user: {
          name: 'Bloqueado',
          email: 'blocked@example.com',
          password: 'password123',
          password_confirmation: 'password123'
        }
      }

      expect(response).to have_http_status(:forbidden)
      expect(User.find_by(email: 'blocked@example.com')).to be_nil
    end

    it 'refuses public registration in the real data environment' do
      allow(DataEnvironments).to receive(:real_data?).and_return(true)

      post '/api/register', params: {
        user: {
          name: 'Bloqueado',
          email: 'blocked-real@example.com',
          password: 'password123',
          password_confirmation: 'password123'
        }
      }

      expect(response).to have_http_status(:forbidden)
      expect(User.find_by(email: 'blocked-real@example.com')).to be_nil
    end

    it 'registers a user and signs them in' do
      post '/api/register', params: {
        user: {
          name: 'Joao Vitor',
          email: 'joao@example.com',
          password: 'password123',
          password_confirmation: 'password123'
        }
      }

      expect(response).to have_http_status(:created)

      body = JSON.parse(response.body)
      user = User.find_by(email: 'joao@example.com')

      expect(user).to be_present
      expect(body['name']).to eq('Joao Vitor')
      expect(body['email']).to eq('joao@example.com')
      expect(body['active']).to eq(true)
    end

    it 'blocks registration when the user limit is reached' do
      create_list(:user, 2)

      post '/api/register', params: {
        user: {
          name: 'Maria',
          email: 'maria@example.com',
          password: 'password123',
          password_confirmation: 'password123'
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to include('Limite máximo de usuários atingido')
    end
  end

  describe 'GET /api/me' do
    it 'keeps an active session across successive requests' do
      user = create(:user, name: 'Joao')
      sign_in user

      2.times do
        get '/api/me'

        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)['id']).to eq(user.id)
      end
    end

    it 'rejects the old session after disable and re-enable without an intervening request' do
      user = create(:user, name: 'Joao')
      sign_in user
      get '/api/me'
      expect(response).to have_http_status(:ok)

      previous_version = user.session_version
      user.update!(active: false)
      user.update!(active: true)
      expect(user.reload.session_version).to eq(previous_version + 1)

      get '/api/me'
      expect(response).to have_http_status(:unauthorized)
    end

    it 'revokes sessions when an administrative SQL update disables the user' do
      user = create(:user, name: 'Joao')
      sign_in user
      get '/api/me'
      expect(response).to have_http_status(:ok)

      previous_version = user.session_version
      User.where(id: user.id).update_all(active: false)
      User.where(id: user.id).update_all(active: true)
      expect(user.reload.session_version).to eq(previous_version + 1)

      get '/api/me'
      expect(response).to have_http_status(:unauthorized)
    end

    it 'revokes the session as soon as an already signed-in user is disabled' do
      user = create(:user, name: 'Joao')
      sign_in user
      user.update!(active: false)

      get '/api/me'

      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)).to eq('error' => 'Unauthorized')

      user.update!(active: true)
      get '/api/me'
      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns the current user profile' do
      user = create(:user, name: 'Joao')
      sign_in user

      get '/api/me'

      expect(response).to have_http_status(:ok)

      body = JSON.parse(response.body)
      expect(body['id']).to eq(user.id)
      expect(body['name']).to eq('Joao')
      expect(body['email']).to eq(user.email)
      expect(body['active']).to eq(true)
    end
  end

  describe 'PATCH /api/me' do
    it 'updates the current user profile' do
      user = create(:user, name: 'Joao')
      sign_in user

      patch '/api/me', params: {
        user: {
          name: 'Joao Atualizado',
          email: 'novo@example.com'
        }
      }

      expect(response).to have_http_status(:ok)

      user.reload
      body = JSON.parse(response.body)
      expect(user.name).to eq('Joao Atualizado')
      expect(user.email).to eq('novo@example.com')
      expect(body['name']).to eq('Joao Atualizado')
    end
  end

  describe 'POST /api/login' do
    it 'does not authenticate inactive users' do
      user = create(:user, active: false, email: 'inactive@example.com', password: 'password123', password_confirmation: 'password123')

      post '/api/login', params: {
        email: user.email,
        password: 'password123'
      }

      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)['error']).to eq('Credenciais inválidas')
    end
  end
end
