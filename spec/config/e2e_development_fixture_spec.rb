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
    stub_const('ApplicationRecord', class_double('ApplicationRecord'))
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
    stub_const('ApplicationRecord', class_double('ApplicationRecord'))
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
    user = double(id: 10, cards: double(exists?: true))
    expect do
      described_class.validate_graph!([user])
    end.to raise_error(described_class::UnsafeFixtureError, /unexpected/i)
  end

  it 'rejects an unexpected financial record type before cleanup' do
    empty = double(exists?: false)
    user = double(id: 10, cards: empty, categories: empty, account_transfers: empty,
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
      double(id: id, cards: empty, categories: empty, account_transfers: empty,
             classification_suggestions: empty, merchant_aliases: empty,
             accounts: [accounts[index]], transactions: index.zero? ? [transaction] : [])
    end
    expect do
      described_class.validate_graph!(users)
    end.to raise_error(described_class::UnsafeFixtureError, /unexpected/i)
  end

  def fixture_user(id:, transactions:, suggestions:)
    empty = double(exists?: false)
    double(id: id, cards: empty, categories: empty, account_transfers: empty,
           merchant_aliases: empty, accounts: [], transactions: transactions,
           classification_suggestions: double(exists?: !suggestions.empty?, to_a: suggestions))
  end

  def fixture_transaction(id:, user_id:)
    double(id: id, user_id: user_id, kind: 'expense', source: 'bank',
           card_id: nil, category_id: nil, billing_statement: nil,
           installment_group_id: nil, account_id: nil,
           classification_suggestions: double(exists?: true))
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
      .to eq(suggestions: [51], payments: [], transactions: [31], accounts: [], users: [11])
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
    records = { suggestions: [51], payments: [41], transactions: [31], accounts: [21], users: [11, 12] }
    calls = []
    stub_const('Rails', double(env: double(development?: true)))
    stub_const('ApplicationRecord', class_double('ApplicationRecord'))
    allow(ApplicationRecord).to receive(:connected_to).with(role: :writing, shard: :local).and_yield
    allow(ApplicationRecord).to receive(:connection_db_config).and_return(double(configuration_hash: {
      adapter: 'postgresql', host: 'localhost', port: 5432, database: 'finch_api_development'
    }))
    %w[ClassificationSuggestion TransactionPayment Transaction Account User].zip(records.values).each do |name, ids|
      model = class_double(name)
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
    expect(calls).to eq(%w[ClassificationSuggestion TransactionPayment Transaction Account User])
  end

  it 'creates A/B through the fixture-only user-limit exception and leaves the operator untouched' do
    operator = double('operator')
    stub_const('Rails', double(env: double(development?: true)))
    stub_const('ApplicationRecord', class_double('ApplicationRecord'))
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
    expect(described_class).to receive(:delete_graph!).with({ suggestions: [], payments: [], transactions: [], accounts: [], users: [] })
    allow(user_model).to receive(:new).and_return(user_a, user_b)
    expect(user_a).to receive(:save!).with(validate: false)
    expect(user_b).to receive(:save!).with(validate: false)
    expect(operator).not_to receive(:save!)
    expect(operator).not_to receive(:destroy!)
    account_model = class_double('Account')
    stub_const('Account', account_model)
    expect(account_model).to receive(:create!).with(hash_including(user: user_a, kind: :checking))

    described_class.prepare!(environment: environment)
  end

  it 'starts the fixture CLI with dotenv disabled before Rails can load database configuration' do
    launcher = File.read(File.expand_path('../../script/e2e/prepare_development_fixture', __dir__))

    expect(launcher).not_to match(/DATABASE_URL=''/)
  end
end
