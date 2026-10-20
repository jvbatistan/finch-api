namespace :card_statements do
  desc "Audit a card statement without changing data: rake card_statements:audit[card_id,month,year]"
  task :audit, %i[card_id month year] => :environment do |_task, args|
    card_id = Integer(args[:card_id], exception: false)
    month = Integer(args[:month], exception: false)
    year = Integer(args[:year], exception: false)

    abort "Usage: rake card_statements:audit[card_id,month,year]" unless card_id && month&.between?(1, 12) && year&.positive?

    card = Card.find(card_id)
    period_start = Date.new(year, month, 1)
    period_end = period_start.end_of_month
    statement = card.card_statements.find_by(billing_statement: card.due_on(year, month))
    transactions = card.transactions
                       .active
                       .includes(:category, :classification_suggestions)
                       .where(billing_statement: period_start..period_end)
                       .order(:date, :id)

    calculated_total = transactions.sum(&:signed_value)
    calculated_paid = statement ? statement.card_statement_payments.sum(:amount).to_d : 0.to_d
    calculated_remaining = [calculated_total - calculated_paid, 0.to_d].max
    duplicate_counts = transactions.group_by do |transaction|
      [transaction.date, transaction.description, transaction.value.to_d, transaction.refund?]
    end.transform_values(&:size)

    puts "Card ID: #{card.id}"
    puts "Period: #{period_start.strftime('%m/%Y')}"
    puts "Statement ID: #{statement&.id || 'not found'}"
    puts "Transaction count: #{transactions.size}"
    puts "Statement payment count: #{statement ? statement.card_statement_payments.count : 0}"
    puts ""
    puts "Transactions:"
    puts "  id | type | status | classification | category ID | included | warning"

    transactions.each do |transaction|
      type = transaction.refund? ? "REFUND" : "PURCHASE"
      warning = transaction.card_statement_payment_description? ? " [PAYMENT-LIKE DESCRIPTION]" : ""
      duplicate_count = duplicate_counts.fetch([transaction.date, transaction.description, transaction.value.to_d, transaction.refund?])
      warning += " [POSSIBLE DUPLICATE x#{duplicate_count}]" if duplicate_count > 1
      puts format(
        "  %<id>d | %<type>s | %<status>s | %<classification>s | %<category>s | YES%<warning>s",
        id: transaction.id,
        type: type,
        status: transaction.paid? ? "PAID" : "OPEN",
        classification: transaction.classification_status,
        category: transaction.category&.id || "none",
        warning: warning
      )
    end

    puts ""
    puts "Statement payments:"
    if statement
      statement.card_statement_payments.order(:paid_at, :id).each do |payment|
        puts format(
          "  #%<id>d | PAYMENT | included in total: NO | included in paid: YES | original transaction ID: %<transaction>s",
          id: payment.id,
          transaction: payment.original_transaction_id || "none"
        )
      end
    end

    puts ""
    if statement
      puts "Total matches stored: #{calculated_total == statement.total_amount.to_d}"
      puts "Paid matches stored: #{calculated_paid == statement.paid_amount.to_d}"
      puts "Remaining matches stored: #{calculated_remaining == statement.remaining_amount.to_d}"
    end
  end
end
