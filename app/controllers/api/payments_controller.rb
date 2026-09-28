class Api::PaymentsController < Api::BaseController
  before_action :authenticate_user!

  def index
    snapshot = period_statement_snapshot
    payments_by_statement = period_payments_by_statement(snapshot.statements)
    statements = snapshot.statements.reject(&:ignored?).map do |statement|
      payment_statement_json(
        statement,
        payments: payments_by_statement.fetch(statement.id, []),
        transactions_count: snapshot.transaction_counts.fetch(statement.card_id, 0)
      )
    end
    ignored_statements = snapshot.statements.select(&:ignored?).map do |statement|
      payment_statement_json(
        statement,
        payments: payments_by_statement.fetch(statement.id, []),
        transactions_count: snapshot.transaction_counts.fetch(statement.card_id, 0)
      )
    end
    loose_scope = loose_expenses_scope
    ignored_loose_scope = ignored_loose_expenses_scope
    loose_count, loose_total = transaction_aggregate(loose_scope)
    ignored_loose_count, ignored_loose_total = transaction_aggregate(ignored_loose_scope)
    loose_transactions = loose_scope.includes(:account).order(date: :desc, value: :desc).limit(50).to_a
    ignored_loose_transactions = ignored_loose_scope.includes(:account).order(payment_ignored_at: :desc, date: :desc, value: :desc).limit(50).to_a

    render json: {
      period: {
        month: selected_month,
        year: selected_year
      },
      statements: statements,
      loose_expenses: {
        period_label: I18n.l(period_start, format: '%m/%Y'),
        transactions_count: loose_count,
        total_amount: loose_total,
        paid: loose_count.zero?,
        transactions: loose_transactions.map { |transaction| loose_transaction_json(transaction) }
      },
      ignored_payments: {
        period_label: I18n.l(period_start, format: '%m/%Y'),
        statements_count: ignored_statements.count,
        statements_total_amount: ignored_statements.sum { |statement| statement[:remaining_amount].to_d },
        statements: ignored_statements,
        loose_expenses: {
          transactions_count: ignored_loose_count,
          total_amount: ignored_loose_total,
          transactions: ignored_loose_transactions.map { |transaction| loose_transaction_json(transaction) }
        }
      }
    }
  end

  def pay_card_statement
    statement = current_user_card_statements.active_for_payments.find(params[:id])
    pay_statement(statement)
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
  end

  def pay_card_statement_by_reference
    pay_statement(materialize_statement_from_reference!)
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
  end

  def ignore_card_statement
    statement = current_user_card_statements.active_for_payments.where(billing_statement: period_start..period_end).find(params[:id])
    ignore_statement(statement)
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Fatura não encontrada para o período selecionado." }, status: :not_found
  end

  def ignore_card_statement_by_reference
    ignore_statement(materialize_statement_from_reference!)
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
  end

  def pay_statement(statement)
    statement.card.sync_statement!(statement.billing_statement.month, statement.billing_statement.year)
    statement.reload
    amount = payment_amount_param(statement.remaining_amount)
    account = payment_account_param

    statement.apply_payment!(amount, account: account)

    render json: payment_statement_json(statement.reload), status: :ok
  end

  def pay_loose_expenses
    scope = loose_expenses_scope
    count = scope.count
    total = signed_sum(scope)
    account = payment_account_param(message: "Conta é obrigatória para pagar despesas.")

    settled_on = settlement_date_param

    Accounts::DebitGuard.call(account: account, amount: total) do
      Transaction.transaction do
        scope.find_each do |transaction|
          Transactions::RegisterPaymentService.new(
            transaction: transaction, account: account, amount: transaction.value,
            settled_on: settled_on, settle: true
          ).call
        end
      end
    end

    render json: {
      period: {
        month: selected_month,
        year: selected_year
      },
      paid_transactions_count: count,
      total_amount: total
    }, status: :ok
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
  end

  def ignore_statement(statement)
    statement.ignore_for_payment!

    render json: payment_statement_json(statement.reload), status: :ok
  end

  def pay_loose_expense
    transaction = loose_expenses_scope.find(params[:id])
    account = payment_account_param(message: "Conta é obrigatória para pagar a despesa.")
    Transactions::RegisterPaymentService.new(
      transaction: transaction,
      account: account,
      amount: transaction_payment_amount_param(transaction.value),
      settled_on: settlement_date_param,
      settle: settlement_param
    ).call

    render json: loose_transaction_json(transaction.reload), status: :ok
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Despesa avulsa não encontrada para o período selecionado." }, status: :not_found
  end

  def ignore_loose_expense
    transaction = loose_expenses_scope.find(params[:id])
    transaction.ignore_for_payment!

    render json: loose_transaction_json(transaction.reload), status: :ok
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Despesa avulsa não encontrada para o período selecionado." }, status: :not_found
  end

  private

  def selected_month
    @selected_month ||= begin
      month = params[:month].to_i
      month.between?(1, 12) ? month : Date.current.month
    end
  end

  def selected_year
    @selected_year ||= begin
      year = params[:year].to_i
      year.positive? ? year : Date.current.year
    end
  end

  def period_start
    @period_start ||= Date.new(selected_year, selected_month, 1)
  end

  def period_end
    @period_end ||= period_start.end_of_month
  end

  def loose_expenses_scope
    current_user.transactions
                .active
                .active_for_payments
                .loose_expenses
                .where(paid: false)
                .where(date: period_start..period_end)
  end

  def ignored_loose_expenses_scope
    current_user.transactions
                .active
                .loose_expenses
                .where(paid: false)
                .where(date: period_start..period_end)
                .where.not(payment_ignored_at: nil)
  end

  def current_user_card_statements
    CardStatement.joins(:card).where(cards: { user_id: current_user.id })
  end

  def materialize_statement_from_reference!
    card_id = params[:card_id].presence || params.dig(:statement, :card_id).presence
    billing_statement = params[:billing_statement].presence || params.dig(:statement, :billing_statement).presence
    raise ArgumentError, "Cartão é obrigatório para a fatura." if card_id.blank?
    raise ArgumentError, "Competência da fatura é obrigatória." if billing_statement.blank?

    card = current_user.cards.find(card_id)
    date = Date.iso8601(billing_statement)
    expected = card.due_on(date.year, date.month)
    raise ArgumentError, "Competência da fatura inválida." unless date == expected

    card.sync_statement!(date.month, date.year)
  rescue Date::Error
    raise ArgumentError, "Competência da fatura inválida."
  end


  def payment_amount_param(default_amount)
    value = params[:amount].presence || params.dig(:payment, :amount).presence
    return default_amount if value.blank?

    normalized = value.to_s.strip.tr(',', '.')
    raise ArgumentError, 'Valor do pagamento inválido.' unless /\A\d+(?:\.\d{1,2})?\z/.match?(normalized)

    parsed = normalized.to_d
    raise ArgumentError, 'Pagamento deve ser > 0' if parsed <= 0

    parsed
  end

  def payment_account_param(message: "Conta é obrigatória para pagar fatura.")
    account_id = params[:account_id].presence || params.dig(:payment, :account_id).presence
    raise ArgumentError, message if account_id.blank?

    current_user.accounts.active.find_by(id: account_id) || raise(ArgumentError, "Conta não encontrada.")
  end

  def settlement_date_param
    value = params[:settled_on].presence || params.dig(:payment, :settled_on).presence
    return Date.current if value.blank?

    Date.iso8601(value)
  rescue Date::Error
    raise ArgumentError, 'Data de realização inválida.'
  end

  def transaction_payment_amount_param(default_value)
    value = params[:amount].presence || params.dig(:payment, :amount).presence || params[:settled_value].presence || params.dig(:payment, :settled_value).presence
    return default_value if value.blank?

    normalized = value.to_s.strip.tr(',', '.')
    raise ArgumentError, 'Valor do pagamento inválido.' unless /\A\d+(?:\.\d{1,2})?\z/.match?(normalized)

    parsed = normalized.to_d
    raise ArgumentError, 'Pagamento deve ser > 0' if parsed <= 0

    parsed
  end

  def settlement_param
    value = params.key?(:settle) ? params[:settle] : params.dig(:payment, :settle)
    return true if value.nil? # compatibility for existing clients of the legacy pay action

    ActiveModel::Type::Boolean.new.cast(value)
  end

  def payment_statement_json(statement, payments: nil, transactions_count: nil)
    payments ||= statement.card_statement_payments.includes(:account).order(paid_at: :desc, id: :desc).to_a
    transactions_count ||= statement.card.transactions
                                    .active
                                    .where(billing_statement: statement.billing_statement.beginning_of_month..statement.billing_statement.end_of_month)
                                    .count

    {
      id: statement.id,
      card: {
        id: statement.card.id,
        name: statement.card.name
      },
      billing_statement: statement.billing_statement,
      total_amount: statement.total_amount,
      paid_amount: statement.paid_amount,
      remaining_amount: statement.remaining_amount,
      paid: statement.paid?,
      payment_status: statement.payment_status,
      paid_at: statement.paid_at,
      ignored_at: statement.ignored_at,
      payments: payments.map { |payment| payment_json(payment) },
      due_day: statement.card.due_day_value,
      closing_day: statement.card.closing_day_value(statement.billing_statement),
      transactions_count: transactions_count
    }
  end

  def payment_json(payment)
    {
      id: payment.id,
      amount: payment.amount,
      paid_at: payment.paid_at,
      description: payment.description,
      source: payment.source,
      original_transaction_id: payment.original_transaction_id,
      account: payment.account&.as_json(only: %i[id name])
    }
  end

  def loose_transaction_json(transaction)
    {
      id: transaction.id,
      description: transaction.description,
      value: transaction.value,
      signed_value: transaction.signed_value,
      refund: transaction.refund,
      date: transaction.date,
      settled_on: transaction.settled_on,
      settled_value: transaction.settled_value,
      source: transaction.source,
      category_id: transaction.category_id,
      account: transaction.account&.as_json(only: %i[id name]),
      paid: transaction.paid,
      payments_total: transaction.payments_total,
      remaining_amount: transaction.remaining_amount,
      payment_status: transaction.payment_status,
      payments: transaction.transaction_payments.includes(:account).order(settled_on: :desc, id: :desc).map { |payment| transaction_payment_json(payment) },
      payment_ignored_at: transaction.payment_ignored_at,
      installment_number: transaction.installment_number,
      installments_count: transaction.installments_count,
      note: transaction.note,
    }
  end

  def transaction_payment_json(payment)
    {
      id: payment.id,
      amount: payment.amount,
      settled_on: payment.settled_on,
      account: payment.account.as_json(only: %i[id name])
    }
  end

  def signed_sum(scope)
    Transaction.signed_sum(scope)
  end

  def period_statement_snapshot
    @period_statement_snapshot ||= CardStatements::PeriodSnapshot.new(
      user: current_user,
      month: selected_month,
      year: selected_year
    ).call
  end

  def period_payments_by_statement(statements)
    CardStatementPayment
      .where(card_statement_id: statements.map(&:id))
      .includes(:account)
      .order(paid_at: :desc, id: :desc)
      .group_by(&:card_statement_id)
  end

  def transaction_aggregate(scope)
    row = scope.pluck(Arel.sql("COUNT(*)"), Arel.sql("COALESCE(SUM(#{Transaction.signed_value_sql}), 0)")).first
    [row[0], row[1].to_d]
  end
end
