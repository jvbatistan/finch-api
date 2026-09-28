class Api::TransactionsController < Api::BaseController
  UNSET = Object.new.freeze
  before_action :authenticate_user!
  before_action :set_transaction, only: %i[update destroy]

  def index
    scope = filtered_transactions_scope
    total_count = scope.count
    transactions = scope.includes(transaction_payments: :account).offset((transactions_page - 1) * transactions_per_page).limit(transactions_per_page).to_a
    pending_suggestions = pending_suggestions_for(transactions)

    payload = transactions.map do |transaction|
      tx_json(
        transaction,
        pending_suggestion: pending_suggestions.fetch(transaction.id),
        category: transaction.category,
        account: transaction.account
      )
    end
    render json: { transactions: payload, pagination: { page: transactions_page, per_page: transactions_per_page, total_count: total_count, total_pages: (total_count.to_f / transactions_per_page).ceil } }
  end

  def export_csv
    csv = Transactions::CsvExportService.call(filtered_transactions_scope.limit(transactions_limit))

    send_data(
      "\uFEFF#{csv}",
      filename: "finch-transacoes-#{Time.zone.today.iso8601}.csv",
      type: 'text/csv; charset=utf-8',
      disposition: 'attachment'
    )
  end

  def create
    transaction = current_user.transactions.new(create_transaction_params)
    create_as_paid_loose_expense = transaction.loose_expense? && transaction.paid?

    unless valid_card_and_category_owner?(transaction)
      return render json: { error: transaction.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end

    if transaction.income? && income_installment_params_present?
      return render json: { error: 'Receita não pode ser parcelada' }, status: :unprocessable_entity
    end

    if transaction.refund? && installment_request?
      return render json: { error: 'Estorno não pode ser parcelado' }, status: :unprocessable_entity
    end

    if installment_request?
      group_id = Transactions::InstallmentGeneratorService.new(
        transaction,
        current_installment: requested_installment_number,
        final_installment: requested_installments_count
      ).call

      installments = current_user.transactions
                                 .active
                                 .includes(:category, :card, :account, :classification_suggestions)
                                 .where(installment_group_id: group_id)
                                 .order(:installment_number)

      sync_statement_targets(installments)

      return render json: {
        installment_group_id: group_id,
        transactions: installments.map { |installment| tx_json(installment) }
      }, status: :created
    end

    clear_installment_attributes(transaction)

    if create_as_paid_loose_expense
      unless transaction.valid?
        return render json: { error: transaction.errors.full_messages.to_sentence }, status: :unprocessable_entity
      end

      create_paid_loose_expense!(transaction)
      Transactions::ClassifyService.new(transaction).call
      transaction.reload
      return render json: tx_json(transaction), status: :created
    end

    if transaction.save
      Transactions::ClassifyService.new(transaction).call
      sync_statement_targets(transaction)
      transaction.reload

      render json: tx_json(transaction), status: :created
    else
      render json: { error: transaction.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
  end

  def update
    if @transaction.transaction_payments.exists? && transaction_params.slice(:value, :paid, :source, :kind, :card_id).present?
      return render json: { error: 'Não é possível alterar a estrutura ou reabrir uma despesa com pagamentos.' }, status: :unprocessable_entity
    end

    previous_targets = statement_targets_for(@transaction)
    @transaction.assign_attributes(transaction_params.except(:installment_number, :installments_count))

    unless valid_card_and_category_owner?(@transaction)
      return render json: { error: @transaction.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end

    if settling_open_loose_expense?(@transaction)
      unless @transaction.valid?
        return render json: { error: @transaction.errors.full_messages.to_sentence }, status: :unprocessable_entity
      end

      settle_updated_loose_expense!(@transaction)
      Transactions::ClassifyService.new(
        @transaction,
        force_recompute: @transaction.saved_change_to_description?
      ).call
      @transaction.reload
      return render json: tx_json(@transaction), status: :ok
    end

    if @transaction.save
      Transactions::ClassifyService.new(
        @transaction,
        force_recompute: @transaction.saved_change_to_description?
      ).call

      sync_statement_targets(previous_targets + statement_targets_for(@transaction))
      @transaction.reload
      render json: tx_json(@transaction), status: :ok
    else
      render json: { error: @transaction.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
  end

  def destroy
    previous_targets = statement_targets_for(@transaction)
    @transaction.archive!
    sync_statement_targets(previous_targets)
    head :no_content
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def set_transaction
    @transaction = current_user.transactions.active.find(params[:id])
  end

  def filtered_transactions_scope
    scope = current_user.transactions.active.includes(:category, :card, :account).order(date: :desc, id: :desc)

    month   = params[:month].presence
    year    = params[:year].presence
    card_id = params[:card_id].presence

    scope = apply_card_filter(scope, card_id)
    scope = apply_period_filter(scope, month, year, card_id)
    scope
  end

  def apply_card_filter(scope, card_id)
    return scope if card_id.blank?

    if card_id == 'none'
      scope.where(card_id: nil)
    elsif current_user.cards.exists?(card_id)
      scope.where(card_id: card_id)
    else
      scope.none
    end
  end

  def apply_period_filter(scope, month, year, card_id)
    return scope if month.blank? || year.blank?

    begin
      start_date = Date.new(year.to_i, month.to_i, 1)
      end_date   = start_date.end_of_month
    rescue Date::Error
      return scope.none
    end

    if card_id.blank?
      scope.where(
        '(card_id IS NOT NULL AND billing_statement >= ? AND billing_statement <= ?) OR (card_id IS NULL AND date >= ? AND date <= ?)',
        start_date, end_date, start_date, end_date
      )
    elsif card_id == 'none'
      scope.where(date: start_date..end_date)
    else
      scope.where(billing_statement: start_date..end_date)
    end
  end

  def transactions_limit
    limit = params[:limit].presence&.to_i || 50
    [limit, 200].min
  end

  def transactions_page
    value = params[:page].to_i
    value.positive? ? value : 1
  end

  def transactions_per_page
    value = params[:per_page].presence&.to_i || params[:limit].presence&.to_i || 25
    value.positive? ? [value, 100].min : 25
  end

  def transaction_params
    params.require(:transaction).permit(
      :description, :friendly_title, :value, :date, :kind, :source, :paid, :refund,
      :note, :responsible, :card_id, :category_id, :billing_statement,
      :account_id, :installment_number, :installments_count,
      :purchase_date, :original_value, :settled_on, :settled_value
    )
  end

  def create_transaction_params
    attrs = transaction_params.to_h
    attrs['source'] = 'bank' if attrs['kind'] == 'income' && attrs['source'].blank?
    attrs
  end

  def create_paid_loose_expense!(transaction)
    account = transaction.account
    amount = transaction.settled_value || transaction.value
    settled_on = transaction.settled_on || transaction.date

    Transaction.transaction do
      transaction.paid = false
      transaction.settled_on = nil
      transaction.settled_value = nil
      transaction.save!
      Transactions::RegisterPaymentService.new(
        transaction: transaction, account: account, amount: amount,
        settled_on: settled_on, settle: true
      ).call
    end
  end

  def settle_updated_loose_expense!(transaction)
    account = transaction.account
    amount = transaction.settled_value || transaction.value
    settled_on = transaction.settled_on || transaction.date

    Transaction.transaction do
      transaction.paid = false
      transaction.settled_on = nil
      transaction.settled_value = nil
      transaction.save!
      Transactions::RegisterPaymentService.new(
        transaction: transaction, account: account, amount: amount,
        settled_on: settled_on, settle: true
      ).call
    end
  end

  def settling_open_loose_expense?(transaction)
    transaction.loose_expense? && transaction.paid? && transaction.will_save_change_to_paid? && !transaction.transaction_payments.exists?
  end

  def installment_request?
    requested_installments_count > 1
  end

  def requested_installment_number
    transaction_params[:installment_number].presence || 1
  end

  def requested_installments_count
    transaction_params[:installments_count].to_i
  end

  def income_installment_params_present?
    transaction_params[:installment_number].present? || transaction_params[:installments_count].present?
  end

  def clear_installment_attributes(transaction)
    transaction.installment_number = nil
    transaction.installments_count = nil
    transaction.installment_group_id = nil
  end

  def valid_card_and_category_owner?(transaction)
    if transaction.card_id.present? && !current_user.cards.exists?(transaction.card_id)
      transaction.errors.add(:card, 'inválido')
    end

    if transaction.category_id.present? && !current_user.categories.exists?(transaction.category_id)
      raise ActiveRecord::RecordNotFound
    end

    if transaction.account_id.present? && !current_user.accounts.exists?(transaction.account_id)
      transaction.errors.add(:account, 'inválida')
    end

    transaction.errors.empty?
  end

  def tx_json(transaction, pending_suggestion: UNSET, category: UNSET, account: UNSET)
    suggestion = pending_suggestion.equal?(UNSET) ? transaction.pending_classification_suggestion : pending_suggestion
    category = transaction.association(:category).loaded? ? transaction.category : current_user.categories.find_by(id: transaction.category_id) if category.equal?(UNSET)
    account = transaction.association(:account).loaded? ? transaction.account : current_user.accounts.find_by(id: transaction.account_id) if account.equal?(UNSET)

    {
      id: transaction.id,
      description: transaction.description,
      friendly_title: transaction.friendly_title,
      value: transaction.value,
      original_value: transaction.original_value,
      signed_value: transaction.signed_value,
      refund: transaction.refund,
      date: transaction.date,
      purchase_date: transaction.purchase_date,
      settled_on: transaction.settled_on,
      settled_value: transaction.settled_value,
      payments_total: transaction.payments_total,
      remaining_amount: transaction.remaining_amount,
      payment_status: transaction.payment_status,
      payments: transaction_payments_json(transaction),
      kind: transaction.kind,
      source: transaction.source,
      paid: transaction.paid,
      note: transaction.note,
      responsible: transaction.responsible,
      billing_statement: transaction.billing_statement,
      installment_group_id: transaction.installment_group_id,
      installment_number: transaction.installment_number,
      installments_count: transaction.installments_count,
      classification: {
        status: classification_status(transaction, category, suggestion),
        category: category&.as_json(only: %i[id name]),
        suggestion: suggestion_json(suggestion)
      },
      category: category&.as_json(only: %i[id name]),
      card: transaction.card&.as_json(only: %i[id name]),
      account: account&.as_json(only: %i[id name kind])
    }
  end

  def transaction_payment_json(payment)
    { id: payment.id, amount: payment.amount, settled_on: payment.settled_on, account: payment.account&.as_json(only: %i[id name]) }
  end

  def transaction_payments_json(transaction)
    payments = transaction.association(:transaction_payments).loaded? ? transaction.transaction_payments : transaction.transaction_payments.includes(:account).order(settled_on: :desc, id: :desc)
    payments.sort_by { |payment| [payment.settled_on, payment.id] }.reverse.map { |payment| transaction_payment_json(payment) }
  end

  def pending_suggestions_for(transactions)
    transaction_ids = transactions.map(&:id)
    return {} if transaction_ids.empty?

    installment_group_ids = transactions.filter_map(&:installment_group_id).uniq
    sibling_groups = if installment_group_ids.empty?
                       {}
                     else
                       current_user.transactions.active
                                   .where(installment_group_id: installment_group_ids)
                                   .pluck(:id, :installment_group_id)
                                   .group_by(&:last)
                                   .transform_values { |pairs| pairs.map(&:first) }
                     end

    suggestion_target_ids = transaction_ids + sibling_groups.values.flatten
    suggestions_by_transaction_id = current_user.classification_suggestions
                                            .pending
                                            .includes(:suggested_category)
                                            .where(financial_transaction_id: suggestion_target_ids.uniq)
                                            .order(created_at: :desc)
                                            .group_by(&:financial_transaction_id)

    transactions.to_h do |transaction|
      ids = transaction.installment_group_id.present? ? sibling_groups.fetch(transaction.installment_group_id, [transaction.id]) : [transaction.id]
      [transaction.id, ids.flat_map { |id| suggestions_by_transaction_id[id] || [] }.max_by(&:created_at)]
    end
  end

  def classification_status(transaction, category, suggestion)
    return 'classified' if transaction.category_id.present? && category&.user_id == transaction.user_id
    return 'suggestion_pending' if suggestion.present?

    'unclassified'
  end

  def suggestion_json(suggestion)
    return nil if suggestion.nil?

    suggested_category = if suggestion.association(:suggested_category).loaded?
                           suggestion.suggested_category
                         else
                           current_user.categories.find_by(id: suggestion.suggested_category_id)
                         end

    {
      id: suggestion.id,
      confidence: suggestion.confidence,
      source: suggestion.source,
      suggested_category: suggested_category&.as_json(only: %i[id name])
    }
  end

  def statement_targets_for(transaction)
    return [] if transaction.card_id.blank? || transaction.billing_statement.blank?

    [[transaction.card_id, transaction.billing_statement.year, transaction.billing_statement.month]]
  end

  def sync_statement_targets(targets)
    normalized_targets = Array(targets).flat_map do |target|
      target.is_a?(Transaction) ? statement_targets_for(target) : [target]
    end

    normalized_targets.uniq.each do |card_id, year, month|
      card = current_user.cards.find_by(id: card_id)
      next if card.nil?

      card.sync_statement!(month, year)
    end
  end
end
