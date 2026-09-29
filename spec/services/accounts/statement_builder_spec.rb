require 'rails_helper'

RSpec.describe Accounts::StatementBuilder do
  let(:user) { create(:user) }
  let(:account) do
    create(
      :account,
      user: user,
      name: 'Nubank',
      initial_balance: 500,
      initial_balance_date: Date.new(2026, 7, 1),
      created_at: Time.zone.local(2026, 7, 1, 8)
    )
  end

  describe '.call' do
    it 'builds statement entries for every account cash movement' do
      category = create(:category, user: user, name: 'Salário')
      income = create(
        :transaction,
        user: user,
        kind: :income,
        source: :bank,
        account: account,
        card: nil,
        category: category,
        value: 1_000,
        date: Date.new(2026, 7, 5),
        description: 'Salário',
        note: 'Pagamento mensal',
        created_at: Time.zone.local(2026, 7, 5, 9)
      )
      cash_expense = create(
        :transaction,
        user: user,
        kind: :expense,
        source: :cash,
        account: account,
        card: nil,
        value: 80,
        date: Date.new(2026, 7, 6),
        description: 'Mercado',
        friendly_title: 'Compras da semana',
        paid: true,
        created_at: Time.zone.local(2026, 7, 6, 9)
      )
      bank_expense = create(
        :transaction,
        user: user,
        kind: :expense,
        source: :bank,
        account: account,
        card: nil,
        value: 120,
        date: Date.new(2026, 7, 7),
        description: 'Internet',
        paid: true,
        created_at: Time.zone.local(2026, 7, 7, 9)
      )
      card = create(:card, user: user, name: 'NUBANK')
      statement = create(:card_statement, card: card, billing_statement: Date.new(2026, 7, 1))
      payment = create(
        :card_statement_payment,
        card_statement: statement,
        account: account,
        amount: 300,
        paid_at: Time.zone.local(2026, 7, 8, 10),
        description: 'Pagamento cartão',
        created_at: Time.zone.local(2026, 7, 8, 10)
      )
      savings = create(:account, user: user, name: 'Reserva')
      outgoing = create(
        :account_transfer,
        user: user,
        from_account: account,
        to_account: savings,
        amount: 200,
        transferred_on: Date.new(2026, 7, 9),
        description: 'Guardar dinheiro',
        note: 'Reserva mensal',
        created_at: Time.zone.local(2026, 7, 9, 9)
      )
      incoming = create(
        :account_transfer,
        user: user,
        from_account: savings,
        to_account: account,
        amount: 50,
        transferred_on: Date.new(2026, 7, 10),
        description: 'Volta da reserva',
        created_at: Time.zone.local(2026, 7, 10, 9)
      )

      result = described_class.call(account: account)

      expect(result.items.map(&:movement_type)).to contain_exactly(
        'initial_balance',
        'income',
        'expense',
        'expense',
        'card_statement_payment',
        'transfer_out',
        'transfer_in'
      )
      expect(result.items.map(&:id)).to include(
        "transaction-#{income.id}",
        "transaction-#{cash_expense.id}",
        "transaction-#{bank_expense.id}",
        "card-statement-payment-#{payment.id}",
        "account-transfer-#{outgoing.id}-out",
        "account-transfer-#{incoming.id}-in",
        "initial-balance-#{account.id}"
      )
      expect(result.summary).to include(
        credits_total: 1_550.to_d,
        debits_total: 700.to_d,
        net_total: 850.to_d
      )
      expect(result.balances).to include(
        opening_balance: 0.to_d,
        closing_balance: 850.to_d
      )
      expect(result.items.first.movement_type).to eq('transfer_in')
      expect(result.items.find { |item| item.id == "transaction-#{income.id}" }.metadata[:category]).to include(id: category.id, name: 'Salário')
      expect(result.items.find { |item| item.id == "transaction-#{cash_expense.id}" }.title).to eq('COMPRAS DA SEMANA')
      expect(result.items.find { |item| item.id == "card-statement-payment-#{payment.id}" }.metadata[:card]).to include(id: card.id, name: 'NUBANK')
      expect(result.items.find { |item| item.id == "account-transfer-#{outgoing.id}-out" }.metadata[:counterparty_account]).to include(id: savings.id, name: 'Reserva')
    end

    it 'excludes movements that must not appear in the account statement' do
      card = create(:card, user: user)
      create(
        :transaction,
        user: user,
        kind: :expense,
        source: :card,
        account: nil,
        card: card,
        value: 90,
        date: Date.new(2026, 7, 5),
        description: 'Uber'
      )
      create(
        :transaction,
        user: user,
        kind: :expense,
        source: :bank,
        account: account,
        card: nil,
        value: 40,
        date: Date.new(2026, 7, 6),
        description: 'Arquivada',
        paid: true,
        archived_at: Time.current
      )
      legacy_without_account = create(
        :transaction,
        user: user,
        kind: :expense,
        source: :bank,
        account: account,
        card: nil,
        value: 30,
        date: Date.new(2026, 7, 7),
        description: 'Legado sem conta'
      )
      legacy_without_account.update_column(:account_id, nil)
      statement = create(:card_statement, card: card, billing_statement: Date.new(2026, 7, 1))
      create(:card_statement_payment, card_statement: statement, account: nil, amount: 100)
      savings = create(:account, user: user)
      create(:account_transfer, :reversed, user: user, from_account: account, to_account: savings, amount: 70)

      other_user = create(:user)
      other_account = create(:account, user: other_user)
      foreign_transaction = create(:transaction, user: other_user, kind: :income, source: :bank, account: other_account, card: nil, value: 999)
      foreign_transaction.update_column(:account_id, account.id)
      foreign_card = create(:card, user: other_user)
      foreign_statement = create(:card_statement, card: foreign_card)
      foreign_payment = create(:card_statement_payment, card_statement: foreign_statement, account: nil, amount: 888)
      foreign_payment.update_column(:account_id, account.id)
      foreign_transfer = create(:account_transfer, user: other_user, from_account: other_account, to_account: create(:account, user: other_user), amount: 777)
      foreign_transfer.update_column(:from_account_id, account.id)

      result = described_class.call(account: account)

      expect(result.items.map(&:movement_type)).to eq(['initial_balance'])
      expect(result.summary).to include(
        credits_total: 500.to_d,
        debits_total: 0.to_d,
        net_total: 500.to_d
      )
      expect(result.balances).to include(
        opening_balance: 0.to_d,
        closing_balance: 500.to_d
      )
    end

    it 'only includes a cash expense after it is paid' do
      expense = create(
        :transaction,
        user: user,
        kind: :expense,
        source: :cash,
        account: account,
        card: nil,
        value: 405,
        paid: false,
        date: Date.new(2026, 7, 5)
      )

      expect(described_class.call(account: account).items.map(&:id)).not_to include("transaction-#{expense.id}")

      expense.update!(paid: true, settled_on: Date.new(2026, 7, 5), settled_value: 405)

      expect(described_class.call(account: account).items.map(&:id)).to include("transaction-#{expense.id}")
    end

    it 'uses settlement date and value for paid loose expenses and preserves the legacy fallback' do
      settled = create(:transaction, user: user, kind: :expense, source: :bank, account: account, card: nil, value: 150, paid: true, date: Date.new(2026, 8, 18), settled_on: Date.new(2026, 8, 10), settled_value: 149.26)
      legacy = create(:transaction, user: user, kind: :expense, source: :cash, account: account, card: nil, value: 50, paid: true, date: Date.new(2026, 8, 11))

      result = described_class.call(account: account, params: { start_date: '2026-08-10', end_date: '2026-08-11' }, paginate: false)

      expect(result.items.find { |entry| entry.source_id == settled.id }).to have_attributes(occurred_on: Date.new(2026, 8, 10), amount: 149.26.to_d)
      expect(result.items.find { |entry| entry.source_id == legacy.id }).to have_attributes(occurred_on: Date.new(2026, 8, 11), amount: 50.to_d)
    end

    it 'keeps current balance, statement item, paginated summary and closing balance aligned to effective settlement value' do
      [
        { value: 1_000, settled_value: 1_000, expected_balance: 500 },
        { value: 1_000, settled_value: 950, expected_balance: 550 },
        { value: 1_000, settled_value: 1_050, expected_balance: 450 },
        { value: 1_000, settled_value: nil, expected_balance: 500 }
      ].each do |scenario|
        account = create(:account, user: user, initial_balance: 1_500, initial_balance_date: Date.new(2026, 8, 1))
        expense = create(
          :transaction,
          user: user,
          kind: :expense,
          source: :bank,
          account: account,
          card: nil,
          value: scenario[:value],
          settled_on: Date.new(2026, 8, 10),
          settled_value: scenario[:settled_value],
          paid: true
        )
        expense.update_columns(settled_value: nil) if scenario[:settled_value].nil?

        result = described_class.call(account: account, params: { start_date: '2026-08-10', end_date: '2026-08-10' })
        effective_value = scenario[:settled_value] || scenario[:value]

        expect(Accounts::BalanceCalculator.call(account)).to eq(scenario[:expected_balance].to_d)
        expect(result.items.find { |entry| entry.source_id == expense.id }).to have_attributes(amount: effective_value.to_d)
        expect(result.summary).to include(debits_total: effective_value.to_d, net_total: -effective_value.to_d)
        expect(result.balances).to include(closing_balance: scenario[:expected_balance].to_d)
      end
    end

    it 'applies period, movement type and direction filters before summary and pagination' do
      create(:transaction, user: user, kind: :income, source: :bank, account: account, card: nil, value: 100, date: Date.new(2026, 7, 5))
      create(:transaction, user: user, kind: :income, source: :bank, account: account, card: nil, value: 200, date: Date.new(2026, 7, 6))
      create(:transaction, user: user, kind: :expense, source: :bank, account: account, card: nil, value: 50, date: Date.new(2026, 7, 6), paid: true)

      result = described_class.call(
        account: account,
        params: {
          start_date: '2026-07-06',
          end_date: '2026-07-06',
          movement_type: 'income',
          direction: 'credit',
          page: 1,
          per_page: 1
        }
      )

      expect(result.items.size).to eq(1)
      expect(result.items.first.amount).to eq(200.to_d)
      expect(result.summary).to include(
        credits_total: 200.to_d,
        debits_total: 0.to_d,
        net_total: 200.to_d
      )
      expect(result.balances).to include(
        opening_balance: 600.to_d,
        closing_balance: 750.to_d
      )
      expect(result.pagination).to include(
        page: 1,
        per_page: 1,
        total_count: 1,
        total_pages: 1
      )
      expect(result.period).to include(
        start_date: Date.new(2026, 7, 6),
        end_date: Date.new(2026, 7, 6)
      )
      expect(result.filters).to include(
        movement_type: 'income',
        direction: 'credit'
      )
    end

    it 'keeps balances independent from movement type, direction and pagination filters' do
      create(:transaction, user: user, kind: :income, source: :bank, account: account, card: nil, value: 100, date: Date.new(2026, 7, 5))
      create(:transaction, user: user, kind: :expense, source: :bank, account: account, card: nil, value: 50, date: Date.new(2026, 7, 6), paid: true)
      create(:transaction, user: user, kind: :income, source: :cash, account: account, card: nil, value: 25, date: Date.new(2026, 7, 7))

      result = described_class.call(
        account: account,
        params: {
          start_date: '2026-07-05',
          end_date: '2026-07-07',
          movement_type: 'expense',
          direction: 'debit',
          page: 2,
          per_page: 1
        }
      )

      expect(result.items).to eq([])
      expect(result.summary).to include(
        credits_total: 0.to_d,
        debits_total: 50.to_d,
        net_total: -50.to_d
      )
      expect(result.balances).to include(
        opening_balance: 500.to_d,
        closing_balance: 575.to_d
      )
      expect(result.pagination).to include(
        page: 2,
        per_page: 1,
        total_count: 1,
        total_pages: 1
      )
    end

    it 'treats movements on start_date as period movements and movements on end_date as closing movements' do
      create(:transaction, user: user, kind: :income, source: :bank, account: account, card: nil, value: 100, date: Date.new(2026, 7, 4))
      create(:transaction, user: user, kind: :income, source: :bank, account: account, card: nil, value: 200, date: Date.new(2026, 7, 5))
      create(:transaction, user: user, kind: :expense, source: :bank, account: account, card: nil, value: 50, date: Date.new(2026, 7, 6), paid: true)
      create(:transaction, user: user, kind: :income, source: :bank, account: account, card: nil, value: 999, date: Date.new(2026, 7, 7))

      result = described_class.call(
        account: account,
        params: {
          start_date: '2026-07-05',
          end_date: '2026-07-06'
        }
      )

      expect(result.balances).to include(
        opening_balance: 600.to_d,
        closing_balance: 750.to_d
      )
      expect(result.summary).to include(
        credits_total: 200.to_d,
        debits_total: 50.to_d,
        net_total: 150.to_d
      )
    end

    it 'returns balances for a period without movements' do
      create(:transaction, user: user, kind: :income, source: :bank, account: account, card: nil, value: 100, date: Date.new(2026, 7, 5))

      result = described_class.call(
        account: account,
        params: {
          start_date: '2026-08-01',
          end_date: '2026-08-31'
        }
      )

      expect(result.items).to eq([])
      expect(result.summary).to include(
        credits_total: 0.to_d,
        debits_total: 0.to_d,
        net_total: 0.to_d
      )
      expect(result.balances).to include(
        opening_balance: 600.to_d,
        closing_balance: 600.to_d
      )
    end

    it 'does not include initial balance in opening when account starts inside the period' do
      result = described_class.call(
        account: account,
        params: {
          start_date: '2026-07-01',
          end_date: '2026-07-31'
        }
      )

      expect(result.items.map(&:movement_type)).to include('initial_balance')
      expect(result.balances).to include(
        opening_balance: 0.to_d,
        closing_balance: 500.to_d
      )
    end

    it 'can return closing balance different from current balance' do
      create(:transaction, user: user, kind: :income, source: :bank, account: account, card: nil, value: 100, date: Date.new(2026, 7, 5))
      create(:transaction, user: user, kind: :income, source: :bank, account: account, card: nil, value: 300, date: Date.new(2026, 8, 5))

      result = described_class.call(
        account: account,
        params: {
          start_date: '2026-07-01',
          end_date: '2026-07-31'
        }
      )

      expect(result.balances[:closing_balance]).to eq(600.to_d)
      expect(Accounts::BalanceCalculator.call(account)).to eq(900.to_d)
    end

    it 'paginates with a safe default and maximum page size' do
      create_list(:transaction, 3, user: user, kind: :income, source: :bank, account: account, card: nil, value: 10, date: Date.new(2026, 7, 5))

      result = described_class.call(account: account, params: { per_page: 2, page: 2 })
      capped_result = described_class.call(account: account, params: { per_page: 500 })

      expect(result.items.size).to eq(2)
      expect(result.pagination).to include(page: 2, per_page: 2, total_count: 4, total_pages: 2)
      expect(capped_result.pagination[:per_page]).to eq(100)
    end

    it 'keeps summary and balances equal when pagination is disabled and changes only the returned items' do
      create_list(:transaction, 3, user: user, kind: :income, source: :bank, account: account, card: nil, value: 10, date: Date.new(2026, 7, 5))

      params = {
        start_date: '2026-07-01',
        end_date: '2026-07-31',
        direction: 'credit',
        page: 2,
        per_page: 1
      }
      paginated = described_class.call(account: account, params: params)
      unpaginated = described_class.call(account: account, params: params, paginate: false)

      expect(unpaginated.summary).to eq(paginated.summary)
      expect(unpaginated.balances).to eq(paginated.balances)
      expect(unpaginated.period).to eq(paginated.period)
      expect(unpaginated.filters).to eq(paginated.filters)
      expect(unpaginated.pagination).to eq(paginated.pagination)
      expect(paginated.items.size).to eq(1)
      expect(unpaginated.items.size).to eq(4)
      expect(unpaginated.items.map(&:as_json)).to eq(paginated.all_items.map(&:as_json))
    end

    it 'raises clear errors for invalid filters' do
      expect do
        described_class.call(account: account, params: { movement_type: 'unknown' })
      end.to raise_error(ArgumentError, 'Tipo de movimento inválido.')

      expect do
        described_class.call(account: account, params: { direction: 'sideways' })
      end.to raise_error(ArgumentError, 'Direção inválida.')

      expect do
        described_class.call(account: account, params: { start_date: '2026-99-99' })
      end.to raise_error(ArgumentError, 'Data inválida para start_date.')
    end

    it 'projects canonical payments independently and excludes the legacy transaction fallback' do
      user = create(:user)
      account = create(:account, user: user, initial_balance: 2_000, initial_balance_date: Date.new(2026, 9, 1))
      transaction = create(:transaction, user: user, kind: :expense, source: :cash, card: nil, account: account, value: 1_000, date: Date.new(2026, 9, 1), paid: true)
      transaction.update_columns(settled_on: Date.new(2026, 9, 1), settled_value: 1_000)
      TransactionPayment.create!(financial_transaction: transaction, account: account, amount: 300, settled_on: Date.new(2026, 9, 5))
      TransactionPayment.create!(financial_transaction: transaction, account: account, amount: 200, settled_on: Date.new(2026, 9, 10))

      result = described_class.call(account: account, params: { start_date: '2026-09-01', end_date: '2026-09-30' }, paginate: false)
      items = result.items.select { |item| item.source_type == 'transaction_payment' }

      expect(items.map { |item| [item.occurred_on, item.amount] }).to contain_exactly([Date.new(2026, 9, 5), 300.to_d], [Date.new(2026, 9, 10), 200.to_d])
      expect(result.items.select { |item| item.source_type == 'transaction' && item.source_id == transaction.id }).to be_empty
      expect(result.summary[:debits_total]).to eq(500.to_d)
      expect(result.balances[:opening_balance]).to eq(0.to_d)
      expect(result.balances[:closing_balance]).to eq(1_500.to_d)
    end

    it 'uses each payment account instead of the transaction planned account' do
      user = create(:user)
      planned = create(:account, user: user)
      account_a = create(:account, user: user)
      account_b = create(:account, user: user)
      transaction = create(:transaction, user: user, kind: :expense, source: :cash, card: nil, account: planned, value: 1_000, paid: true)
      transaction.update_columns(settled_on: nil, settled_value: nil)
      TransactionPayment.create!(financial_transaction: transaction, account: account_a, amount: 300, settled_on: Date.new(2026, 9, 5))
      TransactionPayment.create!(financial_transaction: transaction, account: account_b, amount: 200, settled_on: Date.new(2026, 9, 10))

      expect(described_class.call(account: account_a, paginate: false).items.select { |item| item.source_type == 'transaction_payment' }.map(&:amount)).to eq([300.to_d])
      expect(described_class.call(account: account_b, paginate: false).items.select { |item| item.source_type == 'transaction_payment' }.map(&:amount)).to eq([200.to_d])
      expect(described_class.call(account: planned, paginate: false).items.select { |item| item.source_type == 'transaction_payment' }).to be_empty
    end

    it 'keeps legacy settled and fallback expenses as one movement on their planned account' do
      user = create(:user)
      account = create(:account, user: user)
      other_account = create(:account, user: user)
      settled = create(:transaction, user: user, kind: :expense, source: :bank, card: nil, account: account, value: 1_000, date: Date.new(2026, 9, 1), paid: true)
      settled.update_columns(settled_on: Date.new(2026, 9, 10), settled_value: 950)
      fallback = create(:transaction, user: user, kind: :expense, source: :cash, card: nil, account: account, value: 200, date: Date.new(2026, 9, 15), paid: true)
      fallback.update_columns(settled_on: nil, settled_value: nil)

      items = described_class.call(account: account, paginate: false).items.select { |item| item.source_type == 'transaction' }
      expect(items.map { |item| [item.source_id, item.occurred_on, item.amount] }).to contain_exactly([settled.id, Date.new(2026, 9, 10), 950.to_d], [fallback.id, Date.new(2026, 9, 15), 200.to_d])
      expect(described_class.call(account: other_account, paginate: false).items.select { |item| item.source_type == 'transaction' }).to be_empty
    end
  end
end
