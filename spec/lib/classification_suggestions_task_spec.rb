require "spec_helper"
require "logger"
require "rake"
require "stringio"
require "active_support/all"

RSpec.describe "classification suggestion tasks" do
  around do |example|
    previous_application = Rake.application
    previous_environment = ENV.to_h.slice("DRY_RUN", "SEED_MISSING", "USER_ID")
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    load File.expand_path("../../lib/tasks/classification_suggestions.rake", __dir__)
    example.run
  ensure
    %w[DRY_RUN SEED_MISSING USER_ID].each do |key|
      ENV.delete(key)
    end
    previous_environment.each { |key, value| ENV[key] = value }
    Rake.application = previous_application
  end

  it "keeps the transaction id and exception class but hides the exception message" do
    sensitive_message = "private transaction description and credentials"
    user = double("user", id: 11)
    relation = double("transactions relation")
    tx = double(
      "transaction",
      id: 17,
      classification_suggestions: double("suggestions", pending: double(exists?: false)),
      category_id: nil,
      installment_group_id: nil
    )

    allow(user).to receive(:transactions).and_return(relation)
    allow(relation).to receive(:where).and_return(relation)
    allow(relation).to receive(:not).and_return(relation)
    allow(relation).to receive(:pluck).and_return([17])
    allow(relation).to receive(:group).and_return(relation)
    allow(relation).to receive(:minimum).and_return({})
    allow(user).to receive(:id).and_return(11)
    stub_const(
      "Transactions::CreateCategorySuggestionService",
      Class.new do
        define_singleton_method(:new) do |_transaction|
          raise StandardError, sensitive_message
        end
      end
    )

    user_scope = double("user scope")
    allow(user_scope).to receive(:find_each).and_yield(user)
    stub_const("User", Class.new { def self.all; nil; end })
    allow(User).to receive(:all).and_return(user_scope)
    stub_const("Transaction", Class.new { def self.find_by(*) = nil })
    allow(Transaction).to receive(:find_by).with(id: 17, user_id: 11).and_return(tx)

    ENV["DRY_RUN"] = "false"
    output = capture_stdout { Rake::Task["classification:seed_missing"].invoke }

    expect(output).to include("ERRO tx=17: StandardError")
    expect(output).not_to include(sensitive_message)
  end

  it "keeps suggestion and transaction ids but hides the exception message" do
    sensitive_message = "private financial details and access token"
    suggestion = double(
      "suggestion",
      id: 23,
      suggested_category_id: 9,
      confidence: 0.99,
      financial_transaction: double(
        "transaction",
        id: 17,
        installment_group_id: nil,
        suggested_category_id: 9
      )
    )
    tx = suggestion.financial_transaction
    allow(tx).to receive(:update!).and_raise(StandardError, sensitive_message)

    scope = double("suggestions scope")
    allow(scope).to receive(:pending).and_return(scope)
    allow(scope).to receive(:includes).and_return(scope)
    allow(scope).to receive(:order).and_return(scope)
    allow(scope).to receive(:count).and_return(1)
    allow(scope).to receive(:find_each).and_yield(suggestion)

    stub_const("ClassificationSuggestion", Class.new { def self.all; nil; end; def self.pending; nil; end })
    allow(ClassificationSuggestion).to receive(:all).and_return(scope)
    allow(ClassificationSuggestion).to receive(:pending).and_return(scope)
    stub_const("Transaction", Class.new { def self.transaction; yield if block_given?; end })
    allow(Transaction).to receive(:transaction).and_yield

    ENV["DRY_RUN"] = "false"
    ENV["SEED_MISSING"] = "false"
    output = capture_stdout { Rake::Task["classification:auto_apply_pending"].invoke }

    expect(output).to include("ERRO suggestion=23 tx=17: StandardError")
    expect(output).not_to include(sensitive_message)
  end

  def capture_stdout
    original_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original_stdout
  end
end
