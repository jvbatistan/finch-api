require "spec_helper"
require_relative "../../lib/production_secret_validation"

RSpec.describe ProductionSecretValidation do
  let(:application) { double("Rails application") }

  it "rejects production boot without a resolved signing secret" do
    allow(application).to receive(:secret_key_base).and_return(nil)

    expect do
      described_class.validate!(environment: "production", application: application)
    end.to raise_error(described_class::MissingSecretError, /SECRET_KEY_BASE/)
  end

  it "rejects a whitespace-only signing secret" do
    allow(application).to receive(:secret_key_base).and_return("  ")

    expect do
      described_class.validate!(environment: "production", application: application)
    end.to raise_error(described_class::MissingSecretError)
  end

  it "accepts the resolved signing secret regardless of whether Rails obtained it from ENV or credentials" do
    allow(application).to receive(:secret_key_base).and_return("test-only-signing-secret")

    expect(described_class.validate!(environment: "production", application: application)).to be_nil
  end

  it "does not expose exceptions raised while resolving credentials" do
    allow(application).to receive(:secret_key_base).and_raise(StandardError, "private credential value")

    expect do
      described_class.validate!(environment: "production", application: application)
    end.to raise_error(described_class::MissingSecretError) { |error|
      expect(error.message).not_to include("private credential value")
      expect(error.cause).to be_nil
    }
  end

  %w[development test].each do |environment|
    it "does not require production secrets in #{environment}" do
      expect(application).not_to receive(:secret_key_base)

      expect(described_class.validate!(environment: environment, application: application)).to be_nil
    end
  end
end
