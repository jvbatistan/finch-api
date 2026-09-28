module CardStatements
  class PeriodSnapshot
    Result = Struct.new(:cards, :statements, :transaction_counts, keyword_init: true)

    # Read model. It intentionally carries a persisted statement only when one
    # already exists; callers must not materialize a statement from a GET.
    class Statement
      attr_reader :record, :card, :billing_statement, :total_amount, :paid_amount, :paid_at

      def initialize(record:, card:, billing_statement:, total_amount:, paid_amount:, paid_at:)
        @record = record
        @card = card
        @billing_statement = billing_statement
        @total_amount = total_amount.to_d
        @paid_amount = paid_amount.to_d
        @paid_at = paid_amount >= total_amount && total_amount.positive? ? paid_at : nil
      end

      def id = record&.id
      def card_id = card.id
      def persisted? = record.present?
      def ignored? = record&.ignored? || false
      def ignored_at = record&.ignored_at
      def remaining_amount = [total_amount - paid_amount, 0.to_d].max
      def paid? = remaining_amount <= 0
      def payment_status
        return "paid" if paid?
        return "partially_paid" if paid_amount.positive?

        "open"
      end
      def card_statement_payments
        return CardStatementPayment.none unless record

        record.card_statement_payments
      end
    end

    def initialize(user:, month:, year:)
      @user = user
      @month = month.to_i
      @year = year.to_i
    end

    def call
      cards = user.cards.ordenados.to_a
      return Result.new(cards: [], statements: [], transaction_counts: {}) if cards.empty?

      billing_dates = cards.index_with { |card| card.due_on(year, month) }
      records = load_statement_records(cards, billing_dates)
      totals, transaction_counts = transaction_aggregates(cards)
      payment_totals, latest_payments = payment_aggregates(records.values)

      statements = cards.map do |card|
        billing_date = billing_dates.fetch(card)
        record = records[[card.id, billing_date]]
        Statement.new(
          record: record,
          card: card,
          billing_statement: billing_date,
          total_amount: totals.fetch(card.id, 0.to_d),
          paid_amount: payment_totals.fetch(record&.id, 0.to_d),
          paid_at: latest_payments[record&.id]
        )
      end

      Result.new(cards: cards, statements: statements, transaction_counts: transaction_counts)
    end

    private

    attr_reader :user, :month, :year

    def period_start
      @period_start ||= Date.new(year, month, 1)
    end

    def period_end
      @period_end ||= period_start.end_of_month
    end

    def load_statement_records(cards, billing_dates)
      CardStatement
        .where(card_id: cards.map(&:id), billing_statement: billing_dates.values)
        .index_by { |statement| [statement.card_id, statement.billing_statement] }
    end

    def transaction_aggregates(cards)
      rows = user.transactions
                 .active
                 .where(card_id: cards.map(&:id), billing_statement: period_start..period_end)
                 .group(:card_id)
                 .pluck(
                   :card_id,
                   Arel.sql("COALESCE(SUM(#{Transaction.signed_value_sql}), 0)"),
                   Arel.sql("COUNT(*)")
                 )

      totals = {}
      counts = {}
      rows.each do |card_id, total, count|
        totals[card_id] = total.to_d
        counts[card_id] = count
      end

      [totals, counts]
    end

    def payment_aggregates(statements)
      statement_ids = statements.filter_map(&:id)
      return [{}, {}] if statement_ids.empty?

      rows = CardStatementPayment
             .where(card_statement_id: statement_ids)
             .group(:card_statement_id)
             .pluck(:card_statement_id, Arel.sql("COALESCE(SUM(amount), 0)"), Arel.sql("MAX(paid_at)"))

      totals = {}
      latest = {}
      rows.each do |statement_id, total, latest_paid_at|
        totals[statement_id] = total.to_d
        latest[statement_id] = latest_paid_at
      end

      [totals, latest]
    end
  end
end
