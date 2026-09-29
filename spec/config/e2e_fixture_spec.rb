require 'spec_helper'
require 'uri'
require_relative '../../script/e2e/prepare_fixture'

RSpec.describe E2EFixture do
  it 'disables direct CLI execution before Rails can load any database configuration' do
    source = File.read(File.expand_path('../../script/e2e/prepare_fixture.rb', __dir__))

    expect(source).to include('Direct test-fixture execution is disabled')
    expect(source).not_to include("require_relative '../../config/environment'")
  end

  let(:safe_url) { 'postgresql://fixture:password@localhost:5432/finch_test' }
  let(:credentials) do
    { 'FINCH_E2E_EMAIL_A' => 'a@example.test', 'FINCH_E2E_EMAIL_B' => 'b@example.test',
      'FINCH_E2E_PASSWORD_A' => 'ephemeral-a', 'FINCH_E2E_PASSWORD_B' => 'ephemeral-b' }
  end

  def environment(overrides = {})
    { 'RAILS_ENV' => 'test', 'FINCH_E2E_CSRF' => '1',
      'DATABASE_URL_TEST' => safe_url }.merge(credentials).merge(overrides)
  end

  it 'accepts only an explicit test process and local disposable database' do
    expect(described_class.validate_environment!(environment)).to be_a(URI::Generic)

    [
      { 'RAILS_ENV' => 'development' }, { 'FINCH_E2E_CSRF' => nil },
      { 'DATABASE_URL_TEST' => 'postgresql://fixture:password@db.example.com/finch_test' },
      { 'DATABASE_URL_TEST' => 'postgresql://fixture:password@localhost/finch_development' },
      { 'DATABASE_URL_DEVEL' => safe_url }
    ].each do |override|
      expect { described_class.validate_environment!(environment(override)) }
        .to raise_error(E2EFixture::UnsafeFixtureError)
    end
  end

  it 'accepts only distinct synthetic identities with nonempty ephemeral passwords' do
    [
      { 'FINCH_E2E_EMAIL_A' => 'real@example.com' },
      { 'FINCH_E2E_EMAIL_B' => 'a@example.test' },
      { 'FINCH_E2E_PASSWORD_A' => '' }
    ].each do |override|
      expect { described_class.validate_environment!(environment(override)) }
        .to raise_error(E2EFixture::UnsafeFixtureError)
    end
  end

  it 'rejects unsafe settings before asking ActiveRecord for a connection' do
    stub_const('ApplicationRecord', class_double('ApplicationRecord'))
    expect(ApplicationRecord).not_to receive(:connected_to)

    expect do
      described_class.prepare!(environment: environment('DATABASE_URL_TEST' => nil))
    end.to raise_error(E2EFixture::UnsafeFixtureError)
  end

  def stub_rails_connection(configuration:, database: 'finch_test', address: '127.0.0.1',
                            port: '5432', tables: [])
    stub_const('Rails', double(env: double(test?: true)))
    stub_const('ApplicationRecord', class_double('ApplicationRecord'))
    allow(ApplicationRecord).to receive(:connected_to).with(role: :writing, shard: :local).and_yield
    allow(ApplicationRecord).to receive(:connection_db_config)
      .and_return(double(configuration_hash: configuration))
    connection = double('connection', data_sources: tables)
    allow(connection).to receive(:select_value).with('SELECT current_database()').and_return(database)
    allow(connection).to receive(:select_value).with('SELECT inet_server_addr()::text').and_return(address)
    allow(connection).to receive(:select_value).with('SHOW port').and_return(port)
    allow(ApplicationRecord).to receive(:connection).and_return(connection)
    connection
  end

  let(:local_configuration) do
    { adapter: 'postgresql', host: 'localhost', port: 5432, database: 'finch_test' }
  end

  it 'refuses a resolved ActiveRecord target different from the validated URL before opening a connection' do
    stub_rails_connection(configuration: local_configuration.merge(database: 'other_test'))
    expect(ApplicationRecord).not_to receive(:connection)

    expect { described_class.prepare!(environment: environment) }
      .to raise_error(E2EFixture::UnsafeFixtureError, /resolved database/i)
  end

  it 'refuses an actual connection to a different database before writing' do
    stub_rails_connection(configuration: local_configuration, database: 'other_test')
    stub_const('User', class_double('User'))
    expect(User).not_to receive(:transaction)

    expect { described_class.prepare!(environment: environment) }
      .to raise_error(E2EFixture::UnsafeFixtureError, /connected database/i)
  end

  it 'refuses a nonlocal server reached through a local-looking connection setting' do
    stub_rails_connection(configuration: local_configuration, address: '198.51.100.4')
    stub_const('User', class_double('User'))
    expect(User).not_to receive(:transaction)

    expect { described_class.prepare!(environment: environment) }
      .to raise_error(E2EFixture::UnsafeFixtureError, /connected database/i)
  end

  it 'refuses non-fixture table data before writing' do
    connection = stub_rails_connection(configuration: local_configuration, tables: %w[users accounts transactions])
    allow(connection).to receive(:quote_table_name).with('transactions').and_return('"transactions"')
    allow(connection).to receive(:select_value).with('SELECT 1 FROM "transactions" LIMIT 1').and_return(1)
    stub_const('User', class_double('User'))
    expect(User).not_to receive(:transaction)

    expect { described_class.prepare!(environment: environment) }
      .to raise_error(E2EFixture::UnsafeFixtureError, /non-fixture data/i)
  end

  it 'refuses partial prior fixture state without changing it' do
    stub_rails_connection(configuration: local_configuration)
    user_model = class_double('User')
    stub_const('User', user_model)
    allow(user_model).to receive(:transaction).and_yield
    allow(user_model).to receive(:where).and_return(double(not: double(exists?: false)))
    allow(user_model).to receive(:count).and_return(1)
    expect(user_model).not_to receive(:create!)
    stub_const('Account', class_double('Account'))

    expect { described_class.prepare!(environment: environment) }
      .to raise_error(E2EFixture::UnsafeFixtureError, /fixture state/i)
  end

  it 'creates only the two users and one account from an empty database' do
    stub_rails_connection(configuration: local_configuration)

    users = Array.new(2) { double('synthetic user') }
    user_model = class_double('User')
    stub_const('User', user_model)
    allow(user_model).to receive(:transaction).and_yield
    allow(user_model).to receive(:where).and_return(double(not: double(exists?: false)))
    allow(user_model).to receive(:count).and_return(0)
    expect(user_model).to receive(:create!).twice.and_return(*users)

    account = double('synthetic account', current_balance: BigDecimal('1000.00'))
    account_model = class_double('Account')
    stub_const('Account', account_model)
    allow(account_model).to receive(:count).and_return(0)
    expect(account_model).to receive(:create!).with(hash_including(user: users[0], initial_balance: BigDecimal('1000.00')))
      .and_return(account)

    described_class.prepare!(environment: environment)
  end

  it 'accepts an intact prior fixture without changing any record' do
    stub_rails_connection(configuration: local_configuration)
    users = [
      double(id: 11, name: 'Finch E2E A', active?: true, valid_password?: true),
      double(id: 12, name: 'Finch E2E B', active?: true, valid_password?: true)
    ]
    user_model = class_double('User')
    stub_const('User', user_model)
    allow(user_model).to receive(:transaction).and_yield
    allow(user_model).to receive(:where).and_return(double(not: double(exists?: false)))
    allow(user_model).to receive(:count).and_return(2)
    allow(user_model).to receive(:find_by).with(email: 'a@example.test').and_return(users[0])
    allow(user_model).to receive(:find_by).with(email: 'b@example.test').and_return(users[1])
    expect(user_model).not_to receive(:create!)

    account = double(user_id: 11, name: 'Finch E2E Account A', kind: 'checking',
                     initial_balance: BigDecimal('1000.00'), initial_balance_date: Date.new(2020, 1, 1),
                     archived_at: nil, current_balance: BigDecimal('1000.00'))
    account_model = class_double('Account')
    stub_const('Account', account_model)
    allow(account_model).to receive(:count).and_return(1)
    allow(account_model).to receive(:first).and_return(account)
    expect(account_model).not_to receive(:create!)

    2.times { described_class.prepare!(environment: environment) }
  end

  it 'refuses a previously changed fixture account' do
    stub_rails_connection(configuration: local_configuration)
    users = [double(id: 11, name: 'Finch E2E A', active?: true, valid_password?: true),
             double(id: 12, name: 'Finch E2E B', active?: true, valid_password?: true)]
    user_model = class_double('User')
    stub_const('User', user_model)
    allow(user_model).to receive(:transaction).and_yield
    allow(user_model).to receive(:where).and_return(double(not: double(exists?: false)))
    allow(user_model).to receive(:count).and_return(2)
    allow(user_model).to receive(:find_by).with(email: 'a@example.test').and_return(users[0])
    allow(user_model).to receive(:find_by).with(email: 'b@example.test').and_return(users[1])
    expect(user_model).not_to receive(:create!)

    account = double(user_id: 11, name: 'Finch E2E Account A', kind: 'checking',
                     initial_balance: BigDecimal('900.00'), initial_balance_date: Date.new(2020, 1, 1),
                     archived_at: nil, current_balance: BigDecimal('900.00'))
    account_model = class_double('Account')
    stub_const('Account', account_model)
    allow(account_model).to receive(:count).and_return(1)
    allow(account_model).to receive(:first).and_return(account)
    expect(account_model).not_to receive(:create!)

    expect { described_class.prepare!(environment: environment) }
      .to raise_error(E2EFixture::UnsafeFixtureError, /fixture state/i)
  end
end
