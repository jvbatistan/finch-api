# Be sure to restart your server when you modify this file.

# Configure sensitive parameters which will be filtered from the log file.
Rails.application.config.filter_parameters += [
  :password, :token, :secret, :authorization, :cookie,
  :email, :name, :description, :note,
  :user, :transaction, :account, :account_transfer, :card, :category, :payment,
  :amount, :settled_value, :initial_balance, :limit,
  :user_id, :account_id, :card_id, :settled_on, :start_date, :end_date
]
