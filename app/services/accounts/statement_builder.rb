module Accounts
  class StatementBuilder
    CASH_EXPENSE_SOURCES = %w[cash bank].freeze
    DIRECTIONS = %w[credit debit].freeze
    MOVEMENT_TYPES = %w[
      initial_balance
      income
      expense
      transaction_payment
      card_statement_payment
      transfer_in
      transfer_out
    ].freeze
    DEFAULT_PER_PAGE = 25
    MAX_PER_PAGE = 100

    Result = Struct.new(:account, :items, :all_items, :balances, :summary, :pagination, :period, :filters, keyword_init: true)

    class LazyItems
      def initialize(&loader)
        @loader = loader
      end

      def method_missing(method_name, *args, &block)
        loaded_items.public_send(method_name, *args, &block)
      end

      def respond_to_missing?(method_name, include_private = false)
        loaded_items.respond_to?(method_name, include_private) || super
      end

      private

      def loaded_items
        @loaded_items ||= @loader.call
      end
    end

    def self.call(account:, params: {}, paginate: true)
      new(account: account, params: params, paginate: paginate).call
    end

    def initialize(account:, params: {}, paginate: true)
      @account = account
      @params = params
      @pagination_enabled = paginate
    end

    def call
      return paginated_call if pagination_enabled

      filtered_entries = apply_filters(entries)
      sorted_entries = sort_entries(filtered_entries)
      paginated_entries = paginate(sorted_entries)

      Result.new(
        account: account,
        items: paginated_entries,
        all_items: sorted_entries,
        balances: balances,
        summary: summary_for(sorted_entries),
        pagination: pagination_for(sorted_entries),
        period: period,
        filters: filters
      )
    end

    private

    attr_reader :account, :params, :pagination_enabled

    def paginated_call
      candidates = paginated_source_entries
      sorted_candidates = sort_entries(candidates)
      totals = paginated_totals

      Result.new(
        account: account,
        items: sorted_candidates.slice((page - 1) * per_page, per_page) || [],
        all_items: LazyItems.new { sort_entries(apply_filters(entries)) },
        balances: balances,
        summary: { credits_total: totals[:credits], debits_total: totals[:debits], net_total: totals[:credits] - totals[:debits] },
        pagination: { page: page, per_page: per_page, total_count: totals[:count], total_pages: (totals[:count].to_f / per_page).ceil },
        period: period,
        filters: filters
      )
    end

    def paginated_source_entries
      result = []
      result << initial_balance_entry if initial_balance_in_filtered_set?
      result.concat(limited_income_entries) if source_enabled?('income', 'credit')
      result.concat(limited_cash_expense_entries) if source_enabled?('expense', 'debit')
      result.concat(limited_transaction_payment_entries) if source_enabled?('expense', 'debit')
      result.concat(limited_payment_entries) if source_enabled?('card_statement_payment', 'debit')
      result.concat(limited_outgoing_transfer_entries) if source_enabled?('transfer_out', 'debit')
      result.concat(limited_incoming_transfer_entries) if source_enabled?('transfer_in', 'credit')
      result
    end

    def paginated_totals
      credits = 0.to_d
      debits = 0.to_d
      count = 0
      if initial_balance_in_filtered_set?
        credits += account.initial_balance.to_d
        count += 1
      end
      [[income_scope, 'income', 'credit'], [cash_expense_scope, 'expense', 'debit'], [transaction_payment_scope, 'expense', 'debit'], [payment_scope, 'card_statement_payment', 'debit'],
       [outgoing_transfer_scope, 'transfer_out', 'debit'], [incoming_transfer_scope, 'transfer_in', 'credit']].each do |scope, type, source_direction|
        next unless source_enabled?(type, source_direction)

        source_count = scope.count
        amount = if scope.klass == TransactionPayment
                   scope.sum(:amount).to_d
                 elsif type == 'expense'
                   scope.sum(Arel.sql('COALESCE(transactions.settled_value, transactions.value)')).to_d
                 else
                   scope.sum(type == 'income' ? :value : :amount).to_d
                 end
        count += source_count
        source_direction == 'credit' ? credits += amount : debits += amount
      end
      { credits: credits, debits: debits, count: count }
    end

    def source_enabled?(type, source_direction)
      (movement_type.blank? || movement_type == type) && (direction.blank? || direction == source_direction)
    end

    def initial_balance_in_filtered_set?
      source_enabled?('initial_balance', 'credit') &&
        (start_date.blank? || account.initial_balance_date >= start_date) &&
        (end_date.blank? || account.initial_balance_date <= end_date)
    end

    def candidate_limit
      page * per_page
    end

    def apply_period(scope, column)
      scope = scope.where(column => start_date..) if start_date.present?
      scope = scope.where(column => ..end_date) if end_date.present?
      scope
    end

    def income_scope
      apply_period(account.transactions.active.incomes.where(user_id: account.user_id), :date)
    end

    def cash_expense_scope
      scope = account.transactions.active.expenses.where(user_id: account.user_id, source: CASH_EXPENSE_SOURCES, paid: true)
      scope = scope.where.not(id: TransactionPayment.select(:transaction_id))
      scope = scope.where('COALESCE(transactions.settled_on, transactions.date) >= ?', start_date) if start_date.present?
      scope = scope.where('COALESCE(transactions.settled_on, transactions.date) <= ?', end_date) if end_date.present?
      scope
    end

    def transaction_payment_scope
      scope = account.transaction_payments.joins(:financial_transaction).where(transactions: { user_id: account.user_id, archived_at: nil })
      apply_period(scope, :settled_on)
    end

    def payment_scope
      scope = account.card_statement_payments.joins(card_statement: :card).where(cards: { user_id: account.user_id })
      scope = scope.where('card_statement_payments.paid_at >= ?', start_date.beginning_of_day) if start_date.present?
      scope = scope.where('card_statement_payments.paid_at <= ?', end_date.end_of_day) if end_date.present?
      scope
    end

    def outgoing_transfer_scope
      apply_period(account.outgoing_transfers.completed.where(user_id: account.user_id), :transferred_on)
    end

    def incoming_transfer_scope
      apply_period(account.incoming_transfers.completed.where(user_id: account.user_id), :transferred_on)
    end

    def limited_income_entries
      income_scope.includes(:category).order(date: :desc, created_at: :desc, id: :desc).limit(candidate_limit).map { |tx| transaction_entry(tx, movement_type: 'income', direction: 'credit', title: transaction_title(tx)) }
    end

    def limited_cash_expense_entries
      cash_expense_scope.includes(:category).order(Arel.sql('COALESCE(transactions.settled_on, transactions.date) DESC, transactions.created_at DESC, transactions.id DESC')).limit(candidate_limit).map { |tx| transaction_entry(tx, movement_type: 'expense', direction: 'debit', title: transaction_title(tx)) }
    end

    def limited_transaction_payment_entries
      transaction_payment_scope.includes(financial_transaction: :category).order(settled_on: :desc, created_at: :desc, id: :desc).limit(candidate_limit).map { |payment| transaction_payment_entry(payment) }
    end

    def limited_payment_entries
      payment_scope.includes(card_statement: :card).order(Arel.sql('DATE(card_statement_payments.paid_at) DESC, card_statement_payments.created_at DESC, card_statement_payments.id DESC')).limit(candidate_limit).map { |payment| payment_entry(payment) }
    end

    def limited_outgoing_transfer_entries
      outgoing_transfer_scope.includes(:to_account).order(transferred_on: :desc, created_at: :desc, id: :desc).limit(candidate_limit).map { |transfer| outgoing_transfer_entry(transfer) }
    end

    def limited_incoming_transfer_entries
      incoming_transfer_scope.includes(:from_account).order(transferred_on: :desc, created_at: :desc, id: :desc).limit(candidate_limit).map { |transfer| incoming_transfer_entry(transfer) }
    end

    def entries
      [
        initial_balance_entry,
        income_entries,
        cash_expense_entries,
        transaction_payment_entries,
        card_statement_payment_entries,
        outgoing_transfer_entries,
        incoming_transfer_entries
      ].flatten
    end

    def initial_balance_entry
      StatementEntry.new(
        id: "initial-balance-#{account.id}",
        source_type: "account",
        source_id: account.id,
        movement_type: "initial_balance",
        direction: "credit",
        amount: account.initial_balance,
        occurred_on: account.initial_balance_date,
        title: "Saldo inicial",
        description: "Saldo informado ao criar a conta",
        created_at: account.created_at,
        metadata: {}
      )
    end

    def income_entries
      account.transactions
             .active
             .incomes
             .where(user_id: account.user_id)
             .includes(:category)
             .map do |transaction|
        transaction_entry(
          transaction,
          movement_type: "income",
          direction: "credit",
          title: transaction.description
        )
      end
    end

    def cash_expense_entries
      account.transactions
             .active
             .expenses
             .where(user_id: account.user_id)
             .where(source: CASH_EXPENSE_SOURCES, paid: true)
             .where.not(id: TransactionPayment.select(:transaction_id))
             .includes(:category)
             .map do |transaction|
        transaction_entry(
          transaction,
          movement_type: "expense",
          direction: "debit",
          title: transaction.description
        )
      end
    end

    def transaction_payment_entries
      account.transaction_payments.joins(:financial_transaction).where(transactions: { user_id: account.user_id, archived_at: nil }).includes(financial_transaction: :category).map { |payment| transaction_payment_entry(payment) }
    end

    def transaction_payment_entry(payment)
      transaction = payment.financial_transaction
      StatementEntry.new(
        id: "transaction-payment-#{payment.id}", source_type: "transaction_payment", source_id: payment.id,
        movement_type: "expense", direction: "debit", amount: payment.amount, occurred_on: payment.settled_on,
        title: "Pagamento — #{transaction_title(transaction)}", description: transaction.note, created_at: payment.created_at,
        metadata: { transaction_id: transaction.id, category: category_metadata(transaction.category), source: transaction.source, responsible: transaction.responsible }
      )
    end

    def transaction_entry(transaction, movement_type:, direction:, title:)
      StatementEntry.new(
        id: "transaction-#{transaction.id}",
        source_type: "transaction",
        source_id: transaction.id,
        movement_type: movement_type,
        direction: direction,
        amount: transaction_settlement_amount(transaction, movement_type),
        occurred_on: transaction_settlement_date(transaction, movement_type),
        title: title,
        description: transaction.note,
        created_at: transaction.created_at,
        metadata: {
          category: category_metadata(transaction.category),
          source: transaction.source,
          responsible: transaction.responsible
        }
      )
    end

    def transaction_title(transaction)
      transaction.friendly_title.presence || transaction.description
    end

    def transaction_settlement_amount(transaction, movement_type)
      movement_type == 'expense' ? (transaction.settled_value || transaction.value) : transaction.value
    end

    def transaction_settlement_date(transaction, movement_type)
      movement_type == 'expense' ? (transaction.settled_on || transaction.date) : transaction.date
    end

    def card_statement_payment_entries
      account.card_statement_payments
             .joins(card_statement: :card)
             .where(cards: { user_id: account.user_id })
             .includes(card_statement: :card)
             .map { |payment| payment_entry(payment) }
    end

    def payment_entry(payment)
      statement = payment.card_statement
      card = statement.card

      StatementEntry.new(
          id: "card-statement-payment-#{payment.id}",
          source_type: "card_statement_payment",
          source_id: payment.id,
          movement_type: "card_statement_payment",
          direction: "debit",
          amount: payment.amount,
          occurred_on: payment.paid_at.to_date,
          title: "Pagamento de fatura",
          description: payment.description,
          created_at: payment.created_at,
          metadata: {
            card: {
              id: card.id,
              name: card.name
            },
            billing_statement: statement.billing_statement
          }
      )
    end

    def outgoing_transfer_entries
      account.outgoing_transfers
             .completed
             .where(user_id: account.user_id)
             .includes(:to_account)
             .map { |transfer| outgoing_transfer_entry(transfer) }
    end

    def outgoing_transfer_entry(transfer)
      StatementEntry.new(
          id: "account-transfer-#{transfer.id}-out",
          source_type: "account_transfer",
          source_id: transfer.id,
          movement_type: "transfer_out",
          direction: "debit",
          amount: transfer.amount,
          occurred_on: transfer.transferred_on,
          title: "Transferência para #{transfer.to_account.name}",
          description: transfer.description,
          created_at: transfer.created_at,
          metadata: {
            counterparty_account: account_metadata(transfer.to_account),
            note: transfer.note
          }
      )
    end

    def incoming_transfer_entries
      account.incoming_transfers
             .completed
             .where(user_id: account.user_id)
             .includes(:from_account)
             .map { |transfer| incoming_transfer_entry(transfer) }
    end

    def incoming_transfer_entry(transfer)
      StatementEntry.new(
          id: "account-transfer-#{transfer.id}-in",
          source_type: "account_transfer",
          source_id: transfer.id,
          movement_type: "transfer_in",
          direction: "credit",
          amount: transfer.amount,
          occurred_on: transfer.transferred_on,
          title: "Transferência de #{transfer.from_account.name}",
          description: transfer.description,
          created_at: transfer.created_at,
          metadata: {
            counterparty_account: account_metadata(transfer.from_account),
            note: transfer.note
          }
      )
    end

    def apply_filters(entries)
      entries.select do |entry|
        within_period?(entry) &&
          matches_movement_type?(entry) &&
          matches_direction?(entry)
      end
    end

    def within_period?(entry)
      return false if start_date.present? && entry.occurred_on < start_date
      return false if end_date.present? && entry.occurred_on > end_date

      true
    end

    def matches_movement_type?(entry)
      movement_type.blank? || entry.movement_type == movement_type
    end

    def matches_direction?(entry)
      direction.blank? || entry.direction == direction
    end

    def sort_entries(entries)
      entries.sort_by do |entry|
        [
          -entry.occurred_on.jd,
          -entry.created_at.to_i,
          entry.source_type,
          -entry.source_id.to_i,
          entry.direction
        ]
      end
    end

    def paginate(entries)
      return entries unless pagination_enabled

      entries.slice((page - 1) * per_page, per_page) || []
    end

    def summary_for(entries)
      credits_total = entries.select(&:credit?).sum(0.to_d, &:amount)
      debits_total = entries.select(&:debit?).sum(0.to_d, &:amount)

      {
        credits_total: credits_total,
        debits_total: debits_total,
        net_total: credits_total - debits_total
      }
    end

    def pagination_for(entries)
      total_count = entries.size
      total_pages = (total_count.to_f / per_page).ceil

      {
        page: page,
        per_page: per_page,
        total_count: total_count,
        total_pages: total_pages
      }
    end

    def balances
      {
        opening_balance: opening_balance,
        closing_balance: closing_balance
      }
    end

    def opening_balance
      return 0.to_d if start_date.blank?

      Accounts::BalanceAtDateCalculator.call(account: account, as_of: start_date - 1.day)
    end

    def closing_balance
      Accounts::BalanceAtDateCalculator.call(
        account: account,
        as_of: end_date || Accounts::BalanceAtDateCalculator::ALL_KNOWN_EVENTS_CUTOFF
      )
    end

    def period
      {
        start_date: start_date,
        end_date: end_date
      }
    end

    def filters
      {
        movement_type: movement_type,
        direction: direction
      }
    end

    def start_date
      @start_date ||= parse_date_param(:start_date)
    end

    def end_date
      @end_date ||= parse_date_param(:end_date)
    end

    def movement_type
      @movement_type ||= begin
        value = params[:movement_type].presence
        raise ArgumentError, "Tipo de movimento inválido." if value.present? && !MOVEMENT_TYPES.include?(value)

        value
      end
    end

    def direction
      @direction ||= begin
        value = params[:direction].presence
        raise ArgumentError, "Direção inválida." if value.present? && !DIRECTIONS.include?(value)

        value
      end
    end

    def page
      @page ||= [(params[:page].presence || 1).to_i, 1].max
    end

    def per_page
      @per_page ||= begin
        requested = (params[:per_page].presence || DEFAULT_PER_PAGE).to_i
        requested = DEFAULT_PER_PAGE if requested <= 0
        [requested, MAX_PER_PAGE].min
      end
    end

    def parse_date_param(param_name)
      value = params[param_name].presence
      return nil if value.blank?

      Date.iso8601(value)
    rescue ArgumentError
      raise ArgumentError, "Data inválida para #{param_name}."
    end

    def category_metadata(category)
      return nil if category.blank?

      {
        id: category.id,
        name: category.name
      }
    end

    def account_metadata(account)
      {
        id: account.id,
        name: account.name
      }
    end
  end
end
