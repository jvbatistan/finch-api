require "rails_helper"

RSpec.describe CardStatements::PeriodSnapshot do
  let(:user) { create(:user) }

  it "projects a missing statement without persisting it and derives its totals and transaction count" do
    card = create(:card, user: user, due_day: 15, closing_day: 8)
    create(:transaction, user: user, card: card, source: :card, date: Date.new(2026, 3, 7), value: 120)
    create(:transaction, user: user, card: card, source: :card, date: Date.new(2026, 3, 7), value: 20, refund: true)

    expect do
      @result = described_class.new(user: user, month: 3, year: 2026).call
    end.not_to change(CardStatement, :count)

    statement = @result.statements.first
    expect(statement).not_to be_persisted
    expect(statement.id).to be_nil
    expect(statement.billing_statement).to eq(Date.new(2026, 3, 15))
    expect(statement.total_amount.to_d).to eq(100.to_d)
    expect(statement.paid_amount.to_d).to eq(0.to_d)
    expect(statement.paid_at).to be_nil
    expect(@result.transaction_counts).to eq(card.id => 2)
  end

  it "corrects stale totals and preserves partial-payment semantics" do
    card = create(:card, user: user, due_day: 15, closing_day: 8)
    create(:transaction, user: user, card: card, source: :card, date: Date.new(2026, 3, 7), value: 120)
    statement = create(
      :card_statement,
      card: card,
      billing_statement: Date.new(2026, 3, 15),
      total_amount: 999,
      paid_amount: 999,
      paid_at: Time.zone.local(2026, 3, 1, 12)
    )
    payment = create(
      :card_statement_payment,
      card_statement: statement,
      amount: 30,
      paid_at: Time.zone.local(2026, 3, 10, 12)
    )
    statement.update_columns(total_amount: 999, paid_amount: 999, paid_at: payment.paid_at)

    result = described_class.new(user: user, month: 3, year: 2026).call

    synced = result.statements.first
    expect(synced.total_amount.to_d).to eq(120.to_d)
    expect(synced.paid_amount.to_d).to eq(30.to_d)
    expect(synced.paid_at).to be_nil
    expect(synced.remaining_amount).to eq(90.to_d)
  end

  it "sets paid_at from the latest payment only when the statement is fully paid" do
    card = create(:card, user: user, due_day: 15, closing_day: 8)
    create(:transaction, user: user, card: card, source: :card, date: Date.new(2026, 3, 7), value: 120)
    statement = create(:card_statement, card: card, billing_statement: Date.new(2026, 3, 15), total_amount: 120)
    create(:card_statement_payment, card_statement: statement, amount: 40, paid_at: Time.zone.local(2026, 3, 9, 12))
    latest = create(:card_statement_payment, card_statement: statement, amount: 80, paid_at: Time.zone.local(2026, 3, 11, 12))

    synced = described_class.new(user: user, month: 3, year: 2026).call.statements.first

    expect(synced.paid_amount.to_d).to eq(120.to_d)
    expect(synced.paid_at).to eq(latest.paid_at)
    expect(synced).to be_paid
  end

  it "does not include transactions or statements from another user" do
    own_card = create(:card, user: user, name: "Own", due_day: 15, closing_day: 8)
    other_user = create(:user)
    other_card = create(:card, user: other_user, name: "Other", due_day: 15, closing_day: 8)
    create(:transaction, user: user, card: own_card, source: :card, date: Date.new(2026, 3, 7), value: 50)
    create(:transaction, user: other_user, card: other_card, source: :card, date: Date.new(2026, 3, 7), value: 500)

    result = described_class.new(user: user, month: 3, year: 2026).call

    expect(result.cards).to eq([own_card])
    expect(result.statements.map(&:card_id)).to eq([own_card.id])
    expect(result.statements.first.total_amount.to_d).to eq(50.to_d)
  end
end
