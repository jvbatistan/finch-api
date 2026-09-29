#!/usr/bin/env ruby

require 'uri'
require 'bigdecimal'
require 'date'
require_relative '../../lib/test_database_safety'

module E2EFixture
  class UnsafeFixtureError < StandardError; end

  PROTECTED_DATABASE_VARIABLES = %w[
    DATABASE_URL_DEVEL DATABASE_URL_DEVELOPMENT DATABASE_URL_LOCAL
    DATABASE_URL_PRODUCTION
  ].freeze
  EMAIL_VARIABLES = %w[FINCH_E2E_EMAIL_A FINCH_E2E_EMAIL_B].freeze
  PASSWORD_VARIABLES = %w[FINCH_E2E_PASSWORD_A FINCH_E2E_PASSWORD_B].freeze
  LOCAL_HOSTS = %w[localhost 127.0.0.1 ::1].freeze
  LOOPBACK_ADDRESSES = %w[127.0.0.1 ::1].freeze
  INTERNAL_TABLES = %w[ar_internal_metadata schema_migrations].freeze
  ACCOUNT_NAME = 'Finch E2E Account A'.freeze
  INITIAL_BALANCE = BigDecimal('1000.00')
  INITIAL_BALANCE_DATE = Date.new(2020, 1, 1)

  module_function

  def validate_environment!(environment)
    raise UnsafeFixtureError, 'E2E fixture requires RAILS_ENV=test.' unless environment['RAILS_ENV'] == 'test'
    raise UnsafeFixtureError, 'E2E fixture requires FINCH_E2E_CSRF=1.' unless environment['FINCH_E2E_CSRF'] == '1'

    url = environment['DATABASE_URL_TEST']
    protected_urls = PROTECTED_DATABASE_VARIABLES.to_h { |key| [key, environment[key]] }
    TestDatabaseSafety.validate!(environment: 'test', test_url: url, protected_urls: protected_urls)
    uri = URI.parse(url)
    unless LOCAL_HOSTS.include?(uri.host.to_s.downcase) && uri.port && uri.query.nil? && uri.fragment.nil?
      raise UnsafeFixtureError, 'E2E fixture requires a local PostgreSQL URL with explicit port and no overrides.'
    end

    emails = EMAIL_VARIABLES.map { |key| environment[key].to_s }
    unless emails.all? { |email| email.match?(/\A[a-z0-9][a-z0-9._+-]*@example\.test\z/) } && emails.uniq.size == 2
      raise UnsafeFixtureError, 'E2E fixture requires two distinct synthetic @example.test emails.'
    end

    unless PASSWORD_VARIABLES.all? { |key| environment[key].to_s.length >= 8 }
      raise UnsafeFixtureError, 'E2E fixture requires two ephemeral passwords of at least eight characters.'
    end

    uri
  rescue TestDatabaseSafety::UnsafeDatabaseError => error
    raise UnsafeFixtureError, error.message
  end

  def validate_resolved_configuration!(uri, configuration)
    settings = configuration.configuration_hash.transform_keys(&:to_sym)
    expected = TestDatabaseSafety.parse_target!(uri.to_s, variable_name: 'DATABASE_URL_TEST')
    resolved = TestDatabaseSafety::DatabaseTarget.new(
      adapter: TestDatabaseSafety.normalize_adapter(settings[:adapter]),
      host: settings[:host].to_s.downcase,
      port: settings[:port].to_i,
      database: settings[:database].to_s.downcase
    )
    raise UnsafeFixtureError, 'Resolved database differs from validated E2E test target.' unless resolved == expected

    expected
  end

  def validate_connection!(expected, connection)
    database = connection.select_value('SELECT current_database()')
    address = connection.select_value('SELECT inet_server_addr()::text')
    port = connection.select_value('SHOW port')
    unless database == expected.database && LOOPBACK_ADDRESSES.include?(address) && port.to_i == expected.port
      raise UnsafeFixtureError, 'Connected database is not the validated local E2E test target.'
    end
  end

  def ensure_non_fixture_tables_empty!(connection)
    connection.data_sources.each do |table|
      next if (INTERNAL_TABLES + %w[users accounts]).include?(table)

      if connection.select_value("SELECT 1 FROM #{connection.quote_table_name(table)} LIMIT 1")
        raise UnsafeFixtureError, 'Test database contains non-fixture data.'
      end
    end
  end

  def existing_fixture_intact?(environment, emails)
    return false unless User.count == 2 && Account.count == 1
    return false if User.where.not(email: emails).exists?

    users = emails.each_with_index.map do |email, index|
      user = User.find_by(email: email)
      return false unless user && user.name == "Finch E2E #{index.zero? ? 'A' : 'B'}" && user.active?
      return false unless user.valid_password?(environment.fetch(PASSWORD_VARIABLES[index]))

      user
    end

    account = Account.first
    account.user_id == users.first.id && account.name == ACCOUNT_NAME &&
      account.kind == 'checking' && account.initial_balance == INITIAL_BALANCE &&
      account.initial_balance_date == INITIAL_BALANCE_DATE && account.archived_at.nil? &&
      account.current_balance == INITIAL_BALANCE
  end

  def prepare!(environment: ENV)
    uri = validate_environment!(environment)
    raise UnsafeFixtureError, 'E2E fixture requires the Rails test environment.' unless Rails.env.test?

    emails = EMAIL_VARIABLES.map { |key| environment.fetch(key) }
    ApplicationRecord.connected_to(role: :writing, shard: :local) do
      expected = validate_resolved_configuration!(uri, ApplicationRecord.connection_db_config)
      connection = ApplicationRecord.connection
      validate_connection!(expected, connection)
      ensure_non_fixture_tables_empty!(connection)

      User.transaction do
        if User.where.not(email: emails).exists?
          raise UnsafeFixtureError, 'Test database contains users outside the E2E fixture.'
        end

        if User.count.positive? || Account.count.positive?
          raise UnsafeFixtureError, 'Test database has incomplete or modified E2E fixture state.' unless existing_fixture_intact?(environment, emails)

          next
        end

        users = emails.each_with_index.map do |email, index|
          User.create!(
            email: email,
            name: "Finch E2E #{index.zero? ? 'A' : 'B'}",
            active: true,
            password: environment.fetch(PASSWORD_VARIABLES[index]),
            password_confirmation: environment.fetch(PASSWORD_VARIABLES[index])
          )
        end

        account = Account.create!(
          user: users.first, name: ACCOUNT_NAME, kind: :checking,
          initial_balance: INITIAL_BALANCE,
          initial_balance_date: INITIAL_BALANCE_DATE, archived_at: nil
        )
        raise UnsafeFixtureError, 'E2E account has no available balance.' unless account.current_balance.positive?
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  warn 'Direct test-fixture execution is disabled; use the guarded development E2E launcher.'
  exit 1
end
