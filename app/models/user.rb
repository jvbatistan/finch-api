class User < ApplicationRecord
  MAX_USERS = 2

  devise :database_authenticatable, :registerable,
         :recoverable, :validatable

  has_many :account_transfers, dependent: :destroy
  has_many :cards, dependent: :destroy
  has_many :accounts, dependent: :destroy
  has_many :categories, dependent: :destroy
  has_many :transactions, dependent: :destroy
  has_many :classification_suggestions, dependent: :destroy
  has_many :merchant_aliases, dependent: :destroy

  validates :name, presence: true
  validates :active, inclusion: { in: [true, false] }
  validate :user_limit_not_exceeded, on: :create

  scope :active_only, -> { where(active: true) }

  private

  def user_limit_not_exceeded
    return unless User.count >= MAX_USERS

    errors.add(:base, "Limite máximo de usuários atingido")
  end
end
