#!/usr/bin/env ruby
# Invoke through script/e2e/prepare_development_fixture.

require 'uri'
require 'bigdecimal'
require 'date'
require_relative '../../app/services/data_environments/authorization'
require_relative '../../lib/test_database_safety'
require_relative 'development_target'

module E2EDevelopmentFixture
  class UnsafeFixtureError < StandardError; end

  EMAIL_VARIABLES = %w[FINCH_E2E_EMAIL_A FINCH_E2E_EMAIL_B].freeze
  PASSWORD_VARIABLES = %w[FINCH_E2E_PASSWORD_A FINCH_E2E_PASSWORD_B].freeze
  UNEXPECTED_USER_ASSOCIATIONS = %i[
    cards categories account_transfers merchant_aliases
  ].freeze
  ACCOUNT_KINDS = %w[checking savings wallet digital_wallet other].freeze
  TRANSACTION_KINDS = %w[income expense].freeze
  TRANSACTION_SOURCES = %w[cash bank].freeze
  INITIAL_BALANCE = BigDecimal('1000.00')
  INITIAL_BALANCE_DATE = Date.new(2020, 1, 1)

  module_function

  def operator_email(environment)
    environment.fetch('DATA_ENVIRONMENT_LOCAL_OPERATOR_EMAIL',
                      DataEnvironments::Authorization::DEFAULT_LOCAL_OPERATOR_EMAIL).to_s.strip
  end

  def validate_environment!(environment)
    raise UnsafeFixtureError, 'Development fixture requires RAILS_ENV=development.' unless environment['RAILS_ENV'] == 'development'
    raise UnsafeFixtureError, 'Development fixture requires FINCH_E2E_DEVEL_DB=1.' unless environment['FINCH_E2E_DEVEL_DB'] == '1'

    uri = E2EDevelopmentTarget.validate!(environment['DATABASE_URL_DEVEL'])

    emails = EMAIL_VARIABLES.map { |key| environment[key].to_s }
    unless emails.all? { |email| email.match?(/\Afinch-e2e-[a-z0-9][a-z0-9._+-]*@example\.test\z/) } &&
           emails.uniq.length == 2 && !emails.include?(operator_email(environment).downcase)
      raise UnsafeFixtureError, 'Development fixture requires two distinct synthetic identities separate from the operator.'
    end
    unless PASSWORD_VARIABLES.all? { |key| environment[key].to_s.length >= 8 }
      raise UnsafeFixtureError, 'Development fixture requires two ephemeral passwords of at least eight characters.'
    end

    uri
  rescue E2EDevelopmentTarget::UnsafeTargetError, TestDatabaseSafety::UnsafeDatabaseError
    raise UnsafeFixtureError, 'Development fixture requires a valid PostgreSQL development target.'
  end

  def validate_resolved_configuration!(uri, configuration)
    expected = TestDatabaseSafety.parse_target!(uri.to_s, variable_name: 'DATABASE_URL_DEVEL')
    settings = configuration.configuration_hash.transform_keys(&:to_sym)
    resolved = TestDatabaseSafety::DatabaseTarget.new(
      adapter: TestDatabaseSafety.normalize_adapter(settings[:adapter]),
      host: settings[:host].to_s.downcase,
      port: settings[:port].to_i,
      database: settings[:database].to_s.downcase
    )
    raise UnsafeFixtureError, 'Resolved database differs from the development target.' unless resolved == expected

    expected
  end

  def validate_graph!(users)
    ids = users.map(&:id)
    users.each do |user|
      UNEXPECTED_USER_ASSOCIATIONS.each do |association|
        raise UnsafeFixtureError, 'Unexpected E2E user resource.' if user.public_send(association).exists?
      end
    end

    accounts = users.flat_map { |user| user.accounts.to_a }
    transactions = users.flat_map { |user| user.transactions.to_a }
    account_ids = accounts.map(&:id)
    transaction_ids = transactions.map(&:id)
    account_owners = accounts.to_h { |account| [account.id, account.user_id] }
    transaction_owners = transactions.to_h { |transaction| [transaction.id, transaction.user_id] }
    accounts.each do |account|
      if !ids.include?(account.user_id) || !ACCOUNT_KINDS.include?(account.kind) ||
         account.card_statement_payments.exists? ||
         account.outgoing_transfers.exists? || account.incoming_transfers.exists?
        raise UnsafeFixtureError, 'Unexpected E2E account resource.'
      end
    end
    transactions.each do |transaction|
      if !ids.include?(transaction.user_id) || !TRANSACTION_KINDS.include?(transaction.kind) ||
         !TRANSACTION_SOURCES.include?(transaction.source) ||
         transaction.card_id || transaction.category_id ||
         transaction.billing_statement || transaction.installment_group_id ||
         (transaction.account_id && account_owners[transaction.account_id] != transaction.user_id)
        raise UnsafeFixtureError, 'Unexpected E2E transaction resource.'
      end
    end

    owned_suggestions = users.flat_map { |user| user.classification_suggestions.to_a }
    linked_suggestions = transaction_ids.empty? ? [] : ClassificationSuggestion.where(financial_transaction_id: transaction_ids).to_a
    if owned_suggestions.map(&:id).sort != linked_suggestions.map(&:id).sort ||
       linked_suggestions.any? do |suggestion|
         transaction_owners[suggestion.financial_transaction_id] != suggestion.user_id ||
           suggestion.suggested_category_id
       end
      raise UnsafeFixtureError, 'Unexpected E2E classification suggestion.'
    end

    payments = transaction_ids.empty? ? [] : TransactionPayment.where(transaction_id: transaction_ids).to_a
    payment_ids = payments.map(&:id)
    if payments.any? { |payment| account_owners[payment.account_id] != transaction_owners[payment.transaction_id] } ||
       (!account_ids.empty? && TransactionPayment.where(account_id: account_ids).where.not(transaction_id: transaction_ids).exists?) ||
       (!account_ids.empty? && Transaction.where(account_id: account_ids).where.not(user_id: ids).exists?)
      raise UnsafeFixtureError, 'Unexpected cross-user E2E resource.'
    end

    { suggestions: linked_suggestions.map(&:id), payments: payment_ids,
      transactions: transaction_ids, accounts: account_ids, users: ids }
  end

  def delete_graph!(records)
    ClassificationSuggestion.where(id: records.fetch(:suggestions)).delete_all
    TransactionPayment.where(id: records.fetch(:payments)).delete_all
    Transaction.where(id: records.fetch(:transactions)).delete_all
    Account.where(id: records.fetch(:accounts)).delete_all
    User.where(id: records.fetch(:users)).delete_all
  end

  def create_fixture!(environment, operator:)
    raise UnsafeFixtureError, 'Manual operator is missing.' unless operator

    users = EMAIL_VARIABLES.each_with_index.map do |key, index|
      password = environment.fetch(PASSWORD_VARIABLES[index])
      user = User.new(email: environment.fetch(key), name: "Finch E2E #{index.zero? ? 'A' : 'B'}",
                      active: true, password: password, password_confirmation: password)
      # The disposable development fixture has operator + A/B; the public two-user limit stays intact.
      user.save!(validate: false)
      user
    end
    Account.create!(user: users.first, name: 'Finch E2E Account A', kind: :checking,
                    initial_balance: INITIAL_BALANCE, initial_balance_date: INITIAL_BALANCE_DATE,
                    archived_at: nil)
  end

  def prepare!(environment: ENV, mode: :prepare)
    uri = validate_environment!(environment)
    raise UnsafeFixtureError, 'Development fixture requires the Rails development environment.' unless Rails.env.development?
    raise UnsafeFixtureError, 'Unknown development fixture mode.' unless %i[prepare cleanup].include?(mode)

    ApplicationRecord.connected_to(role: :writing, shard: :local) do
      validate_resolved_configuration!(uri, ApplicationRecord.connection_db_config)
      User.transaction do
        operator = User.find_by(email: operator_email(environment))
        raise UnsafeFixtureError, 'Manual operator is missing.' unless operator

        emails = EMAIL_VARIABLES.map { |key| environment.fetch(key) }
        users = User.where('LOWER(email) LIKE ?', 'finch-e2e-%').to_a
        if users.any? { |user| !emails.include?(user.email.to_s) }
          raise UnsafeFixtureError, 'Unexpected E2E identity exists in the development database.'
        end
        records = validate_graph!(users)
        delete_graph!(records)
        create_fixture!(environment, operator: operator) if mode == :prepare
      end
    end
  end

  def run_cli!(arguments = ARGV, environment: ENV)
    raise UnsafeFixtureError, 'Use the development fixture launcher.' unless environment['FINCH_E2E_DEVEL_LAUNCHER'] == '1'

    mode = arguments.empty? ? :prepare : arguments.fetch(0).to_sym
    validate_environment!(environment)
    require_relative '../../config/environment'
    prepare!(environment: environment, mode: mode)
    puts(mode == :cleanup ? 'Development E2E fixture cleaned.' : 'Development E2E fixture prepared.')
  rescue StandardError
    warn 'Development E2E fixture refused or failed; verify the opt-in, operator, and development target.'
    exit 1
  end

  private_class_method :delete_graph!, :create_fixture!
end

if $PROGRAM_NAME == __FILE__
  warn 'Use script/e2e/prepare_development_fixture to run this fixture.'
  exit 1
end
