require "spec_helper"
require "bigdecimal"
require "date"
require "logger"
require "rake"
require "stringio"
require "active_support/all"

RSpec.describe "card_statements:audit" do
  around do |example|
    previous_application = Rake.application
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    load File.expand_path("../../lib/tasks/card_statements.rake", __dir__)
    example.run
  ensure
    Rake.application = previous_application
  end

  it "prints technical identifiers and consistency checks without financial or personal values" do
    transaction = double(
      "transaction",
      id: 17,
      date: Date.new(2026, 10, 4),
      description: "PRIVATE TRANSACTION DESCRIPTION",
      value: BigDecimal("123.45"),
      signed_value: BigDecimal("123.45"),
      refund?: false,
      card_statement_payment_description?: false,
      paid?: false,
      classification_status: "pending",
      category: double("category", id: 9, name: "PRIVATE CATEGORY NAME")
    )
    transactions = [transaction]
    payment = double("payment", id: 5, original_transaction_id: 88, amount: BigDecimal("50.00"), description: "PRIVATE PAYMENT DESCRIPTION")
    payments = double("payments", count: 1, sum: BigDecimal("50.00"), order: [payment])
    statement = double("statement", id: 3, card_statement_payments: payments, total_amount: BigDecimal("123.45"), paid_amount: BigDecimal("50.00"), remaining_amount: BigDecimal("73.45"))
    card = double("card", id: 2, name: "PRIVATE CARD NAME", due_on: Date.new(2026, 10, 10), card_statements: double(find_by: statement))
    relation = double("transactions relation")
    allow(relation).to receive(:active).and_return(relation)
    allow(relation).to receive(:includes).and_return(relation)
    allow(relation).to receive(:where).and_return(relation)
    allow(relation).to receive(:order).and_return(transactions)
    allow(card).to receive(:transactions).and_return(relation)
    stub_const("Card", Class.new { def self.find(_id); end })
    allow(Card).to receive(:find).with(2).and_return(card)

    output = capture_stdout { Rake::Task["card_statements:audit"].invoke("2", "10", "2026") }

    expect(output).to include("Card ID: 2", "Statement ID: 3", "Transaction count: 1", "original transaction ID: 88", "Total matches stored: true")
    expect(output).not_to include("PRIVATE", "123.45", "50.00", "73.45")
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
