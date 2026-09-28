require 'rails_helper'

RSpec.describe 'Api::FinancialHygiene', type: :request do
  let(:user) { create(:user) }

  before { sign_in user }

  it 'returns only the current user hygiene indicators without changing records' do
    create(:transaction, user: user, category: nil, card: nil, source: :cash, date: Date.current, value: 30)
    create(:transaction, user: user, category: create(:category, user: user), card: nil, source: :bank, date: Date.current - 1, value: 40, paid: false)
    create(:transaction, user: user, card: nil, source: :cash, date: Date.current - 2, value: 20, payment_ignored_at: Time.current)
    other = create(:user)
    create(:transaction, user: other, category: nil, card: nil, source: :cash, date: Date.current - 3, value: 999)

    expect { get '/api/financial_hygiene' }.not_to change(Transaction, :count)

    expect(response).to have_http_status(:ok)
    indicators = JSON.parse(response.body).fetch('indicators').index_by { |entry| entry.fetch('key') }
    expect(indicators.fetch('uncategorized')).to include('count' => 2, 'total_amount' => '50.0', 'action_url' => '/transactions')
    expect(indicators.fetch('overdue_loose_expenses')).to include('count' => 1, 'total_amount' => '40.0', 'action_url' => '/payments')
    expect(indicators.fetch('ignored_payments')).to include('count' => 1, 'total_amount' => '20.0', 'action_url' => '/payments')
  end
end
