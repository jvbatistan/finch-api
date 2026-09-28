require 'rails_helper'

RSpec.describe 'Api::Transactions', type: :request do
  let(:user) { create(:user) }

  before do
    sign_in user
  end

  def select_query_count
    count = 0
    callback = lambda do |_name, _started, _finished, _unique_id, payload|
      sql = payload[:sql].to_s
      count += 1 if sql.match?(/\ASELECT/i) && !payload[:cached]
    end

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { yield }
    count
  end

  def request_metrics
    metrics = Hash.new(0)
    callback = lambda do |_name, _started, _finished, _unique_id, payload|
      next if payload[:cached]

      metrics[:select] += 1 if payload[:sql].to_s.match?(/\A\s*SELECT/i)
    end

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { yield }
    metrics[:duration_ms] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1_000).round(1)
    metrics[:payload_bytes] = response.body.bytesize
    metrics
  end

  describe 'POST /api/transactions' do
    it 'persists and returns an optional friendly title without changing the original description' do
      account = create(:account, user: user, initial_balance: 95)

      post '/api/transactions', params: {
        transaction: {
          description: 'PAG*MAQUININHA 1234',
          friendly_title: 'Presente da Maria',
          value: '22,00',
          date: '2026-08-22',
          kind: 'expense',
          source: 'cash',
          account_id: account.id
        }
      }

      expect(response).to have_http_status(:created)

      body = JSON.parse(response.body)
      transaction = Transaction.find(body['id'])
      expect(transaction.description).to eq('PAG*MAQUININHA 1234')
      expect(transaction.friendly_title).to eq('Presente da Maria')
      expect(body['description']).to eq('PAG*MAQUININHA 1234')
      expect(body['friendly_title']).to eq('Presente da Maria')
    end

    it 'rejects cash and bank expenses with a card without creating a transaction' do
      card = create(:card, user: user)

      %w[cash bank].each do |source|
        expect do
          post '/api/transactions', params: {
            transaction: { description: 'Despesa', value: '10,00', date: Date.current, kind: 'expense', source: source, card_id: card.id }
          }
        end.not_to change(Transaction, :count)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body).fetch('error')).to include('Card não deve existir para origem dinheiro ou banco')
      end
    end

    it 'preserves a civil date through create, persistence, response, reload and edit' do
      account = create(:account, user: user, initial_balance: 95)

      post '/api/transactions', params: {
        transaction: {
          description: 'Compra em data civil',
          value: '22,00',
          date: '2026-08-22',
          kind: 'expense',
          source: 'cash',
          account_id: account.id
        }
      }

      expect(response).to have_http_status(:created)

      created_body = JSON.parse(response.body)
      transaction = Transaction.find(created_body['id'])
      expect(transaction.date).to eq(Date.new(2026, 8, 22))
      expect(transaction.purchase_date).to eq(Date.new(2026, 8, 22))
      expect(transaction.original_value).to eq(BigDecimal('22.00'))
      expect(transaction.reload.date).to eq(Date.new(2026, 8, 22))
      expect(created_body['date']).to eq('2026-08-22')
      expect(created_body['purchase_date']).to eq('2026-08-22')
      expect(created_body['original_value'].to_d).to eq(BigDecimal('22.00'))

      get '/api/transactions', params: { month: 8, year: 2026 }

      expect(response).to have_http_status(:ok)
      reloaded_body = JSON.parse(response.body).fetch('transactions').find { |item| item['id'] == transaction.id }
      expect(reloaded_body.fetch('date')).to eq('2026-08-22')

      patch "/api/transactions/#{transaction.id}", params: {
        transaction: { date: '2026-08-23' }
      }

      expect(response).to have_http_status(:ok)
      expect(transaction.reload.date).to eq(Date.new(2026, 8, 23))
      expect(JSON.parse(response.body)['date']).to eq('2026-08-23')
      expect(transaction.purchase_date).to eq(Date.new(2026, 8, 22))
      expect(transaction.original_value).to eq(BigDecimal('22.00'))
    end

    it 'auto-classifies when an exact alias exists' do
      category = create(:category, user: user, name: 'Transporte')
      account = create(:account, user: user, initial_balance: 90)
      MerchantAlias.create!(
        user: user,
        normalized_merchant: 'UBER',
        category: category,
        confidence: 1.0,
        source: :user_override
      )

      post '/api/transactions', params: {
        transaction: {
          description: 'Uber Trip 1234',
          value: '32,90',
          date: Date.current,
          kind: 'expense',
          source: 'cash',
          account_id: account.id
        }
      }

      expect(response).to have_http_status(:created)

      body = JSON.parse(response.body)
      transaction = Transaction.find(body['id'])

      expect(transaction.category_id).to eq(category.id)
      expect(transaction.classification_suggestions.pending.count).to eq(0)
      expect(body.dig('category', 'id')).to eq(category.id)
    end

    it 'creates a pending suggestion when no confident match exists' do
      account = create(:account, user: user, initial_balance: 90)

      post '/api/transactions', params: {
        transaction: {
          description: 'Loja XPTO Centro',
          value: '89,10',
          date: Date.current,
          kind: 'expense',
          source: 'cash',
          account_id: account.id
        }
      }

      expect(response).to have_http_status(:created)

      body = JSON.parse(response.body)
      transaction = Transaction.find(body['id'])

      expect(transaction.category_id).to be_nil
      expect(transaction.classification_suggestions.pending.count).to eq(1)
      expect(body['category']).to be_nil
    end

    it 'rejects a card from another user' do
      other_user = create(:user)
      other_card = create(:card, user: other_user)

      post '/api/transactions', params: {
        transaction: {
          description: 'Compra teste',
          value: '15,00',
          date: Date.current,
          kind: 'expense',
          source: 'card',
          card_id: other_card.id
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to be_present
    end

    it 'does not reveal or accept a category from another user' do
      other_user = create(:user)
      other_category = create(:category, user: other_user)
      account = create(:account, user: user)

      post '/api/transactions', params: {
        transaction: {
          description: 'Compra teste',
          value: '15,00',
          date: Date.current,
          kind: 'expense',
          source: 'cash',
          account_id: account.id,
          category_id: other_category.id
        }
      }

      cross_user_response = [response.status, JSON.parse(response.body)]

      post '/api/transactions', params: {
        transaction: {
          description: 'Compra teste',
          value: '15,00',
          date: Date.current,
          kind: 'expense',
          source: 'cash',
          account_id: account.id,
          category_id: Category.maximum(:id).to_i + 10_000
        }
      }

      missing_response = [response.status, JSON.parse(response.body)]

      expect(cross_user_response).to eq([404, { 'error' => 'Not found' }])
      expect(missing_response).to eq(cross_user_response)
      expect(user.transactions.where(description: 'COMPRA TESTE')).to be_empty
    end

    it 'creates a transaction with a category owned by the current user' do
      category = create(:category, user: user)
      account = create(:account, user: user)

      post '/api/transactions', params: {
        transaction: {
          description: 'Compra categorizada',
          value: '15,00',
          date: Date.current,
          kind: 'expense',
          source: 'cash',
          account_id: account.id,
          category_id: category.id
        }
      }

      expect(response).to have_http_status(:created)
      expect(user.transactions.find(JSON.parse(response.body)['id']).category).to eq(category)
    end

    it 'creates a simple income without requiring card, statement or installment fields' do
      account = create(:account, user: user, name: 'Conta Corrente')

      post '/api/transactions', params: {
        transaction: {
          description: 'Salario mensal',
          value: '3500,00',
          date: Date.new(2026, 6, 30),
          kind: 'income',
          account_id: account.id
        }
      }

      expect(response).to have_http_status(:created)

      body = JSON.parse(response.body)
      transaction = user.transactions.find(body['id'])

      expect(transaction.kind).to eq('income')
      expect(transaction.source).to eq('bank')
      expect(transaction.account).to eq(account)
      expect(transaction.value.to_d).to eq(BigDecimal('3500'))
      expect(transaction.paid).to eq(true)
      expect(transaction.card_id).to be_nil
      expect(transaction.billing_statement).to be_nil
      expect(transaction.installment_group_id).to be_nil
      expect(transaction.installment_number).to be_nil
      expect(transaction.installments_count).to be_nil
      expect(transaction.payment_ignored_at).to be_nil
      expect(transaction.refund).to eq(false)
      expect(body['kind']).to eq('income')
      expect(body['source']).to eq('bank')
      expect(body['paid']).to eq(true)
      expect(body['card']).to be_nil
      expect(body.dig('account', 'id')).to eq(account.id)
      expect(body.dig('account', 'name')).to eq('Conta Corrente')
      expect(body['billing_statement']).to be_nil
    end

    it 'rejects income without account' do
      post '/api/transactions', params: {
        transaction: {
          description: 'Receita sem conta',
          value: '100,00',
          date: Date.current,
          kind: 'income',
          source: 'bank'
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to include('Account é obrigatória para receitas')
    end

    it 'rejects income with an account from another user' do
      other_account = create(:account, user: create(:user))

      post '/api/transactions', params: {
        transaction: {
          description: 'Receita cross user',
          value: '100,00',
          date: Date.current,
          kind: 'income',
          source: 'bank',
          account_id: other_account.id
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to include('Account inválida')
      expect(user.transactions.where(description: 'RECEITA CROSS USER')).to be_empty
    end

    it 'rejects income with an archived account' do
      account = create(:account, user: user, archived_at: Time.current)

      post '/api/transactions', params: {
        transaction: {
          description: 'Receita conta arquivada',
          value: '100,00',
          date: Date.current,
          kind: 'income',
          source: 'bank',
          account_id: account.id
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to include('Account não pode estar arquivada')
    end

    it 'rejects income with a missing account' do
      post '/api/transactions', params: {
        transaction: {
          description: 'Receita conta inexistente',
          value: '100,00',
          date: Date.current,
          kind: 'income',
          source: 'bank',
          account_id: Account.maximum(:id).to_i + 10_000
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to include('Account inválida')
    end

    it 'rejects income with source card' do
      account = create(:account, user: user)

      post '/api/transactions', params: {
        transaction: {
          description: 'Receita no cartao',
          value: '100,00',
          date: Date.current,
          kind: 'income',
          source: 'card',
          account_id: account.id
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to include('Source não pode ser cartão para receitas')
    end

    it 'rejects income with a card' do
      card = create(:card, user: user)
      account = create(:account, user: user)

      post '/api/transactions', params: {
        transaction: {
          description: 'Receita com cartao',
          value: '100,00',
          date: Date.current,
          kind: 'income',
          source: 'bank',
          account_id: account.id,
          card_id: card.id
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to include('Card não deve existir para receitas')
    end

    it 'rejects income with a billing statement' do
      account = create(:account, user: user)

      post '/api/transactions', params: {
        transaction: {
          description: 'Receita com fatura',
          value: '100,00',
          date: Date.current,
          kind: 'income',
          source: 'bank',
          account_id: account.id,
          billing_statement: '2026-07-01'
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to include('Billing statement não deve existir para receitas')
    end

    it 'rejects income with installment params before generating installments' do
      account = create(:account, user: user)

      expect do
        post '/api/transactions', params: {
          transaction: {
            description: 'Receita parcelada',
            value: '100,00',
            date: Date.current,
            kind: 'income',
            source: 'bank',
            account_id: account.id,
            installment_number: 1,
            installments_count: 2
          }
        }
      end.not_to change(Transaction, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to eq('Receita não pode ser parcelada')
    end

    it 'rejects income with refund flag' do
      account = create(:account, user: user)

      post '/api/transactions', params: {
        transaction: {
          description: 'Receita estorno',
          value: '100,00',
          date: Date.current,
          kind: 'income',
          source: 'bank',
          account_id: account.id,
          refund: true
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to include('Refund não pode ser verdadeiro para receitas')
    end

    it 'accepts a card refund and returns its signed value' do
      card = create(:card, user: user)

      post '/api/transactions', params: {
        transaction: {
          description: 'Uber - Nupay',
          value: '6,92',
          date: Date.current,
          kind: 'expense',
          source: 'card',
          card_id: card.id,
          refund: true
        }
      }

      expect(response).to have_http_status(:created)

      body = JSON.parse(response.body)
      transaction = Transaction.find(body['id'])

      expect(transaction.value.to_d).to eq(BigDecimal('6.92'))
      expect(transaction.refund).to eq(true)
      expect(transaction.kind).to eq('expense')
      expect(transaction.source).to eq('card')
      expect(body['refund']).to eq(true)
      expect(body['signed_value']).to eq('-6.92')
    end

    it 'creates a cash expense with an active account from the current user' do
      account = create(:account, user: user, name: 'Carteira')

      post '/api/transactions', params: {
        transaction: {
          description: 'Despesa dinheiro',
          value: '10,00',
          date: Date.current,
          kind: 'expense',
          source: 'cash',
          account_id: account.id
        }
      }

      expect(response).to have_http_status(:created)

      body = JSON.parse(response.body)
      transaction = user.transactions.find(body['id'])
      expect(transaction.account).to eq(account)
      expect(body.dig('account', 'id')).to eq(account.id)
      expect(body.dig('account', 'name')).to eq('Carteira')
    end

    it 'creates a bank expense with an active account from the current user' do
      account = create(:account, user: user, name: 'Conta Corrente')

      post '/api/transactions', params: {
        transaction: {
          description: 'Despesa banco',
          value: '10,00',
          date: Date.current,
          kind: 'expense',
          source: 'bank',
          account_id: account.id
        }
      }

      expect(response).to have_http_status(:created)

      body = JSON.parse(response.body)
      expect(user.transactions.find(body['id']).account).to eq(account)
      expect(body.dig('account', 'name')).to eq('Conta Corrente')
    end

    it 'creates a new unpaid cash or bank expense without account' do
      post '/api/transactions', params: {
        transaction: {
          description: 'Despesa sem conta',
          value: '10,00',
          date: Date.current,
          kind: 'expense',
          source: 'cash'
        }
      }

      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)['account']).to be_nil
    end

    it 'creates a paid loose expense with one canonical transaction payment' do
      account = create(:account, user: user, initial_balance: 90)

      post '/api/transactions', params: {
        transaction: {
          description: 'Despesa já paga', value: '95,00', date: '2026-09-01',
          settled_on: '2026-09-03', settled_value: '90,00', kind: 'expense',
          source: 'bank', account_id: account.id, paid: true
        }
      }

      expect(response).to have_http_status(:created)
      transaction = Transaction.find(JSON.parse(response.body)['id'])
      expect(transaction).to have_attributes(paid: true, settled_on: nil, settled_value: nil)
      expect(transaction.transaction_payments).to contain_exactly(have_attributes(account: account, amount: 90.to_d, settled_on: Date.new(2026, 9, 3)))
    end

    it 'rolls back a paid create when the canonical payment cannot be recorded' do
      account = create(:account, user: user)
      allow_any_instance_of(Transactions::RegisterPaymentService).to receive(:call).and_raise(ActiveRecord::RecordInvalid.new(TransactionPayment.new))

      expect do
        post '/api/transactions', params: { transaction: { description: 'Falha atômica', value: 100, date: '2026-09-01', kind: 'expense', source: 'cash', account_id: account.id, paid: true } }
      end.not_to change(Transaction, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(TransactionPayment.count).to eq(0)
    end

    it 'rolls back a paid create when its account has insufficient funds' do
      account = create(:account, user: user, initial_balance: 90)

      expect do
        post '/api/transactions', params: { transaction: { description: 'Sem saldo', value: 100, date: '2026-09-01', kind: 'expense', source: 'cash', account_id: account.id, paid: true } }
      end.not_to change(Transaction, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body).fetch('error')).to include('Saldo insuficiente')
      expect(TransactionPayment.count).to eq(0)
      expect(Accounts::BalanceCalculator.call(account)).to eq(90.to_d)
    end

    it 'rejects a paid cash or bank expense without account' do
      post '/api/transactions', params: {
        transaction: {
          description: 'Despesa paga sem conta', value: '10,00', date: Date.current,
          kind: 'expense', source: 'bank', paid: true
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to include('Account é obrigatória para despesas sem cartão')
    end

    it 'rejects a cash or bank expense with an account from another user' do
      other_account = create(:account, user: create(:user))

      post '/api/transactions', params: {
        transaction: {
          description: 'Despesa cross user',
          value: '10,00',
          date: Date.current,
          kind: 'expense',
          source: 'bank',
          account_id: other_account.id
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to include('Account inválida')
      expect(user.transactions.where(description: 'DESPESA CROSS USER')).to be_empty
    end

    it 'rejects a cash or bank expense with an archived account' do
      account = create(:account, user: user, archived_at: Time.current)

      post '/api/transactions', params: {
        transaction: {
          description: 'Despesa conta arquivada',
          value: '10,00',
          date: Date.current,
          kind: 'expense',
          source: 'cash',
          account_id: account.id
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to include('Account não pode estar arquivada')
    end

    it 'rejects a cash or bank expense with a missing account' do
      post '/api/transactions', params: {
        transaction: {
          description: 'Despesa conta inexistente',
          value: '10,00',
          date: Date.current,
          kind: 'expense',
          source: 'bank',
          account_id: Account.maximum(:id).to_i + 10_000
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to include('Account inválida')
    end

    it 'rejects account_id on card expenses' do
      account = create(:account, user: user)
      card = create(:card, user: user)

      post '/api/transactions', params: {
        transaction: {
          description: 'Despesa cartao com conta',
          value: '10,00',
          date: Date.current,
          kind: 'expense',
          source: 'card',
          card_id: card.id,
          account_id: account.id
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to include('Account não deve existir para despesas no cartão')
    end

    it 'rejects installment refunds' do
      card = create(:card, user: user)

      post '/api/transactions', params: {
        transaction: {
          description: 'Uber - Nupay',
          value: '6,92',
          date: Date.current,
          kind: 'expense',
          source: 'card',
          card_id: card.id,
          refund: true,
          installment_number: 1,
          installments_count: 2
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to eq('Estorno não pode ser parcelado')
    end

    it 'rejects clear card statement payments as transactions' do
      card = create(:card, user: user)

      post '/api/transactions', params: {
        transaction: {
          description: 'Pagamento recebido para liberar limite',
          value: '1969,20',
          date: Date.current,
          kind: 'expense',
          source: 'card',
          card_id: card.id
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to include('pagamento de fatura deve ser registrado na tela de pagamentos')
    end

    it 'reprocesses classification when the description changes' do
      category = create(:category, user: user, name: 'Transporte')
      MerchantAlias.create!(
        user: user,
        normalized_merchant: 'UBER',
        category: category,
        confidence: 1.0,
        source: :user_override
      )

      transaction = user.transactions.create!(
        description: 'Loja XPTO Centro',
        value: 50,
        date: Date.current,
        kind: :expense,
        source: :cash,
        account: create(:account, user: user)
      )

      expect(transaction.classification_suggestions.pending.count).to eq(1)

      patch "/api/transactions/#{transaction.id}", params: {
        transaction: {
          description: 'Uber Trip 1234'
        }
      }

      expect(response).to have_http_status(:ok)

      body = JSON.parse(response.body)
      transaction.reload

      expect(transaction.category_id).to eq(category.id)
      expect(transaction.classification_suggestions.pending.count).to eq(0)
      expect(body.dig('classification', 'status')).to eq('classified')
      expect(body.dig('classification', 'category', 'id')).to eq(category.id)
      expect(body.dig('classification', 'suggestion')).to be_nil
    end

    it 'creates one pending suggestion for the whole installment group' do
      card = create(:card, user: user)

      post '/api/transactions', params: {
        transaction: {
          description: 'SMARTPHONE XPTO 10X',
          value: '199,90',
          date: Date.current,
          kind: 'expense',
          source: 'card',
          card_id: card.id,
          installment_number: 1,
          installments_count: 3
        }
      }

      expect(response).to have_http_status(:created)

      body = JSON.parse(response.body)
      group_id = body['installment_group_id']
      transactions = user.transactions.where(installment_group_id: group_id).order(:installment_number)
      suggestion_ids = transactions.map { |tx| tx.pending_classification_suggestion&.id }.uniq

      expect(group_id).to be_present
      expect(transactions.count).to eq(3)
      expect(ClassificationSuggestion.pending.where(financial_transaction_id: transactions.pluck(:id)).count).to eq(1)
      expect(suggestion_ids.size).to eq(1)
      expect(suggestion_ids.first).to be_present
      expect(body['transactions'].size).to eq(3)
      expect(body['transactions'].map { |tx| tx.dig('classification', 'status') }.uniq).to eq(['suggestion_pending'])
      expect(body['transactions'].map { |tx| tx.dig('classification', 'suggestion', 'id') }.uniq.size).to eq(1)
    end

    it 'preserves common origin fields while advancing installment dates and statements' do
      card = create(:card, user: user, due_day: 15, closing_day: 8)

      post '/api/transactions', params: {
        transaction: {
          description: 'Notebook parcelado',
          value: '150,00',
          date: '2026-01-10',
          purchase_date: '2026-01-05',
          original_value: '175,00',
          kind: 'expense',
          source: 'card',
          card_id: card.id,
          installment_number: 1,
          installments_count: 3
        }
      }

      expect(response).to have_http_status(:created)

      installments = user.transactions.where(installment_group_id: JSON.parse(response.body)['installment_group_id']).order(:installment_number)
      expect(installments.pluck(:date)).to eq([Date.new(2026, 1, 10), Date.new(2026, 2, 10), Date.new(2026, 3, 10)])
      expect(installments.pluck(:billing_statement)).to eq([Date.new(2026, 2, 1), Date.new(2026, 3, 1), Date.new(2026, 4, 1)])
      expect(installments.pluck(:purchase_date).uniq).to eq([Date.new(2026, 1, 5)])
      expect(installments.pluck(:original_value).uniq).to eq([BigDecimal('175.00')])
      expect(installments.pluck(:value).uniq).to eq([BigDecimal('150.00')])
    end

    it 'propagates auto-classification to every installment in the group' do
      card = create(:card, user: user)
      category = create(:category, user: user, name: 'Transporte')
      MerchantAlias.create!(
        user: user,
        normalized_merchant: 'UBER',
        category: category,
        confidence: 1.0,
        source: :user_override
      )

      post '/api/transactions', params: {
        transaction: {
          description: 'Uber Trip 1234',
          value: '55,00',
          date: Date.current,
          kind: 'expense',
          source: 'card',
          card_id: card.id,
          installment_number: 1,
          installments_count: 2
        }
      }

      expect(response).to have_http_status(:created)

      body = JSON.parse(response.body)
      transactions = user.transactions.where(installment_group_id: body['installment_group_id']).order(:installment_number)

      expect(transactions.count).to eq(2)
      expect(transactions.pluck(:category_id).uniq).to eq([category.id])
      expect(ClassificationSuggestion.pending.where(financial_transaction_id: transactions.pluck(:id)).count).to eq(0)
      expect(body['transactions'].map { |tx| tx.dig('classification', 'status') }.uniq).to eq(['classified'])
      expect(body['transactions'].map { |tx| tx.dig('classification', 'category', 'id') }.uniq).to eq([category.id])
    end
  end

  describe 'GET /api/transactions' do
    it 'paginates the filtered collection with stable ordering and metadata' do
      transactions = 30.times.map do |index|
        create(:transaction, user: user, card: nil, source: :cash, date: Date.new(2026, 3, 20), description: "Item #{index}")
      end

      get '/api/transactions', params: { month: 3, year: 2026, page: 2, per_page: 25 }
      body = JSON.parse(response.body)
      metrics = request_metrics { get '/api/transactions', params: { month: 3, year: 2026, page: 1, per_page: 25 } }

      warn("PERFORMANCE_1C_METRICS #{metrics.inspect}") if ENV['PERFORMANCE_1C_METRICS'] == '1'
      expect(body['pagination']).to eq('page' => 2, 'per_page' => 25, 'total_count' => 30, 'total_pages' => 2)
      expect(body['transactions'].map { |transaction| transaction['id'] }).to eq(transactions.first(5).reverse.map(&:id))
      expect(metrics[:select]).to be <= 12
    end

    it 'uses safe pagination defaults and caps per_page at 100' do
      2.times { |index| create(:transaction, user: user, card: nil, source: :cash, date: Date.new(2026, 3, 10) + index.days) }

      get '/api/transactions', params: { month: 3, year: 2026, page: 0, per_page: 0 }
      expect(JSON.parse(response.body)['pagination']).to include('page' => 1, 'per_page' => 25)

      get '/api/transactions', params: { month: 3, year: 2026, per_page: 999 }
      expect(JSON.parse(response.body)['pagination']).to include('per_page' => 100)
    end

    it 'does not return archived transactions' do
      visible = create(:transaction, user: user, card: nil, source: :cash, date: Date.new(2026, 3, 10), value: 80)
      hidden = create(:transaction, user: user, card: nil, source: :cash, date: Date.new(2026, 3, 11), value: 50, archived_at: Time.current)

      get '/api/transactions', params: { month: 3, year: 2026 }

      expect(response).to have_http_status(:ok)

      body = JSON.parse(response.body)
      expect(body['transactions'].map { |transaction| transaction['id'] }).to eq([visible.id])
      expect(body['transactions'].map { |transaction| transaction['id'] }).not_to include(hidden.id)
      expect(body['pagination']).to include('page' => 1, 'per_page' => 25, 'total_count' => 1, 'total_pages' => 1)
    end

    it 'keeps association queries bounded as the response grows' do
      category = create(:category, user: user)
      card = create(:card, user: user)
      account = create(:account, user: user)

      6.times do |index|
        create(:transaction, user: user, card: card, category: category, description: "Card #{index}")
        cash_expense = create(:transaction, user: user, card: nil, account: account, category: category, source: :cash, paid: false, description: "Cash #{index}")
        TransactionPayment.create!(
          financial_transaction: cash_expense,
          account: account,
          amount: 10,
          settled_on: Date.new(2026, 3, 10)
        )
      end

      queries = select_query_count { get '/api/transactions', params: { per_page: 50 } }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['transactions'].size).to eq(12)
      expect(queries).to be <= 12
    end

    it 'keeps the newest pending suggestion from an installment group outside the response page' do
      card = create(:card, user: user)
      group_id = SecureRandom.uuid
      older_installment = create(
        :transaction,
        user: user,
        card: card,
        installment_group_id: group_id,
        installment_number: 1,
        installments_count: 2,
        date: Date.current - 1.month
      )
      visible_installment = create(
        :transaction,
        user: user,
        card: card,
        installment_group_id: group_id,
        installment_number: 2,
        installments_count: 2,
        date: Date.current
      )
      older_installment.classification_suggestions.delete_all
      visible_installment.classification_suggestions.delete_all
      suggestion = create(:classification_suggestion, user: user, financial_transaction: older_installment)

      get '/api/transactions', params: { per_page: 1 }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)['transactions'].first
      expect(body['id']).to eq(visible_installment.id)
      expect(body.dig('classification', 'status')).to eq('suggestion_pending')
      expect(body.dig('classification', 'suggestion', 'id')).to eq(suggestion.id)
    end
  end

  describe 'PATCH /api/transactions/:id' do
    it 'updates the friendly title independently from the original description' do
      transaction = create(:transaction, user: user, card: nil, source: :cash, description: 'PAG*MAQUININHA 1234')

      patch "/api/transactions/#{transaction.id}", params: {
        transaction: { friendly_title: 'Presente da Maria' }
      }

      expect(response).to have_http_status(:ok)
      expect(transaction.reload.description).to eq('PAG*MAQUININHA 1234')
      expect(transaction.friendly_title).to eq('Presente da Maria')
      expect(JSON.parse(response.body)['friendly_title']).to eq('Presente da Maria')
    end

    it 'updates the selected transaction through the API' do
      card = create(:card, user: user, name: 'Nubank', due_day: 15, closing_day: 8)
      transaction = create(:transaction, user: user, card: nil, source: :cash, date: Date.new(2026, 3, 10), value: 80, description: 'Uber')
      original_value = transaction.original_value

      patch "/api/transactions/#{transaction.id}", params: {
        transaction: {
          description: 'Mercado do bairro',
          value: '125,90',
          date: '2026-03-15',
          source: 'card',
          card_id: card.id,
          account_id: nil,
          paid: true,
          note: 'Compra mensal'
        }
      }

      expect(response).to have_http_status(:ok)

      transaction.reload
      body = JSON.parse(response.body)
      expect(transaction.description).to eq('MERCADO DO BAIRRO')
      expect(transaction.value.to_d).to eq(BigDecimal('125.9'))
      expect(transaction.original_value).to eq(original_value)
      expect(transaction.source).to eq('card')
      expect(transaction.card_id).to eq(card.id)
      expect(transaction.billing_statement).to eq(Date.new(2026, 4, 1))
      expect(transaction.paid).to eq(true)
      expect(transaction.note).to eq('Compra mensal')
      expect(body['id']).to eq(transaction.id)
      expect(body['card']['id']).to eq(card.id)
      expect(body['account']).to be_nil
    end

    it 'keeps a legacy cash expense without account editable when account-relevant fields do not change' do
      transaction = build(:transaction, user: user, card: nil, account: nil, source: :cash, description: 'Despesa legada')
      transaction.save!(validate: false)

      patch "/api/transactions/#{transaction.id}", params: {
        transaction: {
          description: 'Despesa legada ajustada',
          note: 'Apenas observação'
        }
      }

      expect(response).to have_http_status(:ok)

      transaction.reload
      body = JSON.parse(response.body)
      expect(transaction.account_id).to be_nil
      expect(transaction.description).to eq('DESPESA LEGADA AJUSTADA')
      expect(transaction.note).to eq('Apenas observação')
      expect(body['account']).to be_nil
    end

    it 'allows converting an unpaid card expense to cash or bank without account' do
      card = create(:card, user: user)
      transaction = create(:transaction, user: user, card: card, source: :card)

      patch "/api/transactions/#{transaction.id}", params: {
        transaction: {
          source: 'cash',
          card_id: nil
        }
      }

      expect(response).to have_http_status(:ok)
      expect(transaction.reload).to be_cash
      expect(transaction.card_id).to be_nil
      expect(transaction.billing_statement).to be_nil
      expect(transaction.account_id).to be_nil
    end

    it 'rejects changing a card expense to cash or bank while retaining its card' do
      card = create(:card, user: user)
      transaction = create(:transaction, user: user, card: card, source: :card)

      %w[cash bank].each do |source|
        patch "/api/transactions/#{transaction.id}", params: { transaction: { source: source } }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body).fetch('error')).to include('Card não deve existir para origem dinheiro ou banco')
        expect(transaction.reload).to be_card
        expect(transaction.card_id).to eq(card.id)
      end
    end

    it 'does not update a transaction with a category from another user' do
      other_user = create(:user)
      other_category = create(:category, user: other_user)
      transaction = create(:transaction, user: user, card: nil, category: nil, source: :cash)

      patch "/api/transactions/#{transaction.id}", params: {
        transaction: { category_id: other_category.id }
      }

      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)).to eq('error' => 'Not found')
      expect(transaction.reload.category_id).to be_nil
    end

    it 'routes a legacy paid update through the canonical payment guard' do
      account = create(:account, user: user, initial_balance: 90)
      transaction = create(:transaction, user: user, account: account, card: nil, source: :cash, value: 100, paid: false)

      expect do
        patch "/api/transactions/#{transaction.id}", params: { transaction: { paid: true, settled_on: '2026-09-02', settled_value: 100 } }
      end.not_to change(TransactionPayment, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body).fetch('error')).to include('Saldo insuficiente')
      expect(transaction.reload).to have_attributes(paid: false, settled_on: nil, settled_value: nil)
      expect(Accounts::BalanceCalculator.call(account)).to eq(90.to_d)
    end

    it 'keeps legacy reopening available but blocks structural changes after payments' do
      account = create(:account, user: user)
      legacy = create(
        :transaction,
        user: user,
        account: account,
        card: nil,
        source: :cash,
        paid: true,
        settled_on: Date.new(2026, 9, 2),
        settled_value: 100
      )
      paid_with_payment = create(:transaction, user: user, account: account, card: nil, source: :cash, value: 100)
      TransactionPayment.create!(financial_transaction: paid_with_payment, account: account, amount: 100, settled_on: Date.new(2026, 9, 2))
      paid_with_payment.update!(paid: true)

      patch "/api/transactions/#{legacy.id}", params: { transaction: { paid: false } }

      expect(response).to have_http_status(:ok)
      expect(legacy.reload).to have_attributes(paid: false, settled_on: nil, settled_value: nil)

      patch "/api/transactions/#{paid_with_payment.id}", params: { transaction: { value: 90, paid: false } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body).fetch('error')).to include('pagamentos')
      expect(paid_with_payment.reload).to have_attributes(value: 100.to_d, paid: true)
    end

    it 'allows planned-account and metadata changes without mutating payment history' do
      payment_account = create(:account, user: user, name: 'Conta realizada')
      planned_account = create(:account, user: user, name: 'Conta planejada')
      transaction = create(:transaction, user: user, account: payment_account, card: nil, source: :cash, value: 100)
      payment = TransactionPayment.create!(
        financial_transaction: transaction,
        account: payment_account,
        amount: 30,
        settled_on: Date.new(2026, 9, 5)
      )

      patch "/api/transactions/#{transaction.id}", params: {
        transaction: { account_id: planned_account.id, note: 'Planejamento revisado', responsible: 'Ana' }
      }

      expect(response).to have_http_status(:ok)
      expect(transaction.reload).to have_attributes(account: planned_account, note: 'Planejamento revisado', responsible: 'ANA')
      expect(payment.reload).to have_attributes(account: payment_account, amount: 30.to_d, settled_on: Date.new(2026, 9, 5))
    end
  end

  describe 'DELETE /api/transactions/:id' do
    it 'archives the transaction instead of deleting it' do
      transaction = create(:transaction, user: user, card: nil, source: :cash, date: Date.new(2026, 3, 10), value: 80)

      delete "/api/transactions/#{transaction.id}"

      expect(response).to have_http_status(:no_content)

      transaction.reload
      expect(transaction.archived_at).to be_present
    end

    it 'blocks archiving a transaction with payment history' do
      account = create(:account, user: user)
      transaction = create(:transaction, user: user, account: account, card: nil, source: :cash)
      payment = TransactionPayment.create!(financial_transaction: transaction, account: account, amount: 20, settled_on: Date.new(2026, 9, 5))

      delete "/api/transactions/#{transaction.id}"

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body).fetch('error')).to include('pagamentos')
      expect(transaction.reload.archived_at).to be_nil
      expect(payment.reload).to be_present
    end
  end
end
