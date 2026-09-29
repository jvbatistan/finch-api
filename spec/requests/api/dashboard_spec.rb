require "rails_helper"

RSpec.describe "Api::Dashboard", type: :request do
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

  describe "GET /api/dashboard" do
    it "uses the current competence when month and year are omitted or invalid" do
      allow(Date).to receive(:current).and_return(Date.new(2026, 8, 20))

      get "/api/dashboard"
      expect(JSON.parse(response.body).fetch("period")).to include("month" => 8, "year" => 2026)

      get "/api/dashboard", params: { month: 13, year: 0 }
      expect(JSON.parse(response.body).fetch("period")).to include("month" => 8, "year" => 2026)
    end

    it "uses an explicit past or future competence" do
      get "/api/dashboard", params: { month: 2, year: 2024 }
      expect(JSON.parse(response.body).fetch("period")).to include("month" => 2, "year" => 2024)

      get "/api/dashboard", params: { month: 11, year: 2030 }
      expect(JSON.parse(response.body).fetch("period")).to include("month" => 11, "year" => 2030)
    end

    it "limits recent expenses to the selected competence" do
      card = create(:card, user: user, due_day: 15, closing_day: 8)
      outside_period = create(:transaction, user: user, card: card, source: :card, date: Date.new(2026, 1, 10), billing_statement: Date.new(2026, 2, 1), created_at: Time.zone.parse("2026-08-20 10:00"), description: "Despesa fora da competência")
      recent = create(:transaction, user: user, source: :cash, card: nil, date: Date.new(2026, 3, 10), created_at: Time.zone.parse("2026-08-19 10:00"), description: "Despesa da competência", friendly_title: "Título do dashboard")

      get "/api/dashboard", params: { month: 3, year: 2026 }

      body = JSON.parse(response.body)
      expect(body.fetch("period")).to include("month" => 3, "year" => 2026)
      expect(body.fetch("recent_expenses").first.fetch("id")).to eq(recent.id)
      expect(body.fetch("recent_expenses").first.fetch("friendly_title")).to eq("TÍTULO DO DASHBOARD")
      expect(body.fetch("recent_expenses").map { |expense| expense.fetch("id") }).not_to include(outside_period.id)
    end

    it "keeps multi-card reads within a bounded number of queries and performs no redundant writes" do
      6.times do |index|
        card = create(:card, user: user, name: "Card #{index}", due_day: 15, closing_day: 8)
        create(:transaction, user: user, card: card, source: :card, date: Date.new(2026, 3, 7), value: 10 + index)
        card.sync_statement!(3, 2026)
      end

      metrics = sql_metrics { get "/api/dashboard", params: { month: 3, year: 2026 } }

      expect(response).to have_http_status(:ok)
      aggregate_failures(metrics.inspect) do
        expect(metrics[:select]).to be <= 14
        expect(metrics[:insert]).to eq(0)
        expect(metrics[:update]).to eq(0)
        expect(metrics[:delete]).to eq(0)
      end
    end

    it "returns real expense metrics for the selected period" do
      food = create(:category, user: user, name: "Alimentação")
      travel = create(:category, user: user, name: "Transporte")
      card = create(:card, user: user, name: "Nubank", due_day: 15, closing_day: 8)
      account = create(:account, user: user, name: "Conta Corrente")
      other_user = create(:user)
      other_account = create(:account, user: other_user)

      create(
        :transaction,
        user: user,
        category: food,
        card: nil,
        source: :cash,
        date: Date.new(2026, 4, 10),
        value: 80,
        paid: false,
        description: "Mercado"
      )
      create(
        :transaction,
        user: user,
        category: travel,
        card: card,
        source: :card,
        date: Date.new(2026, 4, 7),
        value: 120,
        paid: true,
        description: "Uber"
      )
      create(
        :transaction,
        user: user,
        category: nil,
        card: card,
        source: :card,
        date: Date.new(2026, 4, 6),
        value: 60,
        paid: false,
        description: "Farmacia"
      )
      create(
        :transaction,
        user: user,
        category: travel,
        card: card,
        source: :card,
        date: Date.new(2026, 4, 7),
        value: 20,
        refund: true,
        paid: false,
        description: "Uber estorno"
      )
      create(
        :transaction,
        user: user,
        category: food,
        source: :cash,
        card: nil,
        date: Date.new(2026, 3, 10),
        value: 50,
        paid: false,
        description: "Mes anterior"
      )
      create(
        :transaction,
        user: user,
        category: nil,
        kind: :income,
        account: account,
        source: :bank,
        card: nil,
        date: Date.new(2026, 4, 5),
        value: 1_000,
        paid: true,
        description: "Salário"
      )
      create(
        :transaction,
        user: user,
        category: nil,
        kind: :income,
        account: account,
        source: :bank,
        card: nil,
        date: Date.new(2026, 3, 31),
        value: 500,
        paid: true,
        description: "Receita fora do mês"
      )
      create(
        :transaction,
        user: other_user,
        category: nil,
        kind: :income,
        account: other_account,
        source: :bank,
        card: nil,
        date: Date.new(2026, 4, 5),
        value: 2_000,
        paid: true,
        description: "Receita de outro usuário"
      )
      statement = card.sync_statement!(4, 2026)
      create(:card_statement_payment, card_statement: statement, amount: 30, description: "Pagamento recebido")

      get "/api/dashboard", params: { month: 4, year: 2026 }

      expect(response).to have_http_status(:ok)

      body = JSON.parse(response.body)

      expect(body["period"]).to include("month" => 4, "year" => 2026)
      expect(body["summary"]).to eq(
        "incomes_total" => "1000.0",
        "expenses_total" => "240.0",
        "balance_total" => "760.0",
        "open_total" => "120.0",
        "paid_total" => "120.0",
        "transactions_count" => 5
      )

      expect(body["monthly_trend"].size).to eq(7)
      april = body["monthly_trend"].find { |entry| entry["month"] == 4 && entry["year"] == 2026 }
      march = body["monthly_trend"].find { |entry| entry["month"] == 3 && entry["year"] == 2026 }
      expect(april["total_amount"]).to eq("240.0")
      expect(april["transactions_count"]).to eq(4)
      expect(march["total_amount"]).to eq("50.0")

      by_card = body["by_card"]
      expect(by_card.map { |entry| entry["name"] }).to eq(["NUBANK", "Sem cartão"])
      expect(by_card.first["total_amount"]).to eq("160.0")
      expect(by_card.first["open_amount"]).to eq("40.0")
      expect(by_card.first["paid_amount"]).to eq("120.0")

      by_category = body["by_category"]
      expect(by_category.map { |entry| entry["name"] }).to include("Alimentação", "Transporte", "Sem categoria")

      expect(body["recent_expenses"].size).to be <= 8
      expect(body["recent_expenses"].first.keys).to include("description", "value", "category", "card")

      expect(body["statements"].size).to eq(1)
      expect(body["statements"].first.dig("card", "name")).to eq("NUBANK")
      expect(body["statements"].first["total_amount"]).to eq("160.0")
      expect(body["statements"].first["paid_amount"]).to eq("30.0")
      expect(body["statements"].first["remaining_amount"]).to eq("130.0")
    end

    it "keeps one obligation in dashboard totals regardless of its payment events" do
      account = create(:account, user: user)
      expense = create(
        :transaction,
        user: user,
        account: account,
        card: nil,
        source: :cash,
        date: Date.new(2026, 9, 1),
        value: 1_000,
        paid: false
      )

      TransactionPayment.create!(
        financial_transaction: expense,
        account: account,
        amount: 300,
        settled_on: Date.new(2026, 9, 5)
      )

      get "/api/dashboard", params: { month: 9, year: 2026 }

      partial_summary = JSON.parse(response.body).fetch("summary")
      expect(partial_summary).to include("expenses_total" => "1000.0", "transactions_count" => 1)

      TransactionPayment.create!(financial_transaction: expense, account: account, amount: 200, settled_on: Date.new(2026, 9, 10))
      TransactionPayment.create!(financial_transaction: expense, account: account, amount: 500, settled_on: Date.new(2026, 9, 20))
      expense.update!(paid: true)

      get "/api/dashboard", params: { month: 9, year: 2026 }

      paid_summary = JSON.parse(response.body).fetch("summary")
      expect(paid_summary).to include(
        "expenses_total" => "1000.0",
        "paid_total" => "1000.0",
        "transactions_count" => 1
      )
    end
  end
end
