require 'spec_helper'
require_relative '../../script/e2e/prepare_development_fixture'

RSpec.describe E2EDevelopmentFixture do
  it 'does not access or change the production database variable in this preparer' do
    source = File.read(File.expand_path('../../script/e2e/prepare_development_fixture.rb', __dir__))
    forbidden_access = /\bENV\s*(?:\[|\.fetch\s*\()\s*['"]DATABASE_URL['"]|\bENV\.(?:delete|store)\s*\(\s*['"]DATABASE_URL['"]/
    expect(source).not_to match(forbidden_access)
  end

  it 'requires the launcher to remove the production database variable before Ruby starts' do
    launcher = File.read(File.expand_path('../../script/e2e/prepare_development_fixture', __dir__))
    expect(launcher).to include('exec env -u DATABASE_URL RUBYOPT=')
    expect(launcher).to include('disable_dotenv.rb')
    source = File.read(File.expand_path('../../script/e2e/prepare_development_fixture.rb', __dir__))
    expect(source).to include("if $PROGRAM_NAME == __FILE__\n  warn 'Use script/e2e/prepare_development_fixture")
  end

  let(:url) { 'postgresql://fixture:password@localhost:5432/finch_api_development' }
  let(:environment) do
    {
      'RAILS_ENV' => 'development', 'FINCH_E2E_DEVEL_DB' => '1',
      'DATABASE_URL_DEVEL' => url,
      'FINCH_E2E_EMAIL_A' => 'finch-e2e-a@example.test',
      'FINCH_E2E_EMAIL_B' => 'finch-e2e-b@example.test',
      'FINCH_E2E_PASSWORD_A' => 'ephemeral-a',
      'FINCH_E2E_PASSWORD_B' => 'ephemeral-b'
    }
  end

  it 'requires development, an explicit opt-in, and a PostgreSQL development target' do
    expect(described_class.validate_environment!(environment)).to be_a(URI::Generic)
    [
      { 'RAILS_ENV' => 'test' }, { 'FINCH_E2E_DEVEL_DB' => nil },
      { 'DATABASE_URL_DEVEL' => nil },
      { 'DATABASE_URL_DEVEL' => 'sqlite3:///finch_development' }
    ].each do |override|
      expect { described_class.validate_environment!(environment.merge(override)) }
        .to raise_error(described_class::UnsafeFixtureError)
    end
  end

  it 'rejects any host, port, or database outside the approved disposable local target' do
    approved = 'postgresql://fixture:password@localhost:5432/finch_api_development'
    expect(described_class.validate_environment!(environment.merge('DATABASE_URL_DEVEL' => approved)))
      .to be_a(URI::Generic)

    [
      'postgresql://fixture:password@db.example.test:5432/finch_api_development',
      'postgresql://fixture:password@127.0.0.2:5432/finch_api_development',
      'postgresql://fixture:password@localhost:5433/finch_api_development',
      'postgresql://fixture:password@localhost:5432/finch_development',
      'postgresql://fixture:password@localhost:5432/finch_api_development_other'
    ].each do |unsafe_url|
      expect { described_class.validate_environment!(environment.merge('DATABASE_URL_DEVEL' => unsafe_url)) }
        .to raise_error(described_class::UnsafeFixtureError)
    end
  end

  it 'requires two distinct, prefixed synthetic identities and valid passwords' do
    [
      { 'FINCH_E2E_EMAIL_A' => 'a@example.test' },
      { 'FINCH_E2E_EMAIL_B' => 'finch-e2e-a@example.test' },
      { 'FINCH_E2E_EMAIL_B' => 'finch-e2e-b@example.com' },
      { 'FINCH_E2E_PASSWORD_A' => '' },
      { 'DATA_ENVIRONMENT_LOCAL_OPERATOR_EMAIL' => 'finch-e2e-a@example.test' }
    ].each do |override|
      expect { described_class.validate_environment!(environment.merge(override)) }
        .to raise_error(described_class::UnsafeFixtureError)
    end
  end

  it 'rejects a resolved target outside the local development shard before a connection' do
    configuration = double(configuration_hash: {
      adapter: 'postgresql', host: 'localhost', port: 5432, database: 'other_development'
    })
    expect do
      described_class.validate_resolved_configuration!(URI.parse(url), configuration)
    end.to raise_error(described_class::UnsafeFixtureError, /resolved database/i)
  end

  it 'requires the manual operator before any mutation' do
    stub_const('Rails', double(env: double(development?: true)))
    stub_const('ApplicationRecord', class_double('ApplicationRecord')) unless defined?(ApplicationRecord)
    allow(ApplicationRecord).to receive(:connected_to).with(role: :writing, shard: :local).and_yield
    allow(ApplicationRecord).to receive(:connection_db_config).and_return(double(configuration_hash: {
      adapter: 'postgresql', host: 'localhost', port: 5432, database: 'finch_api_development'
    }))
    user_model = class_double('User')
    stub_const('User', user_model)
    allow(user_model).to receive(:transaction).and_yield
    allow(user_model).to receive(:find_by).with(email: 'homologacao@finch.local').and_return(nil)
    expect(user_model).not_to receive(:where)
    expect(user_model).not_to receive(:new)

    expect { described_class.prepare!(environment: environment) }
      .to raise_error(described_class::UnsafeFixtureError, /operator/i)
  end

  it 'does not expose fixture creation as a callable entrypoint' do
    expect(described_class).not_to respond_to(:create_fixture!)
    expect(described_class).not_to respond_to(:delete_graph!)
  end

  it 'refuses a third prefixed E2E identity before cleanup or creation' do
    stub_const('Rails', double(env: double(development?: true)))
    stub_const('ApplicationRecord', class_double('ApplicationRecord')) unless defined?(ApplicationRecord)
    allow(ApplicationRecord).to receive(:connected_to).with(role: :writing, shard: :local).and_yield
    allow(ApplicationRecord).to receive(:connection_db_config).and_return(double(configuration_hash: {
      adapter: 'postgresql', host: 'localhost', port: 5432, database: 'finch_api_development'
    }))
    user_model = class_double('User')
    stub_const('User', user_model)
    allow(user_model).to receive(:transaction).and_yield
    allow(user_model).to receive(:find_by).with(email: 'homologacao@finch.local').and_return(double('operator'))
    users = %w[finch-e2e-a@example.test finch-e2e-b@example.test finch-e2e-third@example.test]
              .map { |email| double(email: email) }
    allow(user_model).to receive(:where).with('LOWER(email) LIKE ?', 'finch-e2e-%').and_return(double(to_a: users))
    expect(described_class).not_to receive(:delete_graph!)
    expect(user_model).not_to receive(:new)

    %i[prepare cleanup].each do |mode|
      expect { described_class.prepare!(environment: environment, mode: mode) }
        .to raise_error(described_class::UnsafeFixtureError, /unexpected e2e identity/i)
    end
  end

  it 'rejects an unexpected owned resource before deleting any fixture row' do
    user = double(id: 10, categories: double(exists?: true))
    expect do
      described_class.validate_graph!([user])
    end.to raise_error(described_class::UnsafeFixtureError, /unexpected/i)
  end

  it 'rejects an unexpected financial record type before cleanup' do
    empty = double(exists?: false)
    user = double(id: 10, cards: [], categories: empty, account_transfers: empty,
                  classification_suggestions: empty, merchant_aliases: empty,
                  accounts: [double(id: 20, user_id: 10, kind: 'checking',
                                    card_statement_payments: empty, outgoing_transfers: empty,
                                    incoming_transfers: empty)],
                  transactions: [double(id: 30, user_id: 10, card_id: nil,
                                        category_id: nil, billing_statement: nil,
                                        installment_group_id: nil, account_id: 20,
                                        kind: 'expense', source: 'card',
                                        classification_suggestions: empty)])
    expect do
      described_class.validate_graph!([user])
    end.to raise_error(described_class::UnsafeFixtureError, /unexpected/i)
  end

  it 'rejects a transaction pointing to the other E2E user account' do
    empty = double(exists?: false)
    accounts = [11, 12].map do |id|
      double(id: id + 10, user_id: id, kind: 'checking', card_statement_payments: empty,
             outgoing_transfers: empty, incoming_transfers: empty)
    end
    transaction = double(id: 31, user_id: 11, card_id: nil, category_id: nil,
                         billing_statement: nil, installment_group_id: nil,
                         account_id: 22, kind: 'expense', source: 'bank',
                         classification_suggestions: empty)
    users = [11, 12].each_with_index.map do |id, index|
      double(id: id, cards: [], categories: empty, account_transfers: empty,
             classification_suggestions: empty, merchant_aliases: empty,
             accounts: [accounts[index]], transactions: index.zero? ? [transaction] : [])
    end
    expect do
      described_class.validate_graph!(users)
    end.to raise_error(described_class::UnsafeFixtureError, /unexpected/i)
  end

  def fixture_user(id:, transactions:, suggestions:)
    empty = double(exists?: false)
    double(id: id, cards: [], categories: empty, account_transfers: empty,
           merchant_aliases: empty, accounts: [], transactions: transactions,
           classification_suggestions: double(exists?: !suggestions.empty?, to_a: suggestions))
  end

  def fixture_transaction(id:, user_id:)
    double(id: id, user_id: user_id, kind: 'expense', source: 'bank',
           card_id: nil, category_id: nil, billing_statement: nil,
           installment_group_id: nil, account_id: nil,
           classification_suggestions: double(exists?: true))
  end

  def fixture_card_graph(card_owner: 11, expense_owner: 11, payment_account_id: 21)
    card = double(id: 41, user_id: card_owner, name: 'FINCH E2E CARD A')
    period = Date.new(2026, 11, 1)
    due_date = Date.new(2026, 11, 15)
    allow(card).to receive(:due_on).with(2026, 11).and_return(due_date)
    expense = double(id: 31, user_id: expense_owner, kind: 'expense', source: 'card',
                     card_id: 41, category_id: nil, billing_statement: period,
                     installment_group_id: nil, account_id: nil, value: BigDecimal('0.50'))
    payment = double(id: 61, card_statement_id: 51, account_id: payment_account_id,
                     original_transaction_id: nil, source: 'manual', amount: BigDecimal('0.25'))
    statement = double(id: 51, card_id: 41, billing_statement: due_date,
                       total_amount: BigDecimal('0.50'), paid_amount: BigDecimal('0.25'),
                       card_statement_payments: [payment])
    allow(card).to receive(:card_statements).and_return([statement])
    account = double(id: 21, user_id: 11, kind: 'checking',
                     outgoing_transfers: double(exists?: false), incoming_transfers: double(exists?: false))
    user_a = fixture_user(id: 11, transactions: expense_owner == 11 ? [expense] : [], suggestions: [])
    user_b = fixture_user(id: 12, transactions: expense_owner == 12 ? [expense] : [], suggestions: [])
    allow(user_a).to receive(:cards).and_return(card_owner == 11 ? [card] : [])
    allow(user_b).to receive(:cards).and_return(card_owner == 12 ? [card] : [])
    allow(user_a).to receive(:accounts).and_return([account])

    card_statement_model = class_double('CardStatement')
    stub_const('CardStatement', card_statement_model)
    safe_relation = double('safe scoped relation')
    allow(safe_relation).to receive(:where).and_return(safe_relation)
    allow(safe_relation).to receive(:not).and_return(double(exists?: false))
    allow(card_statement_model).to receive(:where).with(card_id: [41])
      .and_return(safe_relation)
    transaction_model = class_double('Transaction')
    stub_const('Transaction', transaction_model)
    allow(transaction_model).to receive(:where).with(card_id: [41])
      .and_return(safe_relation)
    statement_payment_model = class_double('CardStatementPayment')
    stub_const('CardStatementPayment', statement_payment_model)
    allow(statement_payment_model).to receive(:where).with(card_statement_id: [51])
      .and_return(safe_relation)
    allow(statement_payment_model).to receive(:where).with(account_id: [21])
      .and_return(safe_relation)
    transaction_payment_model = class_double('TransactionPayment')
    stub_const('TransactionPayment', transaction_payment_model)
    allow(transaction_payment_model).to receive(:where).with(transaction_id: [31]).and_return(double(to_a: []))
    allow(transaction_payment_model).to receive(:where).with(account_id: [21])
      .and_return(safe_relation)
    allow(transaction_model).to receive(:where).with(account_id: [21])
      .and_return(safe_relation)
    classification_model = class_double('ClassificationSuggestion')
    stub_const('ClassificationSuggestion', classification_model)
    allow(classification_model).to receive(:where).with(financial_transaction_id: [31])
      .and_return(double(to_a: []))
    [user_a, user_b]
  end

  it 'accepts one A-owned card expense, statement, and account payment for cleanup' do
    users = fixture_card_graph
    expect(described_class.validate_graph!(users)).to eq(
      suggestions: [], payments: [], card_statement_payments: [61], transactions: [31],
      card_statements: [51], cards: [41], accounts: [21], users: [11, 12]
    )
  end

  it 'rejects a card expense assigned to B before cleanup' do
    users = fixture_card_graph(expense_owner: 12)
    expect { described_class.validate_graph!(users) }
      .to raise_error(described_class::UnsafeFixtureError, /transaction resource/i)
  end

  it 'rejects a card statement payment from an account outside A' do
    users = fixture_card_graph(payment_account_id: 99)
    expect { described_class.validate_graph!(users) }
      .to raise_error(described_class::UnsafeFixtureError, /statement payment/i)
  end

  it 'rejects a statement total that no longer matches the synthetic card expense' do
    users = fixture_card_graph
    statement = users.first.cards.first.card_statements.first
    allow(statement).to receive(:total_amount).and_return(BigDecimal('0.75'))
    expect { described_class.validate_graph!(users) }
      .to raise_error(described_class::UnsafeFixtureError, /statement period/i)
  end

  it 'rejects a statement whose due date does not match the card cycle' do
    users = fixture_card_graph
    statement = users.first.cards.first.card_statements.first
    allow(statement).to receive(:billing_statement).and_return(Date.new(2026, 11, 16))
    expect { described_class.validate_graph!(users) }
      .to raise_error(described_class::UnsafeFixtureError, /statement period/i)
  end

  it 'rejects an unexpected payment linked to the E2E account' do
    users = fixture_card_graph
    relation = double('account payments')
    allow(relation).to receive(:where).and_return(relation)
    allow(relation).to receive(:not).and_return(double(exists?: true))
    allow(CardStatementPayment).to receive(:where).with(account_id: [21]).and_return(relation)
    expect { described_class.validate_graph!(users) }
      .to raise_error(described_class::UnsafeFixtureError, /statement payment/i)
  end

  it 'accepts a suggestion owned by the E2E transaction owner and includes it in cleanup' do
    transaction = fixture_transaction(id: 31, user_id: 11)
    suggestion = double(id: 51, user_id: 11, financial_transaction_id: 31,
                        suggested_category_id: nil)
    user = fixture_user(id: 11, transactions: [transaction], suggestions: [suggestion])
    stub_const('ClassificationSuggestion', class_double('ClassificationSuggestion'))
    allow(ClassificationSuggestion).to receive(:where).with(financial_transaction_id: [31])
      .and_return(double(to_a: [suggestion]))
    stub_const('TransactionPayment', class_double('TransactionPayment'))
    allow(TransactionPayment).to receive(:where).with(transaction_id: [31]).and_return(double(to_a: []))

    expect(described_class.validate_graph!([user]))
      .to eq(suggestions: [51], payments: [], card_statement_payments: [], transactions: [31],
             card_statements: [], cards: [], accounts: [], users: [11])
  end

  it 'refuses a suggestion linked to an external category before cleanup' do
    transaction = fixture_transaction(id: 31, user_id: 11)
    suggestion = double(id: 51, user_id: 11, financial_transaction_id: 31,
                        suggested_category_id: 99)
    user = fixture_user(id: 11, transactions: [transaction], suggestions: [suggestion])
    stub_const('ClassificationSuggestion', class_double('ClassificationSuggestion'))
    allow(ClassificationSuggestion).to receive(:where).with(financial_transaction_id: [31])
      .and_return(double(to_a: [suggestion]))
    stub_const('TransactionPayment', class_double('TransactionPayment'))
    allow(TransactionPayment).to receive(:where).with(transaction_id: [31]).and_return(double(to_a: []))

    expect { described_class.validate_graph!([user]) }
      .to raise_error(described_class::UnsafeFixtureError, /unexpected/i)
  end

  it 'refuses a suggestion on an E2E transaction when another user owns it' do
    transaction = fixture_transaction(id: 31, user_id: 11)
    suggestion = double(id: 51, user_id: 99, financial_transaction_id: 31)
    user = fixture_user(id: 11, transactions: [transaction], suggestions: [])
    stub_const('ClassificationSuggestion', class_double('ClassificationSuggestion'))
    allow(ClassificationSuggestion).to receive(:where).with(financial_transaction_id: [31])
      .and_return(double(to_a: [suggestion]))

    expect { described_class.validate_graph!([user]) }
      .to raise_error(described_class::UnsafeFixtureError, /unexpected/i)
  end

  it 'refuses a suggestion linked across the two E2E users' do
    transaction = fixture_transaction(id: 31, user_id: 11)
    suggestion = double(id: 51, user_id: 12, financial_transaction_id: 31)
    users = [fixture_user(id: 11, transactions: [transaction], suggestions: []),
             fixture_user(id: 12, transactions: [], suggestions: [suggestion])]
    stub_const('ClassificationSuggestion', class_double('ClassificationSuggestion'))
    allow(ClassificationSuggestion).to receive(:where).with(financial_transaction_id: [31])
      .and_return(double(to_a: [suggestion]))

    expect { described_class.validate_graph!(users) }
      .to raise_error(described_class::UnsafeFixtureError, /unexpected/i)
  end

  it 'refuses a suggestion owned by an E2E user outside E2E transactions' do
    suggestion = double(id: 51, user_id: 11, financial_transaction_id: 99)
    user = fixture_user(id: 11, transactions: [], suggestions: [suggestion])

    expect { described_class.validate_graph!([user]) }
      .to raise_error(described_class::UnsafeFixtureError, /unexpected/i)
  end

  it 'deletes only approved fixture IDs in dependency order' do
    records = { suggestions: [51], payments: [41], card_statement_payments: [61],
                transactions: [31], card_statements: [71], cards: [81],
                accounts: [21], users: [11, 12] }
    calls = []
    stub_const('Rails', double(env: double(development?: true)))
    stub_const('ApplicationRecord', class_double('ApplicationRecord')) unless defined?(ApplicationRecord)
    allow(ApplicationRecord).to receive(:connected_to).with(role: :writing, shard: :local).and_yield
    allow(ApplicationRecord).to receive(:connection_db_config).and_return(double(configuration_hash: {
      adapter: 'postgresql', host: 'localhost', port: 5432, database: 'finch_api_development'
    }))
    %w[ClassificationSuggestion TransactionPayment CardStatementPayment Transaction CardStatement Card Account User].zip(records.values).each do |name, ids|
      model = double(name)
      stub_const(name, model)
      relation = double('scoped relation')
      expect(model).to receive(:where).with(id: ids).and_return(relation)
      expect(relation).to receive(:delete_all) { calls << name }
    end
    allow(User).to receive(:transaction).and_yield
    operator = double('operator')
    allow(User).to receive(:find_by).with(email: 'homologacao@finch.local').and_return(operator)
    expect(operator).not_to receive(:destroy!)
    expect(operator).not_to receive(:delete)
    allow(User).to receive(:where).with('LOWER(email) LIKE ?', 'finch-e2e-%').and_return(double(to_a: []))
    allow(described_class).to receive(:validate_graph!).with([]).and_return(records)

    described_class.prepare!(environment: environment, mode: :cleanup)
    expect(calls).to eq(%w[ClassificationSuggestion TransactionPayment CardStatementPayment Transaction CardStatement Card Account User])
  end

  it 'creates A/B through the fixture-only user-limit exception and leaves the operator untouched' do
    operator = double('operator')
    stub_const('Rails', double(env: double(development?: true)))
    stub_const('ApplicationRecord', class_double('ApplicationRecord')) unless defined?(ApplicationRecord)
    allow(ApplicationRecord).to receive(:connected_to).with(role: :writing, shard: :local).and_yield
    allow(ApplicationRecord).to receive(:connection_db_config).and_return(double(configuration_hash: {
      adapter: 'postgresql', host: 'localhost', port: 5432, database: 'finch_api_development'
    }))
    user_a = double(id: 11)
    user_b = double(id: 12)
    user_model = class_double('User')
    stub_const('User', user_model)
    allow(user_model).to receive(:transaction).and_yield
    allow(user_model).to receive(:find_by).with(email: 'homologacao@finch.local').and_return(operator)
    allow(user_model).to receive(:where).with('LOWER(email) LIKE ?', 'finch-e2e-%')
      .and_return(double(to_a: []))
    expect(described_class).to receive(:delete_graph!).with({ suggestions: [], payments: [], card_statement_payments: [],
                                                               transactions: [], card_statements: [], cards: [],
                                                               accounts: [], users: [] })
    allow(user_model).to receive(:new).and_return(user_a, user_b)
    expect(user_a).to receive(:save!).with(validate: false)
    expect(user_b).to receive(:save!).with(validate: false)
    expect(operator).not_to receive(:save!)
    expect(operator).not_to receive(:destroy!)
    account_model = class_double('Account')
    stub_const('Account', account_model)
    expect(account_model).to receive(:create!).with(hash_including(user: user_a, kind: :checking))
    card_model = double('Card')
    stub_const('Card', card_model)
    expect(card_model).to receive(:create!).with(hash_including(user: user_a, name: 'Finch E2E Card A'))

    described_class.prepare!(environment: environment)
  end

  it 'starts the fixture CLI with dotenv disabled before Rails can load database configuration' do
    launcher = File.read(File.expand_path('../../script/e2e/prepare_development_fixture', __dir__))

    expect(launcher).not_to match(/DATABASE_URL=''/)
  end
end
