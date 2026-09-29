require 'spec_helper'
require 'open3'
require 'tmpdir'

RSpec.describe 'E2E development server launcher' do
  let(:source) { File.read(File.expand_path('../../script/e2e/server_development', __dir__)) }

  it 'requires the explicit development E2E opt-in before boot' do
    expect(source).to match(/\$\{FINCH_E2E_DEVEL_DB:-\}.*!=.*1/)
    expect(source).to match(/\$\{RAILS_ENV:-\}.*!=.*development/)
    expect(source).to include('exit 1')
  end

  it 'unsets the production URL before Rails and binds only to an explicit loopback port' do
    expect(source).to include('exec env -u DATABASE_URL RUBYOPT=')
    expect(source).to include('disable_dotenv.rb')
    expect(source).to include('--binding 127.0.0.1 --port 3001')
    expect(source).not_to match(/\$\{?DATABASE_URL\b/)
  end

  it 'rejects wrong host, port, or database before launching Rails' do
    Dir.mktmpdir('finch-e2e-server-') do |directory|
      bundle_shim = File.join(directory, 'bundle')
      File.write(bundle_shim, "#!/bin/sh\necho SERVER_BOOTED\n")
      File.chmod(0o755, bundle_shim)

      [
        'postgresql://fixture:password@db.example.test:5432/finch_api_development',
        'postgresql://fixture:password@localhost:5433/finch_api_development',
        'postgresql://fixture:password@localhost:5432/finch_development'
      ].each do |unsafe_url|
        stdout, _stderr, status = Open3.capture3({
          'FINCH_E2E_DEVEL_DB' => '1', 'RAILS_ENV' => 'development',
          'DATABASE_URL_DEVEL' => unsafe_url, 'PATH' => "#{directory}:#{ENV.fetch('PATH')}"
          },
          File.expand_path('../../script/e2e/server_development', __dir__)
        )
        expect(status.success?).to be(false)
        expect(stdout).not_to include('SERVER_BOOTED')
      end
    end
  end

  it 'keeps dotenv from restoring a production URL before database configuration' do
    Dir.mktmpdir('finch-e2e-server-') do |directory|
      dotenv_file = File.join(directory, '.env.synthetic')
      File.write(dotenv_file, "DATABASE_URL=synthetic-production-target\nDATABASE_URL_DEVEL=wrong-target\n")
      bundle_shim = File.join(directory, 'bundle')
      File.write(bundle_shim, <<~RUBY)
        #!/usr/bin/env ruby
        require 'dotenv'
        require 'erb'
        require 'yaml'
        require 'active_support/core_ext/object/blank'

        Dotenv::Railtie.load
        abort 'production URL restored' if ENV.key?('DATABASE_URL')
        abort 'development URL lost' unless ENV['DATABASE_URL_DEVEL'] == 'postgresql://fixture:password@localhost:5432/finch_api_development'

        config = YAML.safe_load(ERB.new(File.read('config/database.yml')).result, aliases: true)
        abort 'unsafe database config' unless config.fetch('development').fetch('supabase').fetch('url').nil?
        abort 'wrong development config' unless config.fetch('development').fetch('local').fetch('url') == 'postgresql://fixture:password@localhost:5432/finch_api_development'
      RUBY
      File.chmod(0o755, bundle_shim)

      environment = {
        'FINCH_E2E_DEVEL_DB' => '1', 'RAILS_ENV' => 'development',
        'DATABASE_URL' => 'synthetic-parent-target',
        'DATABASE_URL_DEVEL' => 'postgresql://fixture:password@localhost:5432/finch_api_development',
        'FINCH_E2E_SYNTHETIC_ENV_FILE' => dotenv_file,
        'PATH' => "#{directory}:#{ENV.fetch('PATH')}"
      }
      _stdout, stderr, status = Open3.capture3(environment,
                                                File.expand_path('../../script/e2e/server_development', __dir__))
      expect(status.success?).to be(true), stderr
    end
  end
end
