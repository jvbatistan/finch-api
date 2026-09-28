require "rails_helper"

RSpec.describe "Api::Payments", type: :request do
  let(:user) { create(:user) }

  before do
    sign_in user
  end

  def sql_metrics
    metrics = Hash.new(0)
    callback = lambda do |_name, _started, _finished, _unique_id, payload|
      next if payload[:cached]

      operation = payload[:sql].to_s[/\A(?:\s*\/\*.*?\*\/\s*)?(SELECT|INSERT|UPDATE|DELETE)/im, 1]
      metrics[operation.downcase.to_sym] += 1 if operation
    end

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    metrics[:duration_ms] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1_000).round(1)
    metrics
  end

  describe "GET /api/payments" do
    it "keeps multi-card reads within a bounded number of queries and performs no redundant writes" do
      account = create(:account, user: user, initial_balance: 80)

      6.times do |index|
        card = create(:card, user: user, name: "Card #{index}", due_day: 15, closing_day: 8)
        create(:transaction, user: user, card: card, source: :card, date: Date.new(2026, 3, 7), value: 20 + index)
        statement = card.sync_statement!(3, 2026)
        create(:card_statement_payment, card_statement: statement, account: account, amount: 5, paid_at: Time.zone.local(2026, 3, 10, 12))
      end

      metrics = sql_metrics { get "/api/payments", params: { month: 3, year: 2026 } }

      expect(response).to have_http_status(:ok)
      aggregate_failures(metrics.inspect) do
        expect(metrics[:select]).to be <= 12
        expect(metrics[:insert]).to eq(0)
        expect(metrics[:update]).to eq(0)
        expect(metrics[:delete]).to eq(0)
      end
    end

    it "returns statements and loose expenses for the selected period" do
      card = create(:card, user: user, name: 'Nubank', due_day: 15, closing_day: 8)
      create(:transaction, user: user, card: card, source: :card, date: Date.new(2026, 3, 7), value: 120)
      create(:transaction, user: user, card: card, source: :card, date: Date.new(2026, 3, 7), value: 20, refund: true, description: "Estorno Uber")
      create(:transaction, user: user, card: nil, source: :cash, date: Date.new(2026, 3, 10), value: 80)
      create(:transaction, user: user, card: nil, source: :cash, date: Date.new(2026, 4, 10), value: 50)

      get "/api/payments", params: { month: 3, year: 2026 }

      expect(response).to have_http_status(:ok)

      body = JSON.parse(response.body)
      expect(body["period"]).to eq({ "month" => 3, "year" => 2026 })
      expect(body["statements"].size).to eq(1)
      expect(body["statements"].first.dig("card", "name")).to eq("NUBANK")
      expect(body["statements"].first["total_amount"]).to eq("100.0")
      expect(body["statements"].first["remaining_amount"]).to eq("100.0")
      expect(body["statements"].first["ignored_at"]).to eq(nil)
      expect(body["statements"].first["id"]).to be_nil
      expect(card.card_statements).to be_empty
      expect(body["loose_expenses"]["transactions_count"]).to eq(1)
      expect(body["loose_expenses"]["total_amount"]).to eq("80.0")
      expect(body["ignored_payments"]["statements_count"]).to eq(0)
      expect(body["ignored_payments"]["loose_expenses"]["transactions_count"]).to eq(0)
    end

    it "materializes a virtual statement only when a payment is explicitly requested" do
      card = create(:card, user: user, name: "Nubank", due_day: 15, closing_day: 8)
      account = create(:account, user: user, initial_balance: 200)
      create(:transaction, user: user, card: card, source: :card, date: Date.new(2026, 3, 7), value: 120)

      expect do
        post "/api/payments/card_statements/pay", params: {
          card_id: card.id,
          billing_statement: "2026-03-15",
          account_id: account.id,
          amount: 120
        }
      end.to change(CardStatement, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to include("paid" => true, "remaining_amount" => "0.0")
    end

    it "adds regular card expenses and subtracts card refunds in the statement total" do
      card = create(:card, user: user, name: 'Nubank', due_day: 15, closing_day: 8)
      create(:transaction, user: user, card: card, source: :card, date: Date.new(2026, 3, 7), value: 120)
      create(:transaction, user: user, card: card, source: :card, date: Date.new(2026, 3, 7), value: 6.92, refund: true)

      get "/api/payments", params: { month: 3, year: 2026 }

      expect(response).to have_http_status(:ok)

      body = JSON.parse(response.body)
      expect(body["statements"].first["total_amount"]).to eq("113.08")
    end

    it "keeps both Uber purchases and offsets only the explicit refund" do
      card = create(:card, user: user, name: 'Nubank', due_day: 15, closing_day: 8)
      create(:transaction, user: user, card: card, source: :card, date: Date.new(2026, 6, 12), value: '-11,02', refund: false, description: 'Uber')
      create(:transaction, user: user, card: card, source: :card, date: Date.new(2026, 6, 12), value: '-6,91', refund: false, description: 'Uber')
      create(:transaction, user: user, card: card, source: :card, date: Date.new(2026, 6, 12), value: '-6,91', refund: true, description: 'Estorno Uber')

      get "/api/payments", params: { month: 7, year: 2026 }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["statements"].first["total_amount"]).to eq("11.02")
    end

    it "reproduces the supplied Nubank July statement items without statement payments" do
      card = create(:card, user: user, name: 'Nubank', due_day: 15, closing_day: 1)
      entries = [
        ['Uber - NuPay', 6.92, false], ['IOF de compra internacional', 0.93, false],
        ['Kick Streaming', 26.79, false], ['99 - NuPay', 6.30, false],
        ['Uber - NuPay', 4.84, false], ['Uber - NuPay', 3.63, true],
        ['99 - NuPay', 3.99, false], ['99 - NuPay', 5.28, false],
        ['Uber - NuPay', 6.91, true], ['Uber - NuPay', 11.02, false],
        ['Uber - NuPay', 6.91, false], ['Dl*Google Google', 12.50, false],
        ['Pix no Crédito - Jamil Sousa de Oliveira', 45.30, false],
        ['Pix no Crédito - Nayara Pereira de Freitas - 1/4', 329.03, false],
        ['Pix no Crédito - Marcos Aurelio', 84.34, false], ['Uber - NuPay', 9.95, false],
        ['EBW*Spotify - NuPay', 40.90, false], ['99 - NuPay', 13.80, false],
        ['99 - NuPay', 6.40, false], ['Uber - NuPay', 6.92, false],
        ['Uber - NuPay', 6.92, true], ['Uber - NuPay', 6.72, true],
        ['Uber - NuPay', 5.87, false], ['Uber - NuPay', 6.72, false],
        ['Dm *Twitch', 9.90, false], ['Uber - NuPay', 6.90, false],
        ['IOF de compra internacional', 0.36, false], ['Twitch', 10.34, false],
        ['Galeteria Aguiar', 78.00, false], ["Barber'In", 262.00, false],
        ['Uber - NuPay', 11.81, false], ['Uber - NuPay', 6.92, false],
        ['99 - NuPay', 9.52, false], ['Apple.Com/Bill', 5.90, false],
        ['Moto Sao Francisco - Parcela 6/6', 55.00, false],
        ['58367492patricia - Parcela 3/10', 175.00, false],
        ['Jim.Com* Bs Treinamen - Parcela 5/10', 280.00, false],
        ['Zp *Fbio Lopes - Parcela 6/10', 58.86, false]
      ]

      entries.each do |description, value, refund|
        create(
          :transaction,
          user: user,
          card: card,
          source: :card,
          date: Date.new(2026, 6, 20),
          value: value,
          refund: refund,
          description: description
        )
      end

      statement = card.sync_statement!(7, 2026)
      create(
        :card_statement_payment,
        card_statement: statement,
        amount: 30,
        paid_at: Time.zone.local(2026, 6, 18, 12),
        description: 'Pagamento recebido'
      )

      get "/api/payments", params: { month: 7, year: 2026 }

      expect(response).to have_http_status(:ok)
      statement_json = JSON.parse(response.body)["statements"].first
      expect(statement_json["total_amount"]).to eq("1581.04")
      expect(statement_json["paid_amount"]).to eq("30.0")
      expect(statement_json["remaining_amount"]).to eq("1551.04")
    end

    it "uses statement payments as paid amount without reducing expenses" do
      card = create(:card, user: user, name: 'Nubank', due_day: 15, closing_day: 8)
      create(:transaction, user: user, card: card, source: :card, date: Date.new(2026, 3, 7), value: 100)
      statement = card.sync_statement!(3, 2026)
      create(:card_statement_payment, card_statement: statement, amount: 30, paid_at: Time.zone.local(2026, 3, 10, 12))

      get "/api/payments", params: { month: 3, year: 2026 }

      expect(response).to have_http_status(:ok)

      body = JSON.parse(response.body)
      statement_json = body["statements"].first
      expect(statement_json["total_amount"]).to eq("100.0")
      expect(statement_json["paid_amount"]).to eq("30.0")
      expect(statement_json["remaining_amount"]).to eq("70.0")
      expect(statement_json["payment_status"]).to eq("partially_paid")
      expect(statement_json["payments"].first["amount"]).to eq("30.0")
      expect(statement_json["payments"].first["account"]).to be_nil
    end

    it "ignores archived transactions in statements and loose expenses" do
      card = create(:card, user: user, name: "Nubank", due_day: 15, closing_day: 8)
      create(:transaction, user: user, card: card, source: :card, date: Date.new(2026, 3, 7), value: 120, archived_at: Time.current)
      create(:transaction, user: user, card: nil, source: :cash, date: Date.new(2026, 3, 10), value: 80, archived_at: Time.current)

      get "/api/payments", params: { month: 3, year: 2026 }

      expect(response).to have_http_status(:ok)

      body = JSON.parse(response.body)
      expect(body["statements"].size).to eq(1)
      expect(body["statements"].first["total_amount"]).to eq("0.0")
      expect(body["statements"].first["remaining_amount"]).to eq("0.0")
      expect(body["statements"].first["transactions_count"]).to eq(0)
      expect(body["loose_expenses"]["transactions_count"]).to eq(0)
      expect(body["loose_expenses"]["total_amount"]).to eq("0.0")
    end

    it "ignores loose expenses removed from the payment flow" do
      create(:transaction, user: user, card: nil, source: :cash, date: Date.new(2026, 3, 10), value: 80, payment_ignored_at: Time.current)
      create(:transaction, user: user, card: nil, source: :cash, date: Date.new(2026, 3, 11), value: 50)

      get "/api/payments", params: { month: 3, year: 2026 }

      expect(response).to have_http_status(:ok)

      body = JSON.parse(response.body)
      expect(body["loose_expenses"]["transactions_count"]).to eq(1)
      expect(body["loose_expenses"]["total_amount"]).to eq("50.0")
      expect(body["loose_expenses"]["transactions"].map { |transaction| transaction["value"] }).to eq(["50.0"])
      expect(body["ignored_payments"]["loose_expenses"]["transactions_count"]).to eq(1)
      expect(body["ignored_payments"]["loose_expenses"]["total_amount"]).to eq("80.0")
      expect(body["ignored_payments"]["loose_expenses"]["transactions"].first["payment_ignored_at"]).to be_present
    end

    it "returns ignored statements for the selected period" do
      card = create(:card, user: user, name: 'Nubank', due_day: 15, closing_day: 8)
      create(:transaction, user: user, card: card, source: :card, date: Date.new(2026, 3, 7), value: 120, paid: false)
      statement = card.sync_statement!(3, 2026)
      statement.ignore_for_payment!

      get "/api/payments", params: { month: 3, year: 2026 }

      expect(response).to have_http_status(:ok)

      body = JSON.parse(response.body)
      expect(body["statements"]).to eq([])
      expect(body["ignored_payments"]["statements_count"]).to eq(1)
      expect(body["ignored_payments"]["statements_total_amount"]).to eq("120.0")
      expect(body["ignored_payments"]["statements"].first.dig("card", "name")).to eq("NUBANK")
      expect(body["ignored_payments"]["statements"].first["ignored_at"]).to be_present
    end
  end

  describe "POST /api/payments/card_statements/:id/pay" do
    it "creates a statement payment for the remaining amount and marks its transactions as paid" do
      card = create(:card, user: user, name: 'Nubank', due_day: 15, closing_day: 8)
      account = create(:account, user: user, name: 'Conta Corrente', initial_balance: 120)
      transaction = create(:transaction, user: user, card: card, source: :card, date: Date.new(2026, 3, 7), value: 120, paid: false)
      statement = card.sync_statement!(3, 2026)

      expect do
        post "/api/payments/card_statements/#{statement.id}/pay", params: { account_id: account.id }
      end.not_to change(Transaction, :count)

      expect(response).to have_http_status(:ok)

      transaction.reload
      statement.reload
      body = JSON.parse(response.body)
      expect(statement.card_statement_payments.count).to eq(1)
      expect(statement.card_statement_payments.first.amount.to_d).to eq(BigDecimal('120'))
      expect(statement.card_statement_payments.first.account).to eq(account)
      expect(statement.paid?).to eq(true)
      expect(transaction.paid).to eq(true)
      expect(body["paid_amount"]).to eq("120.0")
      expect(body["remaining_amount"]).to eq("0.0")
      expect(body["payments"].first["account"]).to eq("id" => account.id, "name" => "Conta Corrente")
    end

    it "accepts a partial statement payment below the remaining amount" do
      card = create(:card, user: user, name: 'Nubank', due_day: 15, closing_day: 8)
      account = create(:account, user: user, initial_balance: 40.50)
      create(:transaction, user: user, card: card, source: :card, date: Date.new(2026, 3, 7), value: 120, paid: false)
      statement = card.sync_statement!(3, 2026)

      post "/api/payments/card_statements/#{statement.id}/pay", params: { amount: "40.50", account_id: account.id }

      expect(response).to have_http_status(:ok)

      statement.reload
      body = JSON.parse(response.body)
      expect(statement.card_statement_payments.count).to eq(1)
      expect(statement.card_statement_payments.first.amount.to_d).to eq(BigDecimal('40.50'))
      expect(statement.card_statement_payments.first.account).to eq(account)
      expect(statement.paid_amount.to_d).to eq(BigDecimal('40.50'))
      expect(statement.remaining_amount).to eq(BigDecimal('79.5'))
      expect(statement.paid?).to eq(false)
      expect(body["paid_amount"]).to eq("40.5")
      expect(body["remaining_amount"]).to eq("79.5")
      expect(body["payment_status"]).to eq("partially_paid")
    end

    it 'rejects a statement payment that exceeds the selected account balance without mutating the statement' do
      card = create(:card, user: user, name: 'Nubank', due_day: 15, closing_day: 8)
      account = create(:account, user: user, initial_balance: 40)
      transaction = create(:transaction, user: user, card: card, source: :card, date: Date.new(2026, 3, 7), value: 120, paid: false)
      statement = card.sync_statement!(3, 2026)

      expect do
        post "/api/payments/card_statements/#{statement.id}/pay", params: { amount: '50', account_id: account.id }
      end.not_to change(CardStatementPayment, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body).fetch('error')).to include('Saldo insuficiente')
      expect(statement.reload).to have_attributes(paid_amount: 0.to_d, paid_at: nil)
      expect(transaction.reload.paid).to eq(false)
      expect(Accounts::BalanceCalculator.call(account)).to eq(40.to_d)
    end

    it "accepts a payment equal to the remaining amount" do
      card = create(:card, user: user, name: 'Nubank', due_day: 15, closing_day: 8)
      account = create(:account, user: user, initial_balance: 90)
      transaction = create(:transaction, user: user, card: card, source: :card, date: Date.new(2026, 3, 7), value: 120, paid: false)
      statement = card.sync_statement!(3, 2026)
      create(:card_statement_payment, card_statement: statement, amount: 30, paid_at: Time.zone.local(2026, 3, 10, 12))

      post "/api/payments/card_statements/#{statement.id}/pay", params: { amount: "90", account_id: account.id }

      expect(response).to have_http_status(:ok)

      transaction.reload
      statement.reload
      body = JSON.parse(response.body)
      expect(statement.card_statement_payments.count).to eq(2)
      expect(statement.paid_amount.to_d).to eq(BigDecimal('120'))
      expect(statement.remaining_amount).to eq(BigDecimal('0'))
      expect(statement.paid?).to eq(true)
      expect(transaction.paid).to eq(true)
      expect(body["paid_amount"]).to eq("120.0")
      expect(body["remaining_amount"]).to eq("0.0")
      expect(body["payment_status"]).to eq("paid")
    end

    it "rejects a payment greater than the remaining amount without creating a payment" do
      card = create(:card, user: user, name: 'Nubank', due_day: 15, closing_day: 8)
      account = create(:account, user: user)
      create(:transaction, user: user, card: card, source: :card, date: Date.new(2026, 3, 7), value: 120, paid: false)
      statement = card.sync_statement!(3, 2026)
      create(:card_statement_payment, card_statement: statement, amount: 30, paid_at: Time.zone.local(2026, 3, 10, 12))

      expect do
        post "/api/payments/card_statements/#{statement.id}/pay", params: { amount: "91", account_id: account.id }
      end.not_to change(CardStatementPayment, :count)

      statement.reload
      body = JSON.parse(response.body)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(body["error"]).to eq("Pagamento excede o saldo restante da fatura. Saldo atual: 90.0")
      expect(statement.paid_amount.to_d).to eq(BigDecimal('30'))
      expect(statement.remaining_amount).to eq(BigDecimal('90'))
    end

    it "rejects malformed, zero and negative payment amounts without creating a payment" do
      card = create(:card, user: user, due_day: 15, closing_day: 8)
      account = create(:account, user: user)
      create(:transaction, user: user, card: card, source: :card, date: Date.new(2026, 3, 7), value: 120)
      statement = card.sync_statement!(3, 2026)

      ["abc", "0", "-1", "1.234"].each do |amount|
        expect do
          post "/api/payments/card_statements/#{statement.id}/pay", params: { amount: amount, account_id: account.id }
        end.not_to change(CardStatementPayment, :count)

        expect(response).to have_http_status(:unprocessable_entity)
      end
    end

    it "does not accept another payment for a fully paid statement" do
      card = create(:card, user: user, name: 'Nubank', due_day: 15, closing_day: 8)
      account = create(:account, user: user)
      create(:transaction, user: user, card: card, source: :card, date: Date.new(2026, 3, 7), value: 120, paid: false)
      statement = card.sync_statement!(3, 2026)
      create(:card_statement_payment, card_statement: statement, amount: 120, paid_at: Time.zone.local(2026, 3, 10, 12))

      expect do
        post "/api/payments/card_statements/#{statement.id}/pay", params: { account_id: account.id }
      end.not_to change(CardStatementPayment, :count)

      statement.reload
      body = JSON.parse(response.body)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(body["error"]).to eq("Fatura já está quitada.")
      expect(statement.paid_amount.to_d).to eq(BigDecimal('120'))
      expect(statement.remaining_amount).to eq(BigDecimal('0'))
    end

    it "requires account for a statement payment" do
      card = create(:card, user: user, name: 'Nubank', due_day: 15, closing_day: 8)
      create(:transaction, user: user, card: card, source: :card, date: Date.new(2026, 3, 7), value: 120, paid: false)
      statement = card.sync_statement!(3, 2026)

      expect do
        post "/api/payments/card_statements/#{statement.id}/pay"
      end.not_to change(CardStatementPayment, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to eq("Conta é obrigatória para pagar fatura.")
    end

    it "rejects an account from another user without creating a payment" do
      card = create(:card, user: user, name: 'Nubank', due_day: 15, closing_day: 8)
      other_account = create(:account, user: create(:user))
      create(:transaction, user: user, card: card, source: :card, date: Date.new(2026, 3, 7), value: 120, paid: false)
      statement = card.sync_statement!(3, 2026)

      expect do
        post "/api/payments/card_statements/#{statement.id}/pay", params: { account_id: other_account.id }
      end.not_to change(CardStatementPayment, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to eq("Conta não encontrada.")
    end

    it "rejects an archived account without creating a payment" do
      card = create(:card, user: user, name: 'Nubank', due_day: 15, closing_day: 8)
      account = create(:account, user: user, archived_at: Time.current)
      create(:transaction, user: user, card: card, source: :card, date: Date.new(2026, 3, 7), value: 120, paid: false)
      statement = card.sync_statement!(3, 2026)

      expect do
        post "/api/payments/card_statements/#{statement.id}/pay", params: { account_id: account.id }
      end.not_to change(CardStatementPayment, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to eq("Conta não encontrada.")
    end

    it "rejects a missing account without creating a payment" do
      card = create(:card, user: user, name: 'Nubank', due_day: 15, closing_day: 8)
      create(:transaction, user: user, card: card, source: :card, date: Date.new(2026, 3, 7), value: 120, paid: false)
      statement = card.sync_statement!(3, 2026)

      expect do
        post "/api/payments/card_statements/#{statement.id}/pay", params: { account_id: Account.maximum(:id).to_i + 10_000 }
      end.not_to change(CardStatementPayment, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to eq("Conta não encontrada.")
    end

    it "does not allow paying a statement from another user" do
      other_user = create(:user)
      other_card = create(:card, user: other_user, name: 'Inter', due_day: 15, closing_day: 8)
      create(:transaction, user: other_user, card: other_card, source: :card, date: Date.new(2026, 3, 7), value: 120, paid: false)
      statement = other_card.sync_statement!(3, 2026)
      account = create(:account, user: user)

      expect do
        post "/api/payments/card_statements/#{statement.id}/pay", params: { account_id: account.id }
      end.not_to change(CardStatementPayment, :count)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/payments/card_statements/:id/ignore" do
    it "marks a statement as ignored for the selected period" do
      card = create(:card, user: user, name: 'Nubank', due_day: 15, closing_day: 8)
      create(:transaction, user: user, card: card, source: :card, date: Date.new(2026, 3, 7), value: 120, paid: false)
      statement = card.sync_statement!(3, 2026)

      post "/api/payments/card_statements/#{statement.id}/ignore", params: { month: 3, year: 2026 }

      expect(response).to have_http_status(:ok)

      statement.reload
      body = JSON.parse(response.body)
      expect(statement.ignored_at).to be_present
      expect(body["ignored_at"]).to be_present
    end

    it "returns not found when the statement is outside the selected period" do
      card = create(:card, user: user, name: 'Nubank', due_day: 15, closing_day: 8)
      create(:transaction, user: user, card: card, source: :card, date: Date.new(2026, 4, 7), value: 120, paid: false)
      statement = card.sync_statement!(4, 2026)

      post "/api/payments/card_statements/#{statement.id}/ignore", params: { month: 3, year: 2026 }

      expect(response).to have_http_status(:not_found)

      statement.reload
      body = JSON.parse(response.body)
      expect(statement.ignored_at).to eq(nil)
      expect(body["error"]).to eq("Fatura não encontrada para o período selecionado.")
    end

    it "hides ignored statements from the payments overview" do
      card = create(:card, user: user, name: 'Nubank', due_day: 15, closing_day: 8)
      create(:transaction, user: user, card: card, source: :card, date: Date.new(2026, 3, 7), value: 120, paid: false)
      statement = card.sync_statement!(3, 2026)
      statement.ignore_for_payment!

      get "/api/payments", params: { month: 3, year: 2026 }

      expect(response).to have_http_status(:ok)

      body = JSON.parse(response.body)
      expect(body["statements"]).to eq([])
    end
  end

  describe "POST /api/payments/loose_expenses/pay" do
    it "marks the loose expenses of the period as paid" do
      account = create(:account, user: user, initial_balance: 80)
      transaction = create(:transaction, user: user, card: nil, source: :bank, date: Date.new(2026, 3, 10), value: 80, paid: false)
      create(:transaction, user: user, card: nil, source: :bank, date: Date.new(2026, 4, 10), value: 50, paid: false)

      post "/api/payments/loose_expenses/pay", params: { month: 3, year: 2026, account_id: account.id }

      expect(response).to have_http_status(:ok)

      transaction.reload
      body = JSON.parse(response.body)
      expect(transaction.paid).to eq(true)
      expect(transaction.transaction_payments.first.account).to eq(account)
      expect(body["paid_transactions_count"]).to eq(1)
      expect(body["total_amount"]).to eq("80.0")
    end

    it 'creates one canonical integral payment per transaction without double-counting' do
      account = create(:account, user: user, initial_balance: 2_000)
      first = create(:transaction, user: user, card: nil, source: :cash, date: Date.new(2026, 3, 10), value: 300, paid: false)
      second = create(:transaction, user: user, card: nil, source: :bank, date: Date.new(2026, 3, 11), value: 500, paid: false)

      post '/api/payments/loose_expenses/pay', params: { month: 3, year: 2026, account_id: account.id, settled_on: '2026-03-15' }

      expect(response).to have_http_status(:ok)
      [first, second].each do |transaction|
        expect(transaction.reload).to have_attributes(paid: true, settled_on: nil, settled_value: nil)
        expect(transaction.transaction_payments).to contain_exactly(have_attributes(account: account, amount: transaction.value, settled_on: Date.new(2026, 3, 15)))
      end
      expect(Accounts::BalanceCalculator.call(account)).to eq(1_200.to_d)
    end

    it 'rolls back the entire batch when a later payment registration fails' do
      account = create(:account, user: user, initial_balance: 2_000)
      first = create(:transaction, user: user, card: nil, source: :cash, date: Date.new(2026, 3, 10), value: 300, paid: false)
      second = create(:transaction, user: user, card: nil, source: :bank, date: Date.new(2026, 3, 11), value: 500, paid: false)
      calls = 0
      allow_any_instance_of(Transactions::RegisterPaymentService).to receive(:call).and_wrap_original do |original, *args|
        calls += 1
        raise ActiveRecord::RecordInvalid.new(TransactionPayment.new) if calls == 2

        original.call(*args)
      end

      post '/api/payments/loose_expenses/pay', params: { month: 3, year: 2026, account_id: account.id }

      expect(response).to have_http_status(:unprocessable_entity)
      expect([first, second].map(&:reload).map(&:paid)).to eq([false, false])
      expect(TransactionPayment.count).to eq(0)
      expect(Accounts::BalanceCalculator.call(account)).to eq(2_000.to_d)
    end

    it 'rejects the entire batch when its combined debit exceeds the account balance' do
      account = create(:account, user: user, initial_balance: 1_000)
      first = create(:transaction, user: user, card: nil, source: :cash, date: Date.new(2026, 3, 10), value: 600, paid: false)
      second = create(:transaction, user: user, card: nil, source: :bank, date: Date.new(2026, 3, 11), value: 600, paid: false)

      expect do
        post '/api/payments/loose_expenses/pay', params: { month: 3, year: 2026, account_id: account.id }
      end.not_to change(TransactionPayment, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body).fetch('error')).to eq(
        "Saldo insuficiente na conta #{account.name}. Disponível: R$ 1000,00. Necessário: R$ 1200,00."
      )
      expect([first, second].map(&:reload).map(&:paid)).to eq([false, false])
      expect(Accounts::BalanceCalculator.call(account)).to eq(1_000.to_d)
      expect(Accounts::StatementBuilder.call(account: account, paginate: false).items.none? { |item| item.source_type == 'transaction_payment' }).to eq(true)
    end

    it "requires an active account from the current user" do
      create(:transaction, user: user, card: nil, source: :cash, date: Date.new(2026, 3, 10), paid: false)

      post "/api/payments/loose_expenses/pay", params: { month: 3, year: 2026 }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to eq("Conta é obrigatória para pagar despesas.")
    end
  end

  describe "POST /api/payments/loose_expenses/:id/pay" do
    it 'registers a partial payment and returns the canonical payment summary' do
      account = create(:account, user: user, initial_balance: 300)
      transaction = create(:transaction, user: user, card: nil, source: :bank, date: Date.new(2026, 3, 10), value: 1_000, paid: false)

      post "/api/payments/loose_expenses/#{transaction.id}/pay", params: { month: 3, year: 2026, account_id: account.id, amount: 300, settled_on: '2026-03-05', settle: false }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to include('paid' => false, 'payments_total' => '300.0', 'remaining_amount' => '700.0', 'payment_status' => 'partially_paid')
      expect(transaction.reload).to have_attributes(settled_on: nil, settled_value: nil)
      expect(Accounts::BalanceCalculator.call(account)).to eq(0.to_d)
    end

    it 'rejects an insufficient partial payment without changing the expense or statement' do
      account = create(:account, user: user, initial_balance: 299)
      transaction = create(:transaction, user: user, card: nil, source: :bank, date: Date.new(2026, 3, 10), value: 1_000, paid: false)

      expect do
        post "/api/payments/loose_expenses/#{transaction.id}/pay", params: { month: 3, year: 2026, account_id: account.id, amount: 300, settled_on: '2026-03-05', settle: false }
      end.not_to change(TransactionPayment, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body).fetch('error')).to include('Saldo insuficiente')
      expect(transaction.reload).to have_attributes(paid: false, payments_total: 0.to_d, remaining_amount: 1_000.to_d)
      expect(Accounts::BalanceCalculator.call(account)).to eq(299.to_d)
      expect(Accounts::StatementBuilder.call(account: account, paginate: false).items.none? { |item| item.source_type == 'transaction_payment' }).to eq(true)
    end

    it 'rejects an unconfirmed overpayment without persisting another event' do
      account = create(:account, user: user, initial_balance: 90)
      transaction = create(:transaction, user: user, card: nil, source: :cash, date: Date.new(2026, 3, 10), value: 100, paid: false)
      Transactions::RegisterPaymentService.new(transaction: transaction, account: account, amount: 90, settled_on: Date.new(2026, 3, 10)).call

      post "/api/payments/loose_expenses/#{transaction.id}/pay", params: { month: 3, year: 2026, account_id: account.id, amount: 20, settle: false }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(transaction.transaction_payments.count).to eq(1)
    end

    it "marks a single loose expense as paid for the selected period" do
      account = create(:account, user: user, name: "Conta Corrente", initial_balance: 80)
      transaction = create(:transaction, user: user, card: nil, source: :bank, date: Date.new(2026, 3, 10), value: 80, paid: false, description: "Uber")
      create(:transaction, user: user, card: nil, source: :bank, date: Date.new(2026, 3, 11), value: 50, paid: false)

      post "/api/payments/loose_expenses/#{transaction.id}/pay", params: { month: 3, year: 2026, account_id: account.id }

      expect(response).to have_http_status(:ok)

      transaction.reload
      body = JSON.parse(response.body)
      expect(transaction.paid).to eq(true)
      expect(transaction.transaction_payments.first.account).to eq(account)
      expect(body["id"]).to eq(transaction.id)
      expect(body["description"]).to eq("UBER")
      expect(body["paid"]).to eq(true)
      expect(body.dig("payments", 0, "account", "name")).to eq("Conta Corrente")
    end

    it 'records the provided settlement date and value' do
      account = create(:account, user: user, initial_balance: 149.26)
      transaction = create(:transaction, user: user, card: nil, source: :bank, date: Date.new(2026, 3, 18), value: 150, paid: false)

      post "/api/payments/loose_expenses/#{transaction.id}/pay", params: { month: 3, year: 2026, account_id: account.id, settled_on: '2026-03-10', settled_value: '149,26' }

      expect(response).to have_http_status(:ok)
      expect(transaction.reload).to have_attributes(paid: true, settled_on: nil, settled_value: nil)
      expect(transaction.transaction_payments.first).to have_attributes(settled_on: Date.new(2026, 3, 10), amount: 149.26.to_d)
    end

    it "rejects an account from another user without changing the expense" do
      transaction = create(:transaction, user: user, card: nil, source: :bank, date: Date.new(2026, 3, 10), paid: false)
      original_account_id = transaction.account_id
      other_account = create(:account, user: create(:user))

      post "/api/payments/loose_expenses/#{transaction.id}/pay", params: { month: 3, year: 2026, account_id: other_account.id }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(transaction.reload.paid).to eq(false)
      expect(transaction.account_id).to eq(original_account_id)
    end

    it "does not treat a legacy card-sourced transaction without card_id as a loose expense" do
      account = create(:account, user: user)
      transaction = create(:transaction, user: user, card: nil, source: :bank, date: Date.new(2026, 3, 10), paid: false)
      transaction.update_column(:source, Transaction.sources[:card])

      post "/api/payments/loose_expenses/#{transaction.id}/pay", params: { month: 3, year: 2026, account_id: account.id }

      expect(response).to have_http_status(:not_found)
      expect(transaction.reload.paid).to eq(false)
      expect(transaction.account_id).not_to eq(account.id)
    end

    it "returns not found when the expense is outside the selected period" do
      transaction = create(:transaction, user: user, card: nil, source: :bank, date: Date.new(2026, 4, 10), value: 80, paid: false)

      account = create(:account, user: user)
      post "/api/payments/loose_expenses/#{transaction.id}/pay", params: { month: 3, year: 2026, account_id: account.id }

      expect(response).to have_http_status(:not_found)

      transaction.reload
      body = JSON.parse(response.body)
      expect(transaction.paid).to eq(false)
      expect(body["error"]).to eq("Despesa avulsa não encontrada para o período selecionado.")
    end
  end

  describe "POST /api/payments/loose_expenses/:id/ignore" do
    it "removes a single loose expense from the payment flow for the selected period" do
      transaction = create(:transaction, user: user, card: nil, source: :bank, date: Date.new(2026, 3, 10), value: 80, paid: false, description: "Uber")
      create(:transaction, user: user, card: nil, source: :bank, date: Date.new(2026, 3, 11), value: 50, paid: false)

      post "/api/payments/loose_expenses/#{transaction.id}/ignore", params: { month: 3, year: 2026 }

      expect(response).to have_http_status(:ok)

      transaction.reload
      body = JSON.parse(response.body)
      expect(transaction.paid).to eq(false)
      expect(transaction.payment_ignored_at).to be_present
      expect(body["id"]).to eq(transaction.id)
      expect(body["payment_ignored_at"]).to be_present
    end

    it "returns not found when the expense is outside the selected period" do
      transaction = create(:transaction, user: user, card: nil, source: :bank, date: Date.new(2026, 4, 10), value: 80, paid: false)

      post "/api/payments/loose_expenses/#{transaction.id}/ignore", params: { month: 3, year: 2026 }

      expect(response).to have_http_status(:not_found)

      transaction.reload
      body = JSON.parse(response.body)
      expect(transaction.payment_ignored_at).to eq(nil)
      expect(body["error"]).to eq("Despesa avulsa não encontrada para o período selecionado.")
    end
  end
end
