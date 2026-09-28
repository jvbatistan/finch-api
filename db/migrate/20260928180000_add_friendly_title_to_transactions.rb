class AddFriendlyTitleToTransactions < ActiveRecord::Migration[6.1]
  def change
    add_column :transactions, :friendly_title, :string
  end
end
