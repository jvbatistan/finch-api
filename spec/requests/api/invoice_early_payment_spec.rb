require 'rails_helper'

RSpec.describe 'Early card statement payments', type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user) }
  let(:card) { create(:card, user: user, closing_day: 8, due_day: 15) }
  let(:account) do
    create(:account, user: user, initial_balance: 200, initial_balance_date: Date.new(2026, 3, 1))
  end

  before { sign_in user }

  it 'settles the statement after closing but before its due date without debiting the card purchase' do
    transaction = create(:transaction, user: user, card: card, source: :card,
                                       date: Date.new(2026, 3, 3), value: 120, paid: false)
    statement = card.sync_statement!(3, 2026)

    expect(statement.billing_statement).to eq(Date.new(2026, 3, 15))
    expect(Accounts::BalanceCalculator.call(account)).to eq(200.to_d)

    travel_to(Time.zone.local(2026, 3, 10, 12)) do
      expect do
        post "/api/payments/card_statements/#{statement.id}/pay", params: { account_id: account.id }
      end.not_to change(Transaction, :count)
    end

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to include(
      'total_amount' => '120.0', 'paid_amount' => '120.0',
      'remaining_amount' => '0.0', 'payment_status' => 'paid'
    )
    expect(transaction.reload.paid).to eq(true)
    expect(statement.reload.paid_at.to_date).to eq(Date.new(2026, 3, 10))
    expect(Accounts::BalanceCalculator.call(account)).to eq(80.to_d)

    get "/api/accounts/#{account.id}/statement", params: { movement_type: 'card_statement_payment' }

    expect(response).to have_http_status(:ok)
    account_statement = JSON.parse(response.body)
    expect(account_statement['summary']).to include('debits_total' => '120.0')
    expect(account_statement['items'].map { |item| [item['amount'], item['occurred_on']] })
      .to eq([['120.0', '2026-03-10']])
  end

  it 'tracks multiple payments before closing and completes payment before the due date exactly once in the account' do
    transaction = create(:transaction, user: user, card: card, source: :card,
                                       date: Date.new(2026, 3, 3), value: 120, paid: false)
    statement = card.sync_statement!(3, 2026)

    [
      [6, '40.50', '40.5', '79.5', '159.5'],
      [7, '29.50', '70.0', '50.0', '130.0'],
      [10, '50.00', '120.0', '0.0', '80.0']
    ].each do |day, amount, paid_amount, remaining_amount, account_balance|
      travel_to(Time.zone.local(2026, 3, day, 12)) do
        post "/api/payments/card_statements/#{statement.id}/pay", params: { account_id: account.id, amount: amount }
      end

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body).to include(
        'total_amount' => '120.0', 'paid_amount' => paid_amount,
        'remaining_amount' => remaining_amount,
        'payment_status' => day == 10 ? 'paid' : 'partially_paid'
      )
      expect(transaction.reload.paid).to eq(day == 10)
      expect(statement.reload.payment_status).to eq(day == 10 ? 'paid' : 'partially_paid')
      expect(Accounts::BalanceCalculator.call(account)).to eq(account_balance.to_d)
    end

    payments = statement.card_statement_payments.order(:paid_at)
    expect(payments.pluck(:amount).map(&:to_d)).to eq(%w[40.50 29.50 50.00].map(&:to_d))
    expect(payments.pluck(:paid_at).map(&:to_date)).to eq([6, 7, 10].map { |day| Date.new(2026, 3, day) })
    expect(statement.reload.paid_at.to_date).to eq(Date.new(2026, 3, 10))
    expect(Accounts::BalanceCalculator.call(account)).to eq(80.to_d)

    get '/api/payments', params: { month: 3, year: 2026 }

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['statements'].first).to include(
      'total_amount' => '120.0', 'paid_amount' => '120.0',
      'remaining_amount' => '0.0', 'payment_status' => 'paid'
    )

    get "/api/accounts/#{account.id}/statement"

    expect(response).to have_http_status(:ok)
    account_statement = JSON.parse(response.body)
    expect(account_statement['account']['current_balance']).to eq('80.0')
    expect(account_statement['summary']).to include(
      'credits_total' => '200.0', 'debits_total' => '120.0', 'net_total' => '80.0'
    )
    expect(account_statement['items'].map { |item| item['movement_type'] })
      .to contain_exactly('initial_balance', 'card_statement_payment', 'card_statement_payment', 'card_statement_payment')
    expect(account_statement['items'].select { |item| item['movement_type'] == 'card_statement_payment' }
                            .map { |item| [item['amount'], item['occurred_on']] })
      .to contain_exactly(['40.5', '2026-03-06'], ['29.5', '2026-03-07'], ['50.0', '2026-03-10'])
  end
end
