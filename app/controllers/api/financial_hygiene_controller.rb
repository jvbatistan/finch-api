class Api::FinancialHygieneController < Api::BaseController
  before_action :authenticate_user!

  def show
    render json: { indicators: [uncategorized_indicator, overdue_loose_expenses_indicator, ignored_payments_indicator] }
  end

  private

  def active_transactions
    @active_transactions ||= current_user.transactions.active
  end

  def uncategorized_indicator
    scope = active_transactions.where(category_id: nil)
    indicator('uncategorized', 'Lançamentos sem categoria', scope, '/transactions')
  end

  def overdue_loose_expenses_indicator
    scope = active_transactions.loose_expenses.where(paid: false, payment_ignored_at: nil, refund: false).where('date < ?', Date.current)
    indicator('overdue_loose_expenses', 'Despesas avulsas vencidas', scope, '/payments')
  end

  def ignored_payments_indicator
    loose_scope = active_transactions.loose_expenses.where.not(payment_ignored_at: nil)
    statements = CardStatement.joins(:card).where(cards: { user_id: current_user.id }).where.not(ignored_at: nil)
    {
      key: 'ignored_payments', label: 'Itens ignorados no pagamento',
      count: loose_scope.count + statements.count,
      total_amount: Transaction.signed_sum(loose_scope) + statements.sum('total_amount - paid_amount').to_d,
      action_url: '/payments'
    }
  end

  def indicator(key, label, scope, action_url)
    { key: key, label: label, count: scope.count, total_amount: Transaction.signed_sum(scope), action_url: action_url }
  end
end
