require 'rails_helper'

RSpec.describe Transaction, type: :model do
  describe 'origin defaults' do
    it 'preserves the initial date and value when creating a transaction' do
      transaction = create(:transaction, date: Date.new(2026, 1, 10), value: BigDecimal('150.00'))

      expect(transaction.purchase_date).to eq(Date.new(2026, 1, 10))
      expect(transaction.original_value).to eq(BigDecimal('150.00'))
    end

    it 'does not infer origin fields for an existing historical transaction' do
      transaction = create(:transaction)
      transaction.update_columns(purchase_date: nil, original_value: nil)

      transaction.update!(note: 'Histórico preservado')

      expect(transaction.reload.purchase_date).to be_nil
      expect(transaction.original_value).to be_nil
    end

    it 'keeps original_value when the current value changes' do
      transaction = create(:transaction, value: BigDecimal('150.00'))

      transaction.update!(value: BigDecimal('149.26'))

      expect(transaction.reload.value).to eq(BigDecimal('149.26'))
      expect(transaction.original_value).to eq(BigDecimal('150.00'))
    end
  end

  describe 'associations' do
    it 'keeps card optional at the association level' do
      expect(described_class.reflect_on_association(:card).options[:optional]).to eq(true)
    end

    it { should belong_to(:category).optional }
    it { should belong_to(:account).optional }
  end

  describe 'classification status' do
    it 'distinguishes classified, pending-suggestion and unclassified transactions' do
      user = create(:user)
      category = create(:category, user: user)
      classified = create(:transaction, user: user, card: nil, source: :cash, category: category)
      pending = create(:transaction, user: user, card: nil, source: :cash, category: nil)
      unclassified = create(:transaction, user: user, card: nil, source: :cash, category: nil)
      pending.classification_suggestions.delete_all
      unclassified.classification_suggestions.delete_all
      create(:classification_suggestion, user: user, financial_transaction: pending, suggested_category: category)

      expect(classified.classification_status).to eq('classified')
      expect(pending.classification_status).to eq('suggestion_pending')
      expect(unclassified.classification_status).to eq('unclassified')
    end

    it 'uses the newest pending suggestion among active installments in the same group' do
      user = create(:user)
      category = create(:category, user: user)
      card = create(:card, user: user)
      group_id = SecureRandom.uuid
      first_installment = create(:transaction, user: user, card: card, installment_group_id: group_id, installment_number: 1, installments_count: 2)
      second_installment = create(:transaction, user: user, card: card, installment_group_id: group_id, installment_number: 2, installments_count: 2)
      first_installment.classification_suggestions.delete_all
      second_installment.classification_suggestions.delete_all
      older = create(:classification_suggestion, user: user, financial_transaction: first_installment, suggested_category: category, created_at: 2.minutes.ago)
      create(:classification_suggestion, user: user, financial_transaction: first_installment, suggested_category: category, accepted_at: 1.minute.ago)
      newest = create(:classification_suggestion, user: user, financial_transaction: second_installment, suggested_category: category, created_at: 1.minute.ago)

      expect(first_installment.pending_classification_suggestion).to eq(newest)

      second_installment.archive!

      expect(first_installment.pending_classification_suggestion).to eq(older)
    end
  end

  describe 'validations' do
    it { should validate_presence_of(:description) }
    it { should validate_presence_of(:value) }
    it 'requires a value greater than zero after normalizing the sign' do
      transaction = build(:transaction, value: 0)

      expect(transaction).not_to be_valid
      expect(transaction.errors[:value]).to include('deve ser maior que 0')
    end

    it { should validate_presence_of(:date) }
    it { should validate_presence_of(:kind) }
    it { should validate_presence_of(:source) }

    it 'requires card expense fields for refunds' do
      transaction = build(:transaction, refund: true, source: :cash, card: nil)

      expect(transaction).not_to be_valid
      expect(transaction.errors[:source]).to include('deve ser cartão para estornos')
      expect(transaction.errors[:card]).to include('é obrigatório para estornos')
    end

    it 'rejects clear card statement payment descriptions as transactions' do
      transaction = build(:transaction, description: 'Pagamento recebido para liberar limite', source: :card, refund: false)

      expect(transaction).not_to be_valid
      expect(transaction.errors[:base]).to include('pagamento de fatura deve ser registrado na tela de pagamentos, não como transação')
    end

    it 'rejects the exact generic payment description without matching normal merchants' do
      payment = build(:transaction, description: 'Pagamento', source: :card, refund: false)

      expect(payment).not_to be_valid
      expect(payment.errors[:base]).to include('pagamento de fatura deve ser registrado na tela de pagamentos, não como transação')
    end

    it 'does not reject merchant names that include payment-like words' do
      transaction = build(:transaction, description: 'Pagamento de farmacia sao jose', source: :card, refund: false)

      expect(transaction).to be_valid
    end

    it 'rejects a category owned by another user' do
      user = create(:user)
      other_user = create(:user)
      other_category = create(:category, user: other_user)
      transaction = build(:transaction, user: user, category: other_category)

      expect(transaction).not_to be_valid
      expect(transaction.errors[:category]).to include('deve pertencer ao mesmo usuário')
    end

    it 'accepts a simple income without card, statement, installment or payment-flow fields' do
      user = create(:user)
      account = create(:account, user: user)
      transaction = build(:transaction, user: user, account: account, kind: :income, source: :bank, card: nil, paid: false)

      expect(transaction).to be_valid
      expect(transaction.paid).to eq(true)
      expect(transaction.card_id).to be_nil
      expect(transaction.billing_statement).to be_nil
      expect(transaction.installment_group_id).to be_nil
      expect(transaction.installment_number).to be_nil
      expect(transaction.installments_count).to be_nil
      expect(transaction.payment_ignored_at).to be_nil
      expect(transaction.refund).to eq(false)
    end

    it 'does not require card or billing statement for income' do
      user = create(:user)
      account = create(:account, user: user)
      transaction = build(:transaction, user: user, account: account, kind: :income, source: :cash, card: nil)

      expect(transaction).to be_valid
      expect(transaction.billing_statement).to be_nil
    end

    it 'requires an account for income' do
      transaction = build(:transaction, kind: :income, source: :bank, card: nil, account: nil)

      expect(transaction).not_to be_valid
      expect(transaction.errors[:account]).to include('é obrigatória para receitas')
    end

    it 'rejects income with an account from another user' do
      user = create(:user)
      other_account = create(:account, user: create(:user))
      transaction = build(:transaction, user: user, account: other_account, kind: :income, source: :bank, card: nil)

      expect(transaction).not_to be_valid
      expect(transaction.errors[:account]).to include('deve pertencer ao mesmo usuário')
    end

    it 'rejects income with an archived account' do
      user = create(:user)
      account = create(:account, user: user, archived_at: Time.current)
      transaction = build(:transaction, user: user, account: account, kind: :income, source: :bank, card: nil)

      expect(transaction).not_to be_valid
      expect(transaction.errors[:account]).to include('não pode estar arquivada')
    end

    it 'rejects income with a missing account id before hitting the database foreign key' do
      transaction = build(:transaction, kind: :income, source: :bank, card: nil, account_id: Account.maximum(:id).to_i + 10_000)

      expect(transaction).not_to be_valid
      expect(transaction.errors[:account]).to include('inválida')
    end

    it 'rejects income with source card' do
      user = create(:user)
      account = create(:account, user: user)
      transaction = build(:transaction, user: user, account: account, kind: :income, source: :card, card: nil)

      expect(transaction).not_to be_valid
      expect(transaction.errors[:source]).to include('não pode ser cartão para receitas')
    end

    it 'rejects income with a card' do
      user = create(:user)
      account = create(:account, user: user)
      card = create(:card, user: user)
      transaction = build(:transaction, user: user, account: account, kind: :income, source: :bank, card: card)

      expect(transaction).not_to be_valid
      expect(transaction.errors[:card]).to include('não deve existir para receitas')
    end

    it 'rejects income with a billing statement' do
      user = create(:user)
      account = create(:account, user: user)
      transaction = build(:transaction, user: user, account: account, kind: :income, source: :bank, card: nil, billing_statement: Date.new(2026, 7, 1))

      expect(transaction).not_to be_valid
      expect(transaction.errors[:billing_statement]).to include('não deve existir para receitas')
    end

    it 'rejects income with installment fields' do
      user = create(:user)
      account = create(:account, user: user)
      transaction = build(
        :transaction,
        user: user,
        account: account,
        kind: :income,
        source: :bank,
        card: nil,
        installment_group_id: SecureRandom.uuid,
        installment_number: 1,
        installments_count: 3
      )

      expect(transaction).not_to be_valid
      expect(transaction.errors[:base]).to include('receita não pode ser parcelada')
    end

    it 'rejects income with payment ignored timestamp' do
      user = create(:user)
      account = create(:account, user: user)
      transaction = build(:transaction, user: user, account: account, kind: :income, source: :bank, card: nil, payment_ignored_at: Time.current)

      expect(transaction).not_to be_valid
      expect(transaction.errors[:payment_ignored_at]).to include('não deve existir para receitas')
    end

    it 'rejects income with refund flag' do
      user = create(:user)
      account = create(:account, user: user)
      transaction = build(:transaction, user: user, account: account, kind: :income, source: :bank, card: nil, refund: true)

      expect(transaction).not_to be_valid
      expect(transaction.errors[:refund]).to include('não pode ser verdadeiro para receitas')
    end

    it 'keeps card expenses valid' do
      transaction = build(:transaction, kind: :expense, source: :card)

      expect(transaction).to be_valid
    end

    it 'keeps installment expenses valid' do
      transaction = build(
        :transaction,
        kind: :expense,
        source: :card,
        installment_group_id: SecureRandom.uuid,
        installment_number: 1,
        installments_count: 3
      )

      expect(transaction).to be_valid
    end

    it 'keeps expense refunds valid when they are card expenses without installments' do
      card = create(:card)
      transaction = build(:transaction, kind: :expense, source: :card, card: card, refund: true)

      expect(transaction).to be_valid
    end

    it 'accepts cash expenses with an active account from the same user' do
      user = create(:user)
      account = create(:account, user: user)
      transaction = build(:transaction, user: user, account: account, kind: :expense, source: :cash, card: nil)

      expect(transaction).to be_valid
    end

    it 'accepts bank expenses with an active account from the same user' do
      user = create(:user)
      account = create(:account, user: user)
      transaction = build(:transaction, user: user, account: account, kind: :expense, source: :bank, card: nil)

      expect(transaction).to be_valid
    end

    it 'rejects a card on cash and bank expenses' do
      user = create(:user)
      card = create(:card, user: user)

      %i[cash bank].each do |source|
        transaction = build(:transaction, user: user, kind: :expense, source: source, card: card)

        expect(transaction).not_to be_valid
        expect(transaction.errors[:card]).to include('não deve existir para origem dinheiro ou banco')
      end
    end

    it 'allows new unpaid cash or bank expenses without an account' do
      cash = build(:transaction, kind: :expense, source: :cash, card: nil, account: nil)
      bank = build(:transaction, kind: :expense, source: :bank, card: nil, account: nil)

      expect(cash).to be_valid
      expect(bank).to be_valid
    end

    it 'requires an active account for paid cash or bank expenses' do
      cash = build(:transaction, kind: :expense, source: :cash, card: nil, account: nil, paid: true)
      bank = build(:transaction, kind: :expense, source: :bank, card: nil, account: nil, paid: true)

      expect(cash).not_to be_valid
      expect(cash.errors[:account]).to include('é obrigatória para despesas sem cartão')
      expect(bank).not_to be_valid
      expect(bank.errors[:account]).to include('é obrigatória para despesas sem cartão')
    end

    it 'rejects cash or bank expenses with an account from another user' do
      user = create(:user)
      other_account = create(:account, user: create(:user))
      transaction = build(:transaction, user: user, account: other_account, kind: :expense, source: :cash, card: nil)

      expect(transaction).not_to be_valid
      expect(transaction.errors[:account]).to include('deve pertencer ao mesmo usuário')
    end

    it 'rejects cash or bank expenses with an archived account' do
      user = create(:user)
      account = create(:account, user: user, archived_at: Time.current)
      transaction = build(:transaction, user: user, account: account, kind: :expense, source: :bank, card: nil)

      expect(transaction).not_to be_valid
      expect(transaction.errors[:account]).to include('não pode estar arquivada')
    end

    it 'rejects cash or bank expenses with a missing account id before hitting the database foreign key' do
      transaction = build(:transaction, kind: :expense, source: :bank, card: nil, account_id: Account.maximum(:id).to_i + 10_000)

      expect(transaction).not_to be_valid
      expect(transaction.errors[:account]).to include('inválida')
    end

    it 'rejects account on card expenses' do
      user = create(:user)
      account = create(:account, user: user)
      card = create(:card, user: user)
      transaction = build(:transaction, user: user, account: account, card: card, kind: :expense, source: :card)

      expect(transaction).not_to be_valid
      expect(transaction.errors[:account]).to include('não deve existir para despesas no cartão')
    end

    it 'keeps legacy cash expenses without account editable when account-relevant fields do not change' do
      transaction = build(:transaction, kind: :expense, source: :cash, card: nil, account: nil, description: 'Legado')
      transaction.save!(validate: false)

      transaction.description = 'Legado atualizado'

      expect(transaction).to be_valid
    end

    it 'keeps an unpaid legacy expense valid when its source changes without an account' do
      transaction = build(:transaction, kind: :expense, source: :cash, card: nil, account: nil)
      transaction.save!(validate: false)

      transaction.source = :bank

      expect(transaction).to be_valid
    end

    it 'requires an account when an unpaid expense is marked as paid' do
      transaction = create(:transaction, kind: :expense, source: :cash, card: nil, account: nil, paid: false)

      transaction.paid = true

      expect(transaction).not_to be_valid
      expect(transaction.errors[:account]).to include('é obrigatória para despesas sem cartão')
    end
  end

  describe 'enums' do
    it do
      expect(described_class.kinds).to eq(
        'income'  => 0,
        'expense' => 1
      )
    end

    it do
      expect(described_class.sources).to eq(
        'card' => 0,
        'cash' => 1,
        'bank' => 2
      )
    end
  end

  describe 'settlement' do
    it 'defaults settlement to obligation date and value for a new paid loose expense' do
      account = create(:account)
      transaction = create(:transaction, user: account.user, kind: :expense, source: :bank, card: nil, account: account, paid: true, date: Date.new(2026, 8, 18), value: 150)

      expect(transaction.settled_on).to eq(Date.new(2026, 8, 18))
      expect(transaction.settled_value).to eq(150.to_d)
    end

    it 'clears settlement when a loose expense is reopened' do
      account = create(:account)
      transaction = create(:transaction, user: account.user, kind: :expense, source: :cash, card: nil, account: account, paid: true, settled_on: Date.new(2026, 8, 10), settled_value: 149.26)

      transaction.update!(paid: false)

      expect(transaction.settled_on).to be_nil
      expect(transaction.settled_value).to be_nil
    end
  end

  describe 'scopes and totals' do
    describe '.loose_expenses' do
      it 'includes only cash or bank expenses without a card' do
        user = create(:user)
        user_card = create(:card, user: user)
        cash = create(:transaction, user: user, kind: :expense, source: :cash, card: nil)
        bank = create(:transaction, user: user, kind: :expense, source: :bank, card: nil)
        card = create(:transaction, user: user, kind: :expense, source: :card, card: user_card)
        inconsistent = create(:transaction, user: user, kind: :expense, source: :cash, card: nil)
        inconsistent.update_column(:source, Transaction.sources[:card])

        expect(described_class.loose_expenses).to include(cash, bank)
        expect(described_class.loose_expenses).not_to include(card, inconsistent)
      end
    end

    describe '.by_month' do
      it 'retorna apenas transações do mês/ano informados' do
        nov_2025 = create(:transaction, date: Date.new(2025, 11, 10))
        out_2025 = create(:transaction, date: Date.new(2025, 10, 5))

        result = Transaction.by_month(11, 2025)

        expect(result).to include(nov_2025)
        expect(result).not_to include(out_2025)
      end
    end

    describe '.balance_for' do
      it 'retorna receitas - despesas do mês/ano informado' do
        data = Date.new(2025, 11, 1)

        user = create(:user)
        account = create(:account, user: user)

        create(:transaction, user: user, account: account, kind: :income, source: :bank, card: nil, value: 1000.0, date: data)
        create(:transaction, kind: :expense, value:  200.0, date: data)

        expect(Transaction.balance_for(11, 2025)).to eq(800.0)
      end
    end
  end

  describe '#signed_value' do
    it 'returns value for regular transactions and negative value for refunds' do
      regular = build(:transaction, value: 20, refund: false)
      refund = build(:transaction, value: 6.92, refund: true)

      expect(regular.signed_value).to eq(BigDecimal('20'))
      expect(refund.signed_value).to eq(BigDecimal('-6.92'))
    end

    it 'normalizes the raw sign without changing the explicit transaction type' do
      purchase = build(:transaction, value: '-11,02', refund: false)
      refund = build(:transaction, value: '-6,91', refund: true)

      expect(purchase.value).to eq(BigDecimal('11.02'))
      expect(purchase.signed_value).to eq(BigDecimal('11.02'))
      expect(refund.value).to eq(BigDecimal('6.91'))
      expect(refund.signed_value).to eq(BigDecimal('-6.91'))
    end
  end
end
