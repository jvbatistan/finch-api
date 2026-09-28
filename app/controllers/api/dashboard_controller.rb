class Api::DashboardController < Api::BaseController
  before_action :authenticate_user!

  def show
    render json: {
      period: {
        month: selected_month,
        year: selected_year,
        label: I18n.l(period_start, format: "%B/%Y")
      },
      summary: {
        incomes_total: incomes_total,
        expenses_total: expenses_total,
        balance_total: incomes_total - expenses_total,
        open_total: period_expenses_records.reject(&:paid).sum(0.to_d, &:signed_value),
        paid_total: period_expenses_records.select(&:paid).sum(0.to_d, &:signed_value),
        transactions_count: period_expenses_records.size + period_incomes_records.size
      },
      monthly_trend: monthly_trend,
      by_card: totals_by_card,
      by_category: totals_by_category,
      recent_expenses: recent_expenses,
      statements: statement_overview
    }
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

  def base_expenses_scope
    current_user.transactions.active.expenses.includes(:category, :card)
  end

  def base_incomes_scope
    current_user.transactions.active.incomes.includes(:category)
  end

  def period_expenses
    @period_expenses ||= base_expenses_scope.where(
      "(card_id IS NOT NULL AND billing_statement BETWEEN ? AND ?) OR (card_id IS NULL AND date BETWEEN ? AND ?)",
      period_start,
      period_end,
      period_start,
      period_end
    )
  end

  def period_incomes
    @period_incomes ||= base_incomes_scope.where(date: period_start..period_end)
  end

  def incomes_total
    @incomes_total ||= period_incomes_records.sum(0.to_d, &:signed_value)
  end

  def expenses_total
    @expenses_total ||= period_expenses_records.sum(0.to_d, &:signed_value)
  end

  def period_expenses_records
    @period_expenses_records ||= period_expenses.to_a
  end

  def period_incomes_records
    @period_incomes_records ||= period_incomes.to_a
  end

  def totals_by_card
    grouped = period_expenses_records.group_by { |transaction| transaction.card }

    grouped.map do |card, transactions|
      {
        id: card&.id,
        name: card&.name || "Sem cartão",
        total_amount: transactions.sum(&:signed_value),
        open_amount: transactions.reject(&:paid).sum(&:signed_value),
        paid_amount: transactions.select(&:paid).sum(&:signed_value),
        transactions_count: transactions.size
      }
    end.sort_by { |entry| [-entry[:total_amount].to_d, entry[:name].to_s] }
  end

  def monthly_trend
    months = (0..6).map { |offset| period_start << (6 - offset) }
    range_start = months.first

    grouped = base_expenses_scope
              .where(
                "(card_id IS NOT NULL AND billing_statement BETWEEN ? AND ?) OR (card_id IS NULL AND date BETWEEN ? AND ?)",
                range_start,
                period_end,
                range_start,
                period_end
              )
              .to_a
              .group_by do |transaction|
                trend_date = transaction.card_id.present? ? transaction.billing_statement : transaction.date
                trend_date.beginning_of_month
              end

    months.map do |month_start|
      transactions = grouped.fetch(month_start, [])

      {
        month: month_start.month,
        year: month_start.year,
        label: I18n.l(month_start, format: "%b"),
        total_amount: transactions.sum(&:signed_value),
        transactions_count: transactions.size
      }
    end
  end

  def totals_by_category
    grouped = period_expenses_records.group_by { |transaction| transaction.category }

    grouped.map do |category, transactions|
      {
        id: category&.id,
        name: category&.name || "Sem categoria",
        total_amount: transactions.sum(&:signed_value),
        transactions_count: transactions.size
      }
    end.sort_by { |entry| [-entry[:total_amount].to_d, entry[:name].to_s] }
  end

  def recent_expenses
    period_expenses_records.sort_by { |transaction| [transaction.created_at, transaction.id] }.reverse.first(8).map do |transaction|
      {
        id: transaction.id,
        description: transaction.description,
        friendly_title: transaction.friendly_title,
        value: transaction.value,
        signed_value: transaction.signed_value,
        refund: transaction.refund,
        date: transaction.date,
        paid: transaction.paid,
        card: transaction.card&.as_json(only: %i[id name]),
        category: transaction.category&.as_json(only: %i[id name]),
        installment_number: transaction.installment_number,
        installments_count: transaction.installments_count
      }
    end
  end

  def statement_overview
    snapshot = period_statement_snapshot

    snapshot.statements.filter_map do |statement|
      next if statement.ignored? || statement.total_amount.to_d <= 0

      card = statement.card

      {
        id: statement.id,
        card: {
          id: card.id,
          name: card.name
        },
        billing_statement: statement.billing_statement,
        total_amount: statement.total_amount,
        paid_amount: statement.paid_amount,
        remaining_amount: statement.remaining_amount,
        paid: statement.paid?,
        due_day: card.due_day_value,
        closing_day: card.closing_day_value(statement.billing_statement),
        transactions_count: snapshot.transaction_counts.fetch(card.id, 0)
      }
    end
  end

  def period_statement_snapshot
    @period_statement_snapshot ||= CardStatements::PeriodSnapshot.new(
      user: current_user,
      month: selected_month,
      year: selected_year
    ).call
  end

  def signed_sum(scope)
    Transaction.signed_sum(scope)
  end
end
