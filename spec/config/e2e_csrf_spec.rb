require 'spec_helper'
require 'ostruct'
require 'active_support/core_ext/numeric/time'

RSpec.describe 'E2E CSRF test setting' do
  [nil, '0', 'true', '1'].each do |flag|
    it "enables protection only for flag #{flag.inspect}" do
      settings = OpenStruct.new(
        action_view: OpenStruct.new, public_file_server: OpenStruct.new,
        action_controller: OpenStruct.new, action_dispatch: OpenStruct.new,
        active_storage: OpenStruct.new, action_mailer: OpenStruct.new,
        active_support: OpenStruct.new
      )
      settings.define_singleton_method(:config) { settings }
      app = double('Rails application')
      allow(app).to receive(:configure) { |&block| settings.instance_eval(&block) }
      stub_const('Rails', double(application: app))
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('FINCH_E2E_CSRF').and_return(flag)

      load File.expand_path('../../config/environments/test.rb', __dir__)

      expect(settings.action_controller.allow_forgery_protection).to eq(flag == '1')
    end
  end
end
