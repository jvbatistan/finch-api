class Transaction < ApplicationRecord
  CARD_STATEMENT_PAYMENT_DESCRIPTION_PATTERN = /(\APAGAMENTO\z|PAGAMENTO\s+RECEBIDO|PAGAMENTO\s+(PRA|PARA)\s+LIBERAR\s+LIMITE|LIBERAR\s+LIMITE|PGTO\s+RECEBIDO|PAGTO\s+RECEBIDO)/i
  CARD_STATEMENT_PAYMENT_MERCHANT_EXCLUSION_PATTERN = /(UBER|99|NUPAY|APPLE|TWITCH|SPOTIFY)/i

  belongs_to :card, optional: true
  belongs_to :category, optional: true
  belongs_to :account, optional: true
  belongs_to :user

  has_many :transaction_payments

  has_many :classification_suggestions, foreign_key: :financial_transaction_id, dependent: :destroy

  enum kind: { income: 0, expense: 1 }
  enum source: { card: 0, cash: 1, bank: 2 }

  validates :description, presence: true
  validates :date,        presence: true
  validates :kind,        presence: true
  validates :source,      presence: true
  validates :value,       presence: true, numericality: { greater_than: 0 }
  validates :installment_number, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :installments_count, numericality: { only_integer: true, greater_than: 1 }, allow_nil: true

  validate :installment_consistency
  validate :refund_consistency
  validate :income_consistency
  validate :card_source_consistency
  validate :account_consistency
  validate :settlement_consistency
  validate :card_statement_payment_must_not_be_transaction
  validate :category_must_belong_to_user

  before_validation :normalize_strings
  before_validation :normalize_income_defaults
  before_validation :set_origin_defaults, on: :create
  before_validation :normalize_settlement
  before_validation :set_billing_statement

  after_create_commit :create_initial_category_suggestion
  after_update_commit :refresh_category_suggestion, if: -> { saved_change_to_description? }

  scope :active,            -> { where(archived_at: nil) }
  scope :archived,          -> { where.not(archived_at: nil) }
  scope :active_for_payments, -> { where(payment_ignored_at: nil) }
  scope :by_month,          ->(month, year) { where("EXTRACT(MONTH FROM date) = ? AND EXTRACT(YEAR FROM date) = ?", month, year) }
  scope :by_period,         ->(start_date, end_date) { where(date: start_date..end_date) }
  scope :by_card,           ->(card_id) { where(card_id: card_id) if card_id.present? }
  scope :by_category,       ->(category_id) { where(category_id: category_id) if category_id.present? }
  scope :by_paid,           ->(paid) do
    return all if paid.nil?

    where(paid: ActiveRecord::Type::Boolean.new.cast(paid))
  end
  scope :expenses,          -> { where(kind: kinds[:expense]) }
  scope :incomes,           -> { where(kind: kinds[:income]) }
  scope :loose_expenses,    -> { expenses.where(source: [sources[:cash], sources[:bank]], card_id: nil) }
  scope :installments_only, -> { where.not(installment_group_id: nil) }
  scope :non_installments,  -> { where(installment_group_id: nil) }

  def self.signed_value_sql(table_name = 'transactions')
    "CASE WHEN #{table_name}.refund THEN -#{table_name}.value ELSE #{table_name}.value END"
  end

  def self.signed_sum(scope = all)
    scope.sum(Arel.sql(signed_value_sql)).to_d
  end

  def installment?
    installment_group_id.present?
  end

  def installment_label
    return nil unless installment?

    "#{installment_number}/#{installments_count}"
  end

  def installment_siblings
    return Transaction.none unless installment?

    user.transactions.active.where(installment_group_id: installment_group_id).order(:installment_number)
  end

  def active?
    archived_at.nil?
  end

  def archived?
    archived_at.present?
  end

  def ignored_for_payment?
    payment_ignored_at.present?
  end

  def signed_value
    refund? ? -value.to_d : value.to_d
  end

  def card_statement_payment_description?
    self.class.card_statement_payment_description?(description)
  end

  def ignore_for_payment!(ignored_at_time: Time.zone.now)
    update!(payment_ignored_at: ignored_at_time)
  end

  def pending_classification_suggestion
    user.classification_suggestions
        .pending
        .where(financial_transaction_id: classification_suggestion_target_ids)
        .order(created_at: :desc)
        .first
  end

  def classification_status
    return 'classified' if category_id.present? && category&.user_id == user_id
    return 'suggestion_pending' if pending_classification_suggestion.present?

    'unclassified'
  end

  def self.total_for_month(month = Date.today.month, year = Date.today.year)
    signed_sum(active.by_month(month, year))
  end

  def self.expenses_total_for(month = Date.today.month, year = Date.today.year)
    signed_sum(active.expenses.by_month(month, year))
  end

  def self.incomes_total_for(month = Date.today.month, year = Date.today.year)
    signed_sum(active.incomes.by_month(month, year))
  end

  def self.balance_for(month = Date.today.month, year = Date.today.year)
    incomes_total_for(month, year) - expenses_total_for(month, year)
  end

  def self.card_statement_payment_description?(description)
    text = description.to_s
    text.match?(CARD_STATEMENT_PAYMENT_DESCRIPTION_PATTERN) && !text.match?(CARD_STATEMENT_PAYMENT_MERCHANT_EXCLUSION_PATTERN)
  end

  def archive!(archived_at_time: Time.current)
    raise ActiveRecord::RecordInvalid.new(self), 'Não é possível arquivar despesa com pagamentos.' if transaction_payments.exists?

    update!(archived_at: archived_at_time)
  end

  def loose_expense?
    expense? && !card? && (cash? || bank?)
  end

  def payments_total
    return transaction_payments.sum(&:amount).to_d if association(:transaction_payments).loaded?

    transaction_payments.sum(:amount).to_d
  end

  def remaining_amount
    value.to_d - payments_total
  end

  def payment_status
    return 'paid' if paid?
    return 'partially_paid' if transaction_payments_loaded? ? transaction_payments.any? : transaction_payments.exists?

    'open'
  end

  def value=(val)
    if val.is_a?(String)
      s = val.strip
      s = s.gsub('.', '').tr(',', '.') if s.include?(',')
      val = s
    end

    normalized_value = val.presence
    normalized_value = normalized_value.to_d.abs if normalized_value.present?

    super(normalized_value)
  end

  def settled_value=(val)
    if val.is_a?(String)
      s = val.strip
      s = s.gsub('.', '').tr(',', '.') if s.include?(',')
      val = s
    end

    normalized_value = val.presence
    normalized_value = normalized_value.to_d.abs if normalized_value.present?

    super(normalized_value)
  end

  def set_billing_statement
    return if income?

    if card_id.present? && date.present?
      BillingStatementService.new(self).call
    else
      self.billing_statement = nil
    end
  end

  private

  def transaction_payments_loaded?
    association(:transaction_payments).loaded?
  end

  def normalize_strings
    self.description = description.to_s.upcase.strip
    self.friendly_title = friendly_title.upcase.strip if friendly_title
    self.responsible = responsible.to_s.upcase.strip
  end

  def normalize_income_defaults
    return unless income?

    self.paid = true
  end

  def set_origin_defaults
    self.purchase_date ||= date
    self.original_value ||= value
  end

  def normalize_settlement
    return unless loose_expense?

    unless paid?
      self.settled_on = nil
      self.settled_value = nil
      return
    end

    return unless new_record?

    self.settled_on ||= date
    self.settled_value ||= value
  end

  def create_initial_category_suggestion
    return if destroyed? || category_id.present?

    Transactions::ClassifyService.new(self).call
  end

  def refresh_category_suggestion
    return if destroyed? || category_id.present?

    Transactions::ClassifyService.new(self, force_recompute: true).call
  end

  def classification_suggestion_target_ids
    return [id].compact unless installment?

    installment_siblings.pluck(:id)
  end

  def installment_consistency
    if installment_group_id.present?
      errors.add(:installment_number, 'é obrigatório quando parcelado') if installment_number.blank?
      errors.add(:installments_count, 'é obrigatório quando parcelado') if installments_count.blank?
    elsif installment_number.present? || installments_count.present?
      errors.add(:base, 'campos de parcela não podem existir sem installment_group_id')
    end
  end

  def refund_consistency
    return unless refund?

    errors.add(:kind, 'deve ser despesa para estornos') unless expense?
    errors.add(:source, 'deve ser cartão para estornos') unless card?
    errors.add(:card, 'é obrigatório para estornos') if card_id.blank?
    errors.add(:base, 'estorno não pode ser parcelado') if installment_number.present? || installments_count.present? || installment_group_id.present?
  end

  def income_consistency
    return unless income?

    errors.add(:account, 'é obrigatória para receitas') if account_id.blank?
    errors.add(:source, 'não pode ser cartão para receitas') if card?
    errors.add(:card, 'não deve existir para receitas') if card_id.present?
    errors.add(:billing_statement, 'não deve existir para receitas') if billing_statement.present?
    errors.add(:base, 'receita não pode ser parcelada') if installment_group_id.present? || installment_number.present? || installments_count.present?
    errors.add(:payment_ignored_at, 'não deve existir para receitas') if payment_ignored_at.present?
    errors.add(:refund, 'não pode ser verdadeiro para receitas') if refund?
  end

  def card_source_consistency
    return unless expense? && (cash? || bank?) && card_id.present?

    errors.add(:card, 'não deve existir para origem dinheiro ou banco')
  end

  def account_consistency
    if account_id.present? && account.nil?
      errors.add(:account, 'inválida')
      return
    end

    if account.present?
      errors.add(:account, 'deve pertencer ao mesmo usuário') if user_id.present? && account.user_id != user_id
      errors.add(:account, 'não pode estar arquivada') if account_must_be_active? && account.archived?
    end

    if income?
      errors.add(:account, 'é obrigatória para receitas') if account_id.blank?
      return
    end

    return unless expense?

    if card?
      errors.add(:card, 'é obrigatório para despesas no cartão') if card.blank? && card_id.blank?
      errors.add(:account, 'não deve existir para despesas no cartão') if account_id.present?
    elsif account_required_for_cash_or_bank_expense?
      errors.add(:account, 'é obrigatória para despesas sem cartão') if account_id.blank?
    end
  end

  def settlement_consistency
    return unless loose_expense?

    return if transaction_payments.exists?

    if paid?
      settlement_required = new_record? || (will_save_change_to_paid? && paid?)
      return unless settlement_required

      errors.add(:settled_on, 'é obrigatória para despesas pagas sem cartão') if settled_on.blank?
      if settled_value.blank?
        errors.add(:settled_value, 'é obrigatório para despesas pagas sem cartão')
      elsif settled_value.to_d <= 0
        errors.add(:settled_value, 'deve ser maior que zero')
      end
    elsif settled_on.present? || settled_value.present?
      errors.add(:base, 'realização não pode existir para despesa em aberto')
    end
  end

  def account_must_be_active?
    return true if new_record?

    return true if will_save_change_to_account_id? ||
      will_save_change_to_kind? ||
      will_save_change_to_source? ||
      will_save_change_to_card_id?

    return false if transaction_payments.exists?

    will_save_change_to_paid? && paid?
  end

  def account_required_for_cash_or_bank_expense?
    return false if card?
    return false unless paid?
    return false if transaction_payments.exists?
    return true if new_record?

    will_save_change_to_kind? ||
      will_save_change_to_source? ||
      will_save_change_to_card_id? ||
      will_save_change_to_account_id? ||
      will_save_change_to_paid?
  end

  def card_statement_payment_must_not_be_transaction
    return if archived?
    return unless card? && card_statement_payment_description?

    errors.add(:base, 'pagamento de fatura deve ser registrado na tela de pagamentos, não como transação')
  end

  def category_must_belong_to_user
    return if category.nil? || user.nil?
    return if category.user_id == user_id

    errors.add(:category, 'deve pertencer ao mesmo usuário')
  end
end
